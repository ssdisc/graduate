function [model, report] = ml_train_impulse_lr(p, opts)
%ML_TRAIN_IMPULSE_LR  Train a lightweight impulse detector (logistic regression).
%
% This trains a tiny model for use with mitigate_impulses(..., "ml_blanking", ...).
% It generates labeled data from the Bernoulli-Gaussian channel model, then fits
% a logistic regression by gradient descent (no extra toolboxes required).
%
% Example:
%   addpath(genpath('src'));
%   p = default_params();
%   [model, report] = ml_train_impulse_lr(p);
%   p.mitigation.ml = model;
%   results = simulate(p);

arguments
    p (1,1) struct
    opts.nBlocks (1,1) double {mustBePositive} = 200
    opts.blockLen (1,1) double {mustBeInteger, mustBePositive} = 4096
    opts.ebN0dBRange (1,2) double = [0 10]
    opts.pfaTarget (1,1) double = 0.01
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 25
    opts.batchSize (1,1) double {mustBeInteger, mustBePositive} = 65536
    opts.lr (1,1) double {mustBePositive} = 0.2
    opts.l2 (1,1) double {mustBeNonnegative} = 1e-3
    opts.verbose (1,1) logical = true
end

if opts.ebN0dBRange(2) <= opts.ebN0dBRange(1)
    error("ebN0dBRange must satisfy hi > lo.");
end
if ~(opts.pfaTarget > 0 && opts.pfaTarget < 1)
    error("pfaTarget must be in (0,1).");
end

[~, modInfo] = modulate_bits(uint8([0; 1]), p.mod);
codeRate = modInfo.codeRate;
bitsPerSym = modInfo.bitsPerSymbol;
Es = 1.0;

nBlocks = opts.nBlocks;
L = opts.blockLen;
n = nBlocks * L;

X = zeros(n, 3, "single");
y = false(n, 1);
ebN0dBPerBlock = zeros(nBlocks, 1);

for b = 1:nBlocks
    ebN0dB = opts.ebN0dBRange(1) + rand() * (opts.ebN0dBRange(2) - opts.ebN0dBRange(1));
    ebN0dBPerBlock(b) = ebN0dB;
    EbN0 = 10.^(ebN0dB/10);
    N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es);

    bits = randi([0 1], L, 1, "uint8");
    tx = 1 - 2*double(bits);

    [r, impMask] = channel_bg_impulsive(tx, N0, p.channel);

    feats = ml_impulse_features(r);
    idx = (b-1)*L + (1:L);
    X(idx, :) = single(feats);
    y(idx) = impMask ~= 0;
end

X = double(X);
mu = mean(X, 1);
sigma = std(X, 0, 1);
sigma(sigma == 0) = 1;
Xn = (X - mu) ./ sigma;

pos = y;
neg = ~y;
posRate = mean(pos);
wPos = 0.5 / max(posRate, eps);
wNeg = 0.5 / max(1 - posRate, eps);
weights = ones(n, 1);
weights(pos) = wPos;
weights(neg) = wNeg;

w = zeros(3, 1);
b = 0;

for epoch = 1:opts.epochs
    perm = randperm(n);
    for start = 1:opts.batchSize:n
        stop = min(start + opts.batchSize - 1, n);
        sel = perm(start:stop);

        xb = Xn(sel, :);
        yb = double(y(sel));
        wb = weights(sel);

        logit = xb*w + b;
        logit = max(min(logit, 30), -30);
        pHat = 1 ./ (1 + exp(-logit));

        diff = (pHat - yb) .* wb;
        gw = (xb.' * diff) / numel(sel) + opts.l2 * w;
        gb = mean(diff);

        w = w - opts.lr * gw;
        b = b - opts.lr * gb;
    end

    if opts.verbose && (epoch == 1 || mod(epoch, 5) == 0 || epoch == opts.epochs)
        logitAll = Xn*w + b;
        logitAll = max(min(logitAll, 30), -30);
        pAll = 1 ./ (1 + exp(-logitAll));
        pred = pAll >= 0.5;
        tpr = mean(pred(pos));
        fpr = mean(pred(neg));
        fprintf("epoch %d/%d: TPR@0.5=%.3f, FPR@0.5=%.3f\\n", epoch, opts.epochs, tpr, fpr);
    end
end

logitAll = Xn*w + b;
logitAll = max(min(logitAll, 30), -30);
pAll = 1 ./ (1 + exp(-logitAll));

pNeg = pAll(neg);
pNegSorted = sort(pNeg);
idxQ = max(1, min(numel(pNegSorted), ceil((1 - opts.pfaTarget) * numel(pNegSorted))));
th = pNegSorted(idxQ);

pfaEst = mean(pNeg >= th);
pdEst = mean(pAll(pos) >= th);
peEst = 0.5 * (pfaEst + 1 - pdEst);

model = struct();
model.name = "impulse_lr_custom";
model.features = ["abs_r" "absdiff_abs" "abs_over_median"];
model.mu = mu(:);
model.sigma = sigma(:);
model.w = w(:);
model.b = b;
model.threshold = th;

report = struct();
report.nBlocks = nBlocks;
report.blockLen = L;
report.nSamples = n;
report.ebN0dBRange = opts.ebN0dBRange;
report.ebN0dBPerBlock = ebN0dBPerBlock;
report.posRate = posRate;
report.pfaTarget = opts.pfaTarget;
report.pfaEst = pfaEst;
report.pdEst = pdEst;
report.peEst = peEst;
report.wPos = wPos;
report.wNeg = wNeg;
report.epochs = opts.epochs;
report.batchSize = opts.batchSize;
report.lr = opts.lr;
report.l2 = opts.l2;
end
