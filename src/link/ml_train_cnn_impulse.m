function [model, report] = ml_train_cnn_impulse(p, opts)
%ML_TRAIN_CNN_IMPULSE  Train 1D CNN impulse detector with soft outputs.
%
% This trains a small CNN that outputs:
%   - Impulse probability
%   - Reliability weight for soft decoding
%   - Cleaned symbol estimate
%
% Example:
%   addpath(genpath('src'));
%   p = default_params();
%   [model, report] = ml_train_cnn_impulse(p);
%   p.mitigation.mlCnn = model;
%   results = simulate(p);

arguments
    p (1,1) struct
    opts.nBlocks (1,1) double {mustBePositive} = 300
    opts.blockLen (1,1) double {mustBeInteger, mustBePositive} = 2048
    opts.ebN0dBRange (1,2) double = [0 12]
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 30
    opts.batchSize (1,1) double {mustBeInteger, mustBePositive} = 512
    opts.lr (1,1) double {mustBePositive} = 0.01
    opts.lrDecay (1,1) double = 0.95
    opts.l2 (1,1) double {mustBeNonnegative} = 1e-4
    opts.pfaTarget (1,1) double = 0.01
    opts.verbose (1,1) logical = true
end

%% Generate training data
if opts.verbose
    fprintf("Generating training data...\n");
end

[~, modInfo] = modulate_bits(uint8([0; 1]), p.mod);
codeRate = modInfo.codeRate;
bitsPerSym = modInfo.bitsPerSymbol;
Es = 1.0;

nBlocks = opts.nBlocks;
L = opts.blockLen;
nTotal = nBlocks * L;

% Storage
allX = zeros(nTotal, 4, 'single');       % Features
allY = false(nTotal, 1);                  % Impulse labels
allTxSym = zeros(nTotal, 1, 'single');   % Clean TX symbols (for regression)
allRxSym = zeros(nTotal, 1, 'single');   % Noisy RX symbols

idx = 0;
for b = 1:nBlocks
    ebN0dB = opts.ebN0dBRange(1) + rand() * diff(opts.ebN0dBRange);
    EbN0 = 10.^(ebN0dB/10);
    N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es);

    % Generate random BPSK symbols
    bits = randi([0 1], L, 1, 'uint8');
    txSym = 1 - 2*double(bits);  % BPSK: 0->+1, 1->-1

    % Pass through impulsive channel
    [rxSym, impMask] = channel_bg_impulsive(txSym, N0, p.channel);

    % Extract features
    feats = ml_cnn_features(rxSym);

    % Store
    allX(idx+1:idx+L, :) = single(feats);
    allY(idx+1:idx+L) = impMask ~= 0;
    allTxSym(idx+1:idx+L) = single(txSym);
    allRxSym(idx+1:idx+L) = single(rxSym);

    idx = idx + L;
end

allX = double(allX);
allTxSym = double(allTxSym);
allRxSym = double(allRxSym);

%% Normalize inputs
inputMean = mean(allX, 1);
inputStd = std(allX, 0, 1);
inputStd(inputStd < 1e-6) = 1;
Xn = (allX - inputMean) ./ inputStd;

%% Initialize model
model = ml_cnn_impulse_model();
model.inputMean = inputMean;
model.inputStd = inputStd;

%% Class weights for imbalanced data
posRate = mean(allY);
wPos = 0.5 / max(posRate, 1e-6);
wNeg = 0.5 / max(1 - posRate, 1e-6);
classWeights = ones(nTotal, 1);
classWeights(allY) = wPos;
classWeights(~allY) = wNeg;

if opts.verbose
    fprintf("Training data: %d samples, %.2f%% impulses\n", nTotal, 100*posRate);
    fprintf("Starting training for %d epochs...\n", opts.epochs);
end

%% Training loop
lr = opts.lr;
halfWin = model.halfWin;
losses = zeros(opts.epochs, 1);

for epoch = 1:opts.epochs
    perm = randperm(nTotal);
    epochLoss = 0;
    nBatches = 0;

    for bStart = 1:opts.batchSize:nTotal
        bEnd = min(bStart + opts.batchSize - 1, nTotal);
        batchIdx = perm(bStart:bEnd);
        batchSize = numel(batchIdx);

        % Get batch data
        Xb = Xn(batchIdx, :);
        Yb = double(allY(batchIdx));
        txb = allTxSym(batchIdx);
        wb = classWeights(batchIdx);

        % Forward pass with gradient computation
        [loss, grads] = cnn_forward_backward(Xb, Yb, txb, wb, model, halfWin);

        % Update weights with L2 regularization
        model.W1 = model.W1 - lr * (grads.dW1 + opts.l2 * model.W1);
        model.b1 = model.b1 - lr * grads.db1;
        model.W2 = model.W2 - lr * (grads.dW2 + opts.l2 * model.W2);
        model.b2 = model.b2 - lr * grads.db2;
        model.Wo = model.Wo - lr * (grads.dWo + opts.l2 * model.Wo);
        model.bo = model.bo - lr * grads.dbo;

        epochLoss = epochLoss + loss * batchSize;
        nBatches = nBatches + 1;
    end

    epochLoss = epochLoss / nTotal;
    losses(epoch) = epochLoss;

    % Learning rate decay
    lr = lr * opts.lrDecay;

    if opts.verbose && (epoch == 1 || mod(epoch, 5) == 0 || epoch == opts.epochs)
        % Evaluate on full dataset
        [~, ~, ~, pImpulse] = ml_cnn_impulse_detect(complex(allRxSym), model);
        pred = pImpulse >= 0.5;
        tpr = mean(pred(allY));
        fpr = mean(pred(~allY));
        fprintf("Epoch %d/%d: loss=%.4f, TPR@0.5=%.3f, FPR@0.5=%.3f\n", ...
            epoch, opts.epochs, epochLoss, tpr, fpr);
    end
end

%% Find optimal threshold for target Pfa
[~, ~, ~, pImpulse] = ml_cnn_impulse_detect(complex(allRxSym), model);
pNeg = pImpulse(~allY);
pNegSorted = sort(pNeg);
idxQ = max(1, min(numel(pNegSorted), ceil((1 - opts.pfaTarget) * numel(pNegSorted))));
model.threshold = pNegSorted(idxQ);

%% Final evaluation
pred = pImpulse >= model.threshold;
pfaEst = mean(pImpulse(~allY) >= model.threshold);
pdEst = mean(pImpulse(allY) >= model.threshold);

model.trained = true;

%% Report
report = struct();
report.nBlocks = nBlocks;
report.blockLen = L;
report.nSamples = nTotal;
report.posRate = posRate;
report.epochs = opts.epochs;
report.finalLoss = losses(end);
report.losses = losses;
report.pfaTarget = opts.pfaTarget;
report.pfaEst = pfaEst;
report.pdEst = pdEst;
report.threshold = model.threshold;

if opts.verbose
    fprintf("\nTraining complete.\n");
    fprintf("Final: Pd=%.3f, Pfa=%.3f at threshold=%.3f\n", pdEst, pfaEst, model.threshold);
end

end

%% Helper functions

function [loss, grads] = cnn_forward_backward(X, Y, txSym, weights, model, halfWin)
%CNN_FORWARD_BACKWARD  Forward and backward pass for CNN.

N = size(X, 1);

% Calculate required padding to maintain output size
K1 = model.conv1KernelSize;
K2 = model.conv2KernelSize;
totalKernelLoss = (K1 - 1) + (K2 - 1);  % Total length lost due to 'valid' convolutions
padLen = ceil(totalKernelLoss / 2) + halfWin;

% Pad input symmetrically
Xpad = [repmat(X(1,:), padLen, 1); X; repmat(X(end,:), padLen, 1)];

% Forward pass
% Conv1
[h1_pre, cache1] = conv1d_forward_cache(Xpad, model.W1, model.b1);
h1 = max(h1_pre, 0);  % ReLU
relu1_mask = h1_pre > 0;

% Conv2
[h2_pre, cache2] = conv1d_forward_cache(h1, model.W2, model.b2);
h2 = max(h2_pre, 0);  % ReLU
relu2_mask = h2_pre > 0;

% Calculate correct trim indices
% After conv1: length = len(Xpad) - K1 + 1 = N + 2*padLen - K1 + 1
% After conv2: length = N + 2*padLen - K1 - K2 + 2
h2Len = size(h2, 1);
trimStart = max(1, floor((h2Len - N) / 2) + 1);
trimEnd = min(h2Len, trimStart + N - 1);
actualN = trimEnd - trimStart + 1;

h2_trim = h2(trimStart:trimEnd, :);

% Adjust targets to match actual output length
if actualN < N
    Y = Y(1:actualN);
    txSym = txSym(1:actualN);
    weights = weights(1:actualN);
end
N = actualN;

% Output layer
out = h2_trim * model.Wo + model.bo;  % [N x 4]

% Parse outputs
pImpulse = sigmoid(out(:, 1));
reliability = sigmoid(out(:, 2));
cleanReal = out(:, 3);
cleanImag = out(:, 4);

% Compute losses
% 1. Binary cross-entropy for impulse detection
bce = -weights .* (Y .* log(pImpulse + 1e-8) + (1 - Y) .* log(1 - pImpulse + 1e-8));
loss_bce = mean(bce);

% 2. MSE for symbol reconstruction (only for non-impulse samples)
cleanTarget = real(txSym);  % For BPSK, real part is the symbol
mse = (cleanReal - cleanTarget).^2;
loss_mse = mean(mse);

% 3. Reliability should be low for impulses, high otherwise
relTarget = 1 - Y;  % 1 for clean, 0 for impulse
rel_loss = mean((reliability - relTarget).^2);

% Total loss
alpha_bce = 1.0;
alpha_mse = 0.5;
alpha_rel = 0.3;
loss = alpha_bce * loss_bce + alpha_mse * loss_mse + alpha_rel * rel_loss;

% Backward pass
% Output gradients
dout = zeros(N, 4);

% BCE gradient
dout(:, 1) = alpha_bce * weights .* (pImpulse - Y) / N;

% Reliability gradient
dout(:, 2) = alpha_rel * 2 * (reliability - relTarget) .* reliability .* (1 - reliability) / N;

% MSE gradient for cleanReal
dout(:, 3) = alpha_mse * 2 * (cleanReal - cleanTarget) / N;

% cleanImag gradient (no target, but regularize toward 0)
dout(:, 4) = alpha_mse * 0.1 * cleanImag / N;

% Output layer gradients
grads.dWo = h2_trim' * dout;
grads.dbo = sum(dout, 1);

% Backprop through trim (expand back)
dh2_trim = dout * model.Wo';
dh2 = zeros(size(h2));
dh2(trimStart:trimEnd, :) = dh2_trim;

% ReLU2 backward
dh2_pre = dh2 .* relu2_mask;

% Conv2 backward
[dh1, dW2, db2] = conv1d_backward(dh2_pre, cache2, model.W2);
grads.dW2 = dW2;
grads.db2 = db2;

% ReLU1 backward
dh1_pre = dh1 .* relu1_mask;

% Conv1 backward
[~, dW1, db1] = conv1d_backward(dh1_pre, cache1, model.W1);
grads.dW1 = dW1;
grads.db1 = db1;

end

function [y, cache] = conv1d_forward_cache(x, W, b)
%CONV1D_FORWARD_CACHE  Forward pass with cache for backward.
[T, Cin] = size(x);
[K, ~, Cout] = size(W);
Tout = T - K + 1;

y = zeros(Tout, Cout);
for co = 1:Cout
    for ci = 1:Cin
        y(:, co) = y(:, co) + conv(x(:, ci), flipud(W(:, ci, co)), 'valid');
    end
    y(:, co) = y(:, co) + b(co);
end

cache.x = x;
cache.K = K;
end

function [dx, dW, db] = conv1d_backward(dy, cache, W)
%CONV1D_BACKWARD  Backward pass for 1D convolution.
x = cache.x;
K = cache.K;
[T, Cin] = size(x);
[Tout, Cout] = size(dy);

dW = zeros(size(W));
db = sum(dy, 1);
dx = zeros(T, Cin);

for co = 1:Cout
    for ci = 1:Cin
        % dW: correlation of input with output gradient
        dW(:, ci, co) = conv(x(end:-1:1, ci), dy(:, co), 'valid');
        dW(:, ci, co) = dW(end:-1:1, ci, co);

        % dx: full convolution of dy with W
        dx(:, ci) = dx(:, ci) + conv(dy(:, co), W(:, ci, co), 'full');
    end
end
end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-max(min(x, 30), -30)));
end
