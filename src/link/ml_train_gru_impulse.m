function [model, report] = ml_train_gru_impulse(p, opts)
%ML_TRAIN_GRU_IMPULSE  Train GRU impulse detector with soft outputs.
%
% Example:
%   addpath(genpath('src'));
%   p = default_params();
%   [model, report] = ml_train_gru_impulse(p);
%   p.mitigation.mlGru = model;

arguments
    p (1,1) struct
    opts.nBlocks (1,1) double {mustBePositive} = 200
    opts.blockLen (1,1) double {mustBeInteger, mustBePositive} = 512
    opts.ebN0dBRange (1,2) double = [0 12]
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 20
    opts.lr (1,1) double {mustBePositive} = 0.005
    opts.lrDecay (1,1) double = 0.95
    opts.clipGrad (1,1) double = 5.0
    opts.pfaTarget (1,1) double = 0.01
    opts.verbose (1,1) logical = true
end

%% Generate training data
if opts.verbose
    fprintf("Generating training data for GRU...\n");
end

[~, modInfo] = modulate_bits(uint8([0; 1]), p.mod);
codeRate = modInfo.codeRate;
bitsPerSym = modInfo.bitsPerSymbol;
Es = 1.0;

nBlocks = opts.nBlocks;
L = opts.blockLen;

% Store sequences
allSeqX = cell(nBlocks, 1);
allSeqY = cell(nBlocks, 1);
allSeqTx = cell(nBlocks, 1);
allSeqRx = cell(nBlocks, 1);

for b = 1:nBlocks
    ebN0dB = opts.ebN0dBRange(1) + rand() * diff(opts.ebN0dBRange);
    EbN0 = 10.^(ebN0dB/10);
    N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es);

    bits = randi([0 1], L, 1, 'uint8');
    txSym = 1 - 2*double(bits);

    [rxSym, impMask] = channel_bg_impulsive(txSym, N0, p.channel);

    feats = ml_cnn_features(rxSym);

    allSeqX{b} = feats;
    allSeqY{b} = impMask ~= 0;
    allSeqTx{b} = txSym;
    allSeqRx{b} = rxSym;
end

%% Compute normalization
allX = cell2mat(allSeqX);
inputMean = mean(allX, 1);
inputStd = std(allX, 0, 1);
inputStd(inputStd < 1e-6) = 1;

% Normalize sequences
for b = 1:nBlocks
    allSeqX{b} = (allSeqX{b} - inputMean) ./ inputStd;
end

%% Initialize model
model = ml_gru_impulse_model();
model.inputMean = inputMean;
model.inputStd = inputStd;

%% Training
if opts.verbose
    allY = cell2mat(allSeqY);
    posRate = mean(allY);
    fprintf("Training data: %d sequences, %.2f%% impulses\n", nBlocks, 100*posRate);
    fprintf("Starting GRU training for %d epochs...\n", opts.epochs);
end

lr = opts.lr;
losses = zeros(opts.epochs, 1);

for epoch = 1:opts.epochs
    perm = randperm(nBlocks);
    epochLoss = 0;

    for bi = 1:nBlocks
        b = perm(bi);
        X = allSeqX{b};
        Y = double(allSeqY{b});
        txSym = allSeqTx{b};
        N = size(X, 1);

        % Forward pass with BPTT
        [loss, grads] = gru_forward_backward(X, Y, txSym, model);

        % Gradient clipping
        grads = clip_gradients(grads, opts.clipGrad);

        % Update weights
        model.Wr = model.Wr - lr * grads.dWr;
        model.Ur = model.Ur - lr * grads.dUr;
        model.br = model.br - lr * grads.dbr;

        model.Wz = model.Wz - lr * grads.dWz;
        model.Uz = model.Uz - lr * grads.dUz;
        model.bz = model.bz - lr * grads.dbz;

        model.Wh = model.Wh - lr * grads.dWh;
        model.Uh = model.Uh - lr * grads.dUh;
        model.bh = model.bh - lr * grads.dbh;

        model.Wo = model.Wo - lr * grads.dWo;
        model.bo = model.bo - lr * grads.dbo;

        epochLoss = epochLoss + loss;
    end

    epochLoss = epochLoss / nBlocks;
    losses(epoch) = epochLoss;
    lr = lr * opts.lrDecay;

    if opts.verbose && (epoch == 1 || mod(epoch, 5) == 0 || epoch == opts.epochs)
        % Evaluate
        allPred = [];
        allTrue = [];
        for b = 1:nBlocks
            [~, ~, ~, pImp] = ml_gru_impulse_detect(complex(allSeqRx{b}), model);
            allPred = [allPred; pImp];
            allTrue = [allTrue; double(allSeqY{b})];
        end
        allTrue = logical(allTrue);
        pred = allPred >= 0.5;
        tpr = mean(pred(allTrue));
        fpr = mean(pred(~allTrue));
        fprintf("Epoch %d/%d: loss=%.4f, TPR=%.3f, FPR=%.3f\n", epoch, opts.epochs, epochLoss, tpr, fpr);
    end
end

%% Find optimal threshold
allPred = [];
allTrue = [];
for b = 1:nBlocks
    [~, ~, ~, pImp] = ml_gru_impulse_detect(complex(allSeqRx{b}), model);
    allPred = [allPred; pImp];
    allTrue = [allTrue; double(allSeqY{b})];
end
allTrue = logical(allTrue);

pNeg = allPred(~allTrue);
pNegSorted = sort(pNeg);
idxQ = max(1, min(numel(pNegSorted), ceil((1 - opts.pfaTarget) * numel(pNegSorted))));
model.threshold = pNegSorted(idxQ);

pfaEst = mean(allPred(~allTrue) >= model.threshold);
pdEst = mean(allPred(allTrue) >= model.threshold);

model.trained = true;

%% Report
report = struct();
report.nBlocks = nBlocks;
report.blockLen = L;
report.epochs = opts.epochs;
report.finalLoss = losses(end);
report.losses = losses;
report.pfaTarget = opts.pfaTarget;
report.pfaEst = pfaEst;
report.pdEst = pdEst;
report.threshold = model.threshold;

if opts.verbose
    fprintf("\nGRU training complete. Pd=%.3f, Pfa=%.3f\n", pdEst, pfaEst);
end

end

function [loss, grads] = gru_forward_backward(X, Y, txSym, model)
%GRU_FORWARD_BACKWARD  BPTT for GRU.

N = size(X, 1);
hs = model.hiddenSize;

% Forward pass - store all states
H = zeros(N+1, hs);  % h[0] to h[N]
R = zeros(N, hs);    % reset gates
Z = zeros(N, hs);    % update gates
Htilde = zeros(N, hs);  % candidate states
outputs = zeros(N, 4);

for t = 1:N
    xt = X(t, :);
    h_prev = H(t, :);

    R(t, :) = sigmoid(xt * model.Wr + h_prev * model.Ur + model.br);
    Z(t, :) = sigmoid(xt * model.Wz + h_prev * model.Uz + model.bz);
    Htilde(t, :) = tanh(xt * model.Wh + (R(t,:) .* h_prev) * model.Uh + model.bh);
    H(t+1, :) = (1 - Z(t,:)) .* h_prev + Z(t,:) .* Htilde(t,:);

    outputs(t, :) = H(t+1, :) * model.Wo + model.bo;
end

% Compute loss
pImpulse = sigmoid(outputs(:, 1));
reliability = sigmoid(outputs(:, 2));
cleanReal = outputs(:, 3);

bce = -(Y .* log(pImpulse + 1e-8) + (1 - Y) .* log(1 - pImpulse + 1e-8));
mse = (cleanReal - real(txSym)).^2;
relTarget = 1 - Y;
relLoss = (reliability - relTarget).^2;

loss = mean(bce) + 0.5 * mean(mse) + 0.3 * mean(relLoss);

% Backward pass
dout = zeros(N, 4);
dout(:, 1) = (pImpulse - Y) / N;
dout(:, 2) = 0.3 * 2 * (reliability - relTarget) .* reliability .* (1 - reliability) / N;
dout(:, 3) = 0.5 * 2 * (cleanReal - real(txSym)) / N;

% Output layer gradients
grads.dWo = H(2:end, :)' * dout;
grads.dbo = sum(dout, 1);

% BPTT
dh_next = zeros(1, hs);
grads.dWr = zeros(size(model.Wr));
grads.dUr = zeros(size(model.Ur));
grads.dbr = zeros(size(model.br));
grads.dWz = zeros(size(model.Wz));
grads.dUz = zeros(size(model.Uz));
grads.dbz = zeros(size(model.bz));
grads.dWh = zeros(size(model.Wh));
grads.dUh = zeros(size(model.Uh));
grads.dbh = zeros(size(model.bh));

for t = N:-1:1
    xt = X(t, :);
    h_prev = H(t, :);
    rt = R(t, :);
    zt = Z(t, :);
    ht = Htilde(t, :);

    dh = dout(t, :) * model.Wo' + dh_next;

    % Gradient through h = (1-z)*h_prev + z*h_tilde
    dh_tilde = dh .* zt;
    dz = dh .* (ht - h_prev);
    dh_prev = dh .* (1 - zt);

    % Gradient through h_tilde = tanh(...)
    dh_tilde_pre = dh_tilde .* (1 - ht.^2);
    grads.dWh = grads.dWh + xt' * dh_tilde_pre;
    grads.dUh = grads.dUh + (rt .* h_prev)' * dh_tilde_pre;
    grads.dbh = grads.dbh + dh_tilde_pre;

    dr_from_h = dh_tilde_pre * model.Uh' .* h_prev;
    dh_prev = dh_prev + dh_tilde_pre * model.Uh' .* rt;

    % Gradient through z = sigmoid(...)
    dz_pre = dz .* zt .* (1 - zt);
    grads.dWz = grads.dWz + xt' * dz_pre;
    grads.dUz = grads.dUz + h_prev' * dz_pre;
    grads.dbz = grads.dbz + dz_pre;
    dh_prev = dh_prev + dz_pre * model.Uz';

    % Gradient through r = sigmoid(...)
    dr_pre = dr_from_h .* rt .* (1 - rt);
    grads.dWr = grads.dWr + xt' * dr_pre;
    grads.dUr = grads.dUr + h_prev' * dr_pre;
    grads.dbr = grads.dbr + dr_pre;
    dh_prev = dh_prev + dr_pre * model.Ur';

    dh_next = dh_prev;
end

end

function grads = clip_gradients(grads, maxNorm)
%CLIP_GRADIENTS  Clip gradients by global norm.
fields = fieldnames(grads);
totalNorm = 0;
for i = 1:numel(fields)
    totalNorm = totalNorm + sum(grads.(fields{i})(:).^2);
end
totalNorm = sqrt(totalNorm);

if totalNorm > maxNorm
    scale = maxNorm / totalNorm;
    for i = 1:numel(fields)
        grads.(fields{i}) = grads.(fields{i}) * scale;
    end
end
end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-max(min(x, 30), -30)));
end
