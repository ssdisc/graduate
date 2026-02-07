function [model, report] = ml_train_gru_impulse(p, opts)
%ML_TRAIN_GRU_IMPULSE  使用Deep Learning Toolbox训练GRU脉冲检测器（支持GPU）。
%
% 示例:
%   addpath(genpath('src'));
%   p = default_params();
%   [model, report] = ml_train_gru_impulse(p);
%   p.mitigation.mlGru = model;
%
% 输入:
%   p    - 参数结构体（default_params）
%          主要使用: p.mod, p.channel, p.mitigation
%   opts - 训练选项结构体（Name-Value）
%          .nBlocks, .blockLen, .ebN0dBRange
%          .epochs, .batchSize, .lr, .pfaTarget
%          .useGpu, .verbose
%
% 输出:
%   model  - 训练后的GRU模型结构体
%   report - 训练报告结构体（阈值/检测率等）

arguments
    p (1,1) struct
    opts.nBlocks (1,1) double {mustBePositive} = 200
    opts.blockLen (1,1) double {mustBeInteger, mustBePositive} = 512
    opts.ebN0dBRange (1,2) double = [0 12]
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 20
    opts.batchSize (1,1) double {mustBeInteger, mustBePositive} = 32
    opts.lr (1,1) double {mustBePositive} = 0.001
    opts.pfaTarget (1,1) double = 0.01
    opts.useGpu (1,1) logical = true
    opts.verbose (1,1) logical = true
end

%% 检查GPU可用性
if opts.useGpu && canUseGPU()
    executionEnvironment = "gpu";
    if opts.verbose
        fprintf("使用GPU训练GRU\n");
    end
else
    executionEnvironment = "cpu";
    if opts.verbose
        fprintf("使用CPU训练GRU\n");
    end
end

%% 生成训练数据
if opts.verbose
    fprintf("正在为GRU生成训练数据...\n");
end

[~, modInfo] = modulate_bits(uint8([0; 1]), p.mod);
codeRate = modInfo.codeRate;
bitsPerSym = modInfo.bitsPerSymbol;
Es = 1.0;

nBlocks = opts.nBlocks;
L = opts.blockLen;

% 存储序列
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

%% 计算归一化
allX = cell2mat(allSeqX);
inputMean = mean(allX, 1);
inputStd = std(allX, 0, 1);
inputStd(inputStd < 1e-6) = 1;

% 归一化序列
for b = 1:nBlocks
    allSeqX{b} = (allSeqX{b} - inputMean) ./ inputStd;
end

%% 初始化模型
model = ml_gru_impulse_model();
model.inputMean = inputMean;
model.inputStd = inputStd;

%% 统计脉冲率
allY = cell2mat(allSeqY);
posRate = mean(allY);

if opts.verbose
    fprintf("训练数据：%d序列，每序列%d样本，%.2f%%脉冲\n", nBlocks, L, 100*posRate);
    fprintf("开始GRU训练%d轮...\n", opts.epochs);
end

%% 类别权重（处理不平衡）
wPos = 0.5 / max(posRate, 1e-6);
wNeg = 0.5 / max(1 - posRate, 1e-6);

%% 准备训练数据
XTrain = cell(nBlocks, 1);
YTrain = cell(nBlocks, 1);
TxTrain = cell(nBlocks, 1);

for b = 1:nBlocks
    XTrain{b} = allSeqX{b}';      % [4 x L]
    YTrain{b} = double(allSeqY{b})';  % [1 x L]
    TxTrain{b} = allSeqTx{b}';    % [1 x L]
end

%% 初始化Adam优化器状态
averageGrad = [];
averageSqGrad = [];

%% 训练循环
losses = zeros(opts.epochs, 1);
learnRate = opts.lr;

for epoch = 1:opts.epochs
    perm = randperm(nBlocks);
    epochLoss = 0;

    for bStart = 1:opts.batchSize:nBlocks
        bEnd = min(bStart + opts.batchSize - 1, nBlocks);
        batchIdx = perm(bStart:bEnd);
        batchSize = numel(batchIdx);

        % 准备批次数据
        XBatch = XTrain(batchIdx);
        YBatch = YTrain(batchIdx);
        TxBatch = TxTrain(batchIdx);

        % 合并批次数据
        XData = cat(3, XBatch{:});  % [4 x L x batchSize]
        YData = cat(3, YBatch{:});  % [1 x L x batchSize]
        TxData = cat(3, TxBatch{:}); % [1 x L x batchSize]

        % 计算类别权重
        WData = ones(size(YData));
        WData(YData == 1) = wPos;
        WData(YData == 0) = wNeg;

        % 转换为dlarray
        XDl = dlarray(single(XData), 'CTB');
        YDl = dlarray(single(YData), 'CTB');
        TxDl = dlarray(single(TxData), 'CTB');
        WDl = dlarray(single(WData), 'CTB');

        % 移动到GPU
        if executionEnvironment == "gpu"
            XDl = gpuArray(XDl);
            YDl = gpuArray(YDl);
            TxDl = gpuArray(TxDl);
            WDl = gpuArray(WDl);
        end

        % 计算损失和梯度
        [loss, gradients] = dlfeval(@modelLossGru, model.net, XDl, YDl, TxDl, WDl);

        % 更新网络参数
        [model.net, averageGrad, averageSqGrad] = adamupdate(model.net, gradients, ...
            averageGrad, averageSqGrad, epoch, learnRate);

        epochLoss = epochLoss + extractdata(loss) * batchSize;
    end

    epochLoss = epochLoss / nBlocks;
    losses(epoch) = epochLoss;

    if opts.verbose && (epoch == 1 || mod(epoch, 5) == 0 || epoch == opts.epochs)
        % 评估
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
        fprintf("第%d/%d轮：loss=%.4f, TPR=%.3f, FPR=%.3f\n", epoch, opts.epochs, epochLoss, tpr, fpr);
    end
end

%% 寻找最优阈值
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

%% 报告
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
report.executionEnvironment = executionEnvironment;

if opts.verbose
    fprintf("\nGRU训练完成。Pd=%.3f, Pfa=%.3f\n", pdEst, pfaEst);
end

end

%% 损失函数
function [loss, gradients] = modelLossGru(net, X, Y, Tx, W)
%MODELLOSSGRU  计算GRU模型的损失和梯度。

% 前向传播
out = forward(net, X);  % [4 x L x B]

% 解析输出
pImpulse = sigmoid(out(1,:,:));
reliability = sigmoid(out(2,:,:));
cleanReal = out(3,:,:);

% 1. 脉冲检测的加权二元交叉熵
bce = -W .* (Y .* log(pImpulse + 1e-8) + (1 - Y) .* log(1 - pImpulse + 1e-8));
lossBce = mean(bce, 'all');

% 2. 符号重建的MSE
mse = (cleanReal - Tx).^2;
lossMse = mean(mse, 'all');

% 3. 可靠性损失
relTarget = 1 - Y;
relLoss = (reliability - relTarget).^2;
lossRel = mean(relLoss, 'all');

% 总损失
loss = lossBce + 0.5 * lossMse + 0.3 * lossRel;

% 计算梯度
gradients = dlgradient(loss, net.Learnables);

end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-x));
end
