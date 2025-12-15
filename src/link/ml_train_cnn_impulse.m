function [model, report] = ml_train_cnn_impulse(p, opts)
%ML_TRAIN_CNN_IMPULSE  训练带软输出的1D CNN脉冲检测器。
%
% 训练一个小型CNN，输出：
%   - 脉冲概率
%   - 软译码的可靠性权重
%   - 清洁符号估计
%
% 示例:
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

%% 生成训练数据
if opts.verbose
    fprintf("正在生成训练数据...\n");
end

[~, modInfo] = modulate_bits(uint8([0; 1]), p.mod);
codeRate = modInfo.codeRate;
bitsPerSym = modInfo.bitsPerSymbol;
Es = 1.0;

nBlocks = opts.nBlocks;
L = opts.blockLen;
nTotal = nBlocks * L;

% 存储
allX = zeros(nTotal, 4, 'single');       % 特征
allY = false(nTotal, 1);                  % 脉冲标签
allTxSym = zeros(nTotal, 1, 'single');   % 清洁发送符号（用于回归）
allRxSym = zeros(nTotal, 1, 'single');   % 含噪接收符号

idx = 0;
for b = 1:nBlocks
    ebN0dB = opts.ebN0dBRange(1) + rand() * diff(opts.ebN0dBRange);
    EbN0 = 10.^(ebN0dB/10);
    N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es);

    % 生成随机BPSK符号
    bits = randi([0 1], L, 1, 'uint8');
    txSym = 1 - 2*double(bits);  % BPSK: 0->+1, 1->-1

    % 通过脉冲信道
    [rxSym, impMask] = channel_bg_impulsive(txSym, N0, p.channel);

    % 提取特征
    feats = ml_cnn_features(rxSym);

    % 存储
    allX(idx+1:idx+L, :) = single(feats);
    allY(idx+1:idx+L) = impMask ~= 0;
    allTxSym(idx+1:idx+L) = single(txSym);
    allRxSym(idx+1:idx+L) = single(rxSym);

    idx = idx + L;
end

allX = double(allX);
allTxSym = double(allTxSym);
allRxSym = double(allRxSym);

%% 归一化输入
inputMean = mean(allX, 1);
inputStd = std(allX, 0, 1);
inputStd(inputStd < 1e-6) = 1;
Xn = (allX - inputMean) ./ inputStd;

%% 初始化模型
model = ml_cnn_impulse_model();
model.inputMean = inputMean;
model.inputStd = inputStd;

%% 类别权重处理不平衡数据
posRate = mean(allY);
wPos = 0.5 / max(posRate, 1e-6);
wNeg = 0.5 / max(1 - posRate, 1e-6);
classWeights = ones(nTotal, 1);
classWeights(allY) = wPos;
classWeights(~allY) = wNeg;

if opts.verbose
    fprintf("训练数据：%d样本，%.2f%%脉冲\n", nTotal, 100*posRate);
    fprintf("开始训练%d轮...\n", opts.epochs);
end

%% 训练循环
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

        % 获取批次数据
        Xb = Xn(batchIdx, :);
        Yb = double(allY(batchIdx));
        txb = allTxSym(batchIdx);
        wb = classWeights(batchIdx);

        % 带梯度计算的前向传播
        [loss, grads] = cnn_forward_backward(Xb, Yb, txb, wb, model, halfWin);

        % 带L2正则化的权重更新
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

    % 学习率衰减
    lr = lr * opts.lrDecay;

    if opts.verbose && (epoch == 1 || mod(epoch, 5) == 0 || epoch == opts.epochs)
        % 在完整数据集上评估
        [~, ~, ~, pImpulse] = ml_cnn_impulse_detect(complex(allRxSym), model);
        pred = pImpulse >= 0.5;
        tpr = mean(pred(allY));
        fpr = mean(pred(~allY));
        fprintf("第%d/%d轮：loss=%.4f, TPR@0.5=%.3f, FPR@0.5=%.3f\n", ...
            epoch, opts.epochs, epochLoss, tpr, fpr);
    end
end

%% 为目标Pfa找最优阈值
[~, ~, ~, pImpulse] = ml_cnn_impulse_detect(complex(allRxSym), model);
pNeg = pImpulse(~allY);
pNegSorted = sort(pNeg);
idxQ = max(1, min(numel(pNegSorted), ceil((1 - opts.pfaTarget) * numel(pNegSorted))));
model.threshold = pNegSorted(idxQ);

%% 最终评估
pred = pImpulse >= model.threshold;
pfaEst = mean(pImpulse(~allY) >= model.threshold);
pdEst = mean(pImpulse(allY) >= model.threshold);

model.trained = true;

%% 报告
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
    fprintf("\n训练完成。\n");
    fprintf("最终：Pd=%.3f, Pfa=%.3f，阈值=%.3f\n", pdEst, pfaEst, model.threshold);
end

end

%% 辅助函数

function [loss, grads] = cnn_forward_backward(X, Y, txSym, weights, model, halfWin)
%CNN_FORWARD_BACKWARD  CNN的前向和反向传播。

N = size(X, 1);

% 计算保持输出大小所需的填充
K1 = model.conv1KernelSize;
K2 = model.conv2KernelSize;
totalKernelLoss = (K1 - 1) + (K2 - 1);  % 'valid'卷积导致的总长度损失
padLen = ceil(totalKernelLoss / 2) + halfWin;

% 对称填充输入
Xpad = [repmat(X(1,:), padLen, 1); X; repmat(X(end,:), padLen, 1)];

% 前向传播
% Conv1
[h1_pre, cache1] = conv1d_forward_cache(Xpad, model.W1, model.b1);
h1 = max(h1_pre, 0);  % ReLU
relu1_mask = h1_pre > 0;

% Conv2
[h2_pre, cache2] = conv1d_forward_cache(h1, model.W2, model.b2);
h2 = max(h2_pre, 0);  % ReLU
relu2_mask = h2_pre > 0;

% 计算正确的裁剪索引
% conv1后：长度 = len(Xpad) - K1 + 1 = N + 2*padLen - K1 + 1
% conv2后：长度 = N + 2*padLen - K1 - K2 + 2
h2Len = size(h2, 1);
trimStart = max(1, floor((h2Len - N) / 2) + 1);
trimEnd = min(h2Len, trimStart + N - 1);
actualN = trimEnd - trimStart + 1;

h2_trim = h2(trimStart:trimEnd, :);

% 调整目标以匹配实际输出长度
if actualN < N
    Y = Y(1:actualN);
    txSym = txSym(1:actualN);
    weights = weights(1:actualN);
end
N = actualN;

% 输出层
out = h2_trim * model.Wo + model.bo;  % [N x 4]

% 解析输出
pImpulse = sigmoid(out(:, 1));
reliability = sigmoid(out(:, 2));
cleanReal = out(:, 3);
cleanImag = out(:, 4);

% 计算损失
% 1. 脉冲检测的二元交叉熵
bce = -weights .* (Y .* log(pImpulse + 1e-8) + (1 - Y) .* log(1 - pImpulse + 1e-8));
loss_bce = mean(bce);

% 2. 符号重建的MSE（仅对非脉冲样本）
cleanTarget = real(txSym);  % 对于BPSK，实部就是符号
mse = (cleanReal - cleanTarget).^2;
loss_mse = mean(mse);

% 3. 可靠性应该对脉冲低，否则高
relTarget = 1 - Y;  % 清洁为1，脉冲为0
rel_loss = mean((reliability - relTarget).^2);

% 总损失
alpha_bce = 1.0;
alpha_mse = 0.5;
alpha_rel = 0.3;
loss = alpha_bce * loss_bce + alpha_mse * loss_mse + alpha_rel * rel_loss;

% 反向传播
% 输出梯度
dout = zeros(N, 4);

% BCE梯度
dout(:, 1) = alpha_bce * weights .* (pImpulse - Y) / N;

% 可靠性梯度
dout(:, 2) = alpha_rel * 2 * (reliability - relTarget) .* reliability .* (1 - reliability) / N;

% cleanReal的MSE梯度
dout(:, 3) = alpha_mse * 2 * (cleanReal - cleanTarget) / N;

% cleanImag梯度（无目标，但正则化趋向0）
dout(:, 4) = alpha_mse * 0.1 * cleanImag / N;

% 输出层梯度
grads.dWo = h2_trim' * dout;
grads.dbo = sum(dout, 1);

% 通过裁剪反向传播（扩展回去）
dh2_trim = dout * model.Wo';
dh2 = zeros(size(h2));
dh2(trimStart:trimEnd, :) = dh2_trim;

% ReLU2反向
dh2_pre = dh2 .* relu2_mask;

% Conv2反向
[dh1, dW2, db2] = conv1d_backward(dh2_pre, cache2, model.W2);
grads.dW2 = dW2;
grads.db2 = db2;

% ReLU1反向
dh1_pre = dh1 .* relu1_mask;

% Conv1反向
[~, dW1, db1] = conv1d_backward(dh1_pre, cache1, model.W1);
grads.dW1 = dW1;
grads.db1 = db1;

end

function [y, cache] = conv1d_forward_cache(x, W, b)
%CONV1D_FORWARD_CACHE  带缓存的前向传播用于反向传播。
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
%CONV1D_BACKWARD  1D卷积的反向传播。
x = cache.x;
K = cache.K;
[T, Cin] = size(x);
[Tout, Cout] = size(dy);

dW = zeros(size(W));
db = sum(dy, 1);
dx = zeros(T, Cin);

for co = 1:Cout
    for ci = 1:Cin
        % dW：输入与输出梯度的相关
        dW(:, ci, co) = conv(x(end:-1:1, ci), dy(:, co), 'valid');
        dW(:, ci, co) = dW(end:-1:1, ci, co);

        % dx：dy与W的全卷积
        dx(:, ci) = dx(:, ci) + conv(dy(:, co), W(:, ci, co), 'full');
    end
end
end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-max(min(x, 30), -30)));
end
