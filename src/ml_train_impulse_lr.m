function [model, report] = ml_train_impulse_lr(p, opts)
%ML_TRAIN_IMPULSE_LR  训练轻量级脉冲检测器（逻辑回归）。
%
% 训练一个小型模型用于mitigate_impulses(..., "ml_blanking", ...)。
% 从伯努利-高斯信道模型生成标注数据，然后通过梯度下降拟合逻辑回归
% （无需额外工具箱）。
%
% 示例:
%   addpath(genpath('src'));
%   p = default_params();
%   [model, report] = ml_train_impulse_lr(p);
%   p.mitigation.ml = model;
%   results = simulate(p);
%
% 输入:
%   p    - 参数结构体（default_params）
%          主要使用: p.mod, p.channel, p.mitigation
%   opts - 训练选项结构体（Name-Value）
%          .nBlocks    训练数据块数（块=数据生成单位）
%          .blockLen   每块样本数
%          .ebN0dBRange 每块随机采样的Eb/N0范围[dB]，形如[lo hi]
%          .pfaTarget  用于选阈值的目标虚警率
%          .epochs     训练轮数
%          .batchSize  每次梯度更新的样本数（批=参数更新单位）
%          .lr         学习率
%          .l2         L2正则系数
%          .verbose    是否打印训练日志
%
% 输出:
%   model  - 训练后的逻辑回归模型结构体
%   report - 训练报告结构体（阈值/检测率等）

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

X = zeros(n, 3, "single");%特征矩阵：每行一个样本，每列一个特征
y = false(n, 1);%标签向量：true=脉冲样本，false=非脉冲样本
ebN0dBPerBlock = zeros(nBlocks, 1);

for b = 1:nBlocks
    ebN0dB = opts.ebN0dBRange(1) + rand() * (opts.ebN0dBRange(2) - opts.ebN0dBRange(1));
    ebN0dBPerBlock(b) = ebN0dB;
    EbN0 = 10.^(ebN0dB/10);
    N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es);

    %每块随机生成L个符号（对应L*bitsPerSym个比特），通过信道模型得到接收样本和脉冲标签
    bits = randi([0 1], L * bitsPerSym, 1, "uint8");
    tx = modulate_bits(bits, p.mod);
    [r, impMask] = channel_bg_impulsive(tx, N0, p.channel);

    %提取特征并填充训练矩阵X和标签向量y
    feats = ml_impulse_features(r);
    idx = (b-1)*L + (1:L);
    X(idx, :) = single(feats);
    y(idx) = impMask ~= 0;
end

%特征标准化
X = double(X);
mu = mean(X, 1);
sigma = std(X, 0, 1);
sigma(sigma == 0) = 1;
Xn = (X - mu) ./ sigma;

%处理类别不平衡：为正负样本分配权重，使得它们在损失函数中具有相等的影响力
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
        
        %每次处理一个批次的样本，计算梯度并更新参数
        stop = min(start + opts.batchSize - 1, n);
        sel = perm(start:stop);

        %批次样本的特征、标签和权重
        xb = Xn(sel, :);
        yb = double(y(sel));
        wb = weights(sel);


        %计算逻辑回归的预测概率和梯度，使用sigmoid函数
        logit = xb*w + b;
        logit = max(min(logit, 30), -30);
        pHat = 1 ./ (1 + exp(-logit));

        %计算加权的梯度（带L2正则化），并更新权重w和偏置b
        diff = (pHat - yb) .* wb;
        gw = (xb.' * diff) / numel(sel) + opts.l2 * w;
        gb = mean(diff);

        %参数更新（梯度下降）
        w = w - opts.lr * gw;
        b = b - opts.lr * gb;
    end
    %每5轮或第一轮打印一次训练日志，显示当前的TPR和FPR（使用0.5阈值）
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
