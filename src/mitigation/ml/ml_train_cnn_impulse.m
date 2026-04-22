function [model, report] = ml_train_cnn_impulse(p, opts)
%ML_TRAIN_CNN_IMPULSE  使用 Deep Learning Toolbox 训练采样级 1D CNN 脉冲检测器。

arguments
    p (1,1) struct
    opts.nBlocks (1,1) double {mustBePositive} = 300
    opts.blockLen (1,1) double {mustBeInteger, mustBePositive} = 2048 % 采样窗口长度
    opts.ebN0dBRange (1,2) double = [0 12]
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 30
    opts.batchSize (1,1) double {mustBeInteger, mustBePositive} = 64
    opts.lr (1,1) double {mustBePositive} = 0.001
    opts.pfaTarget (1,1) double = 0.01
    opts.valFraction (1,1) double = 0.15
    opts.testFraction (1,1) double = 0.15
    opts.splitSeed (1,1) double = 1
    opts.rngSeed (1,1) double = NaN
    opts.enableEarlyStopping (1,1) logical = true
    opts.earlyStoppingPatience (1,1) double {mustBeInteger, mustBePositive} = 5
    opts.earlyStoppingMinDelta (1,1) double {mustBeNonnegative} = 1e-4
    opts.minEpochs (1,1) double {mustBeInteger, mustBePositive} = 5
    opts.labelScoreThreshold (1,1) double {mustBePositive} = 0.1
    opts.minPositiveRate (1,1) double {mustBeNonnegative} = 0.002
    opts.maxPositiveRate (1,1) double {mustBePositive} = 0.35
    opts.thresholdPolicy (1,1) string = "min_pe_under_pfa"
    opts.thresholdPfaSlack (1,1) double {mustBeNonnegative} = 0
    opts.impulseEnableProbability (1,1) double = 1.0
    opts.impulseProbRange (1,2) double = [NaN NaN]
    opts.impulseToBgRatioRange (1,2) double = [NaN NaN]
    opts.singleToneProbability (1,1) double = 0.0
    opts.singleTonePowerRange (1,2) double = [NaN NaN]
    opts.singleToneFreqHzRange (1,2) double = [NaN NaN]
    opts.narrowbandProbability (1,1) double = 0.0
    opts.narrowbandPowerRange (1,2) double = [NaN NaN]
    opts.narrowbandCenterFreqPointsRange (1,2) double = [NaN NaN]
    opts.narrowbandBandwidthFreqPointsRange (1,2) double = [NaN NaN]
    opts.sweepProbability (1,1) double = 0.0
    opts.sweepPowerRange (1,2) double = [NaN NaN]
    opts.sweepStartHzRange (1,2) double = [NaN NaN]
    opts.sweepStopHzRange (1,2) double = [NaN NaN]
    opts.sweepPeriodSymbolsRange (1,2) double = [NaN NaN]
    opts.syncImpairmentProbability (1,1) double = 0.0
    opts.timingOffsetSymbolsRange (1,2) double = [NaN NaN]
    opts.phaseOffsetRadRange (1,2) double = [NaN NaN]
    opts.multipathProbability (1,1) double = 0.0
    opts.multipathRayleighProbability (1,1) double = 0.5
    opts.maxAdditionalImpairments (1,1) double {mustBeInteger, mustBeNonnegative} = 2
    opts.saveArtifacts (1,1) logical = false
    opts.saveDir (1,1) string = "models"
    opts.saveTag (1,1) string = ""
    opts.savedBy (1,1) string = ""
    opts.useGpu (1,1) logical = true
    opts.verbose (1,1) logical = true
end

if ~(opts.valFraction > 0 && opts.valFraction < 1)
    error("valFraction 必须在 (0,1) 内。");
end
if ~(opts.testFraction > 0 && opts.testFraction < 1)
    error("testFraction 必须在 (0,1) 内。");
end

rngSeed = ml_resolve_rng_seed(p, opts.rngSeed);
rngScope = ml_rng_scope(rngSeed); %#ok<NASGU>

if opts.useGpu && canUseGPU()
    executionEnvironment = "gpu";
    if opts.verbose
        fprintf("使用GPU训练\n");
    end
else
    executionEnvironment = "cpu";
    if opts.verbose
        fprintf("使用CPU训练\n");
    end
end

if opts.verbose
    fprintf("正在生成训练/验证/测试数据...\n");
end

dataset = ml_generate_impulse_blocks(p, opts.nBlocks, opts.blockLen, opts.ebN0dBRange, ...
    "labelScoreThreshold", opts.labelScoreThreshold, ...
    "impulseEnableProbability", opts.impulseEnableProbability, ...
    "impulseProbRange", opts.impulseProbRange, ...
    "impulseToBgRatioRange", opts.impulseToBgRatioRange, ...
    "singleToneProbability", opts.singleToneProbability, ...
    "singleTonePowerRange", opts.singleTonePowerRange, ...
    "singleToneFreqHzRange", opts.singleToneFreqHzRange, ...
    "narrowbandProbability", opts.narrowbandProbability, ...
    "narrowbandPowerRange", opts.narrowbandPowerRange, ...
    "narrowbandCenterFreqPointsRange", opts.narrowbandCenterFreqPointsRange, ...
    "narrowbandBandwidthFreqPointsRange", opts.narrowbandBandwidthFreqPointsRange, ...
    "sweepProbability", opts.sweepProbability, ...
    "sweepPowerRange", opts.sweepPowerRange, ...
    "sweepStartHzRange", opts.sweepStartHzRange, ...
    "sweepStopHzRange", opts.sweepStopHzRange, ...
    "sweepPeriodSymbolsRange", opts.sweepPeriodSymbolsRange, ...
    "syncImpairmentProbability", opts.syncImpairmentProbability, ...
    "timingOffsetSymbolsRange", opts.timingOffsetSymbolsRange, ...
    "phaseOffsetRadRange", opts.phaseOffsetRadRange, ...
    "multipathProbability", opts.multipathProbability, ...
    "multipathRayleighProbability", opts.multipathRayleighProbability, ...
    "maxAdditionalImpairments", opts.maxAdditionalImpairments);
datasetSummary = ml_validate_dataset_labels(dataset, ...
    "minPositiveRate", opts.minPositiveRate, ...
    "maxPositiveRate", opts.maxPositiveRate);
split = ml_split_dataset_indices(dataset.nBlocks, opts.valFraction, opts.testFraction, opts.splitSeed);
if split.nVal < 1 || split.nTest < 1
    error("当前CNN训练流程要求独立的验证集和测试集，请增大 nBlocks 或调整 val/test 占比。");
end

trainRx = dataset.rxInput(split.trainIdx);
trainTx = dataset.txClean(split.trainIdx);
trainY = dataset.impMask(split.trainIdx);
valRx = dataset.rxInput(split.valIdx);
valY = dataset.impMask(split.valIdx);
testRx = dataset.rxInput(split.testIdx);
testY = dataset.impMask(split.testIdx);

trainX = local_extract_features(trainRx);
valX = local_extract_features(valRx);
testX = local_extract_features(testRx);

allXTrain = cell2mat(trainX);
inputMean = mean(allXTrain, 1);
inputStd = std(allXTrain, 0, 1);
inputStd(inputStd < 1e-6) = 1;

trainX = local_normalize_features(trainX, inputMean, inputStd);
valX = local_normalize_features(valX, inputMean, inputStd);
testX = local_normalize_features(testX, inputMean, inputStd);

model = ml_cnn_impulse_model();
model.inputMean = inputMean;
model.inputStd = inputStd;

trainPosRate = mean(cell2mat(cellfun(@double, trainY, 'UniformOutput', false)));
valPosRate = local_positive_rate(valY);
testPosRate = local_positive_rate(testY);

if opts.verbose
    fprintf("训练标签总体正样本率：%.2f%%（块均值 %.2f%%，范围 %.2f%%~%.2f%%）\n", ...
        100 * datasetSummary.overallPosRate, ...
        100 * datasetSummary.blockPosRateMean, ...
        100 * datasetSummary.blockPosRateMin, ...
        100 * datasetSummary.blockPosRateMax);
    fprintf("数据划分：train=%d, val=%d, test=%d\n", split.nTrain, split.nVal, split.nTest);
    fprintf("训练集脉冲率：%.2f%%，验证集：%.2f%%，测试集：%.2f%%\n", ...
        100 * trainPosRate, 100 * valPosRate, 100 * testPosRate);
    fprintf("开始训练%d轮...\n", opts.epochs);
end

wPos = 0.5 / max(trainPosRate, 1e-6);
wNeg = 0.5 / max(1 - trainPosRate, 1e-6);

XTrain = local_to_network_inputs(trainX);
YTrain = local_to_label_inputs(trainY);
TxRealTrain = local_to_real_imag_inputs(trainTx, "real");
TxImagTrain = local_to_real_imag_inputs(trainTx, "imag");
XVal = local_to_network_inputs(valX);
YVal = local_to_label_inputs(valY);
TxRealVal = local_to_real_imag_inputs(dataset.txClean(split.valIdx), "real");
TxImagVal = local_to_real_imag_inputs(dataset.txClean(split.valIdx), "imag");

averageGrad = [];
averageSqGrad = [];
losses = nan(opts.epochs, 1);
valLosses = nan(opts.epochs, 1);
bestNet = model.net;
bestEpoch = 0;
bestValLoss = inf;
patienceCount = 0;
epochsCompleted = 0;
stoppedEarly = false;

for epoch = 1:opts.epochs
    perm = randperm(numel(XTrain));
    epochLoss = 0;

    for bStart = 1:opts.batchSize:numel(XTrain)
        bEnd = min(bStart + opts.batchSize - 1, numel(XTrain));
        batchIdx = perm(bStart:bEnd);
        batchSize = numel(batchIdx);

        XData = cat(3, XTrain{batchIdx});
        YData = cat(3, YTrain{batchIdx});
        TxRealData = cat(3, TxRealTrain{batchIdx});
        TxImagData = cat(3, TxImagTrain{batchIdx});

        WData = ones(size(YData));
        WData(YData == 1) = wPos;
        WData(YData == 0) = wNeg;

        XDl = dlarray(single(XData), 'CTB');
        YDl = dlarray(single(YData), 'CTB');
        TxRealDl = dlarray(single(TxRealData), 'CTB');
        TxImagDl = dlarray(single(TxImagData), 'CTB');
        WDl = dlarray(single(WData), 'CTB');

        if executionEnvironment == "gpu"
            XDl = gpuArray(XDl);
            YDl = gpuArray(YDl);
            TxRealDl = gpuArray(TxRealDl);
            TxImagDl = gpuArray(TxImagDl);
            WDl = gpuArray(WDl);
        end

        [loss, gradients] = dlfeval(@modelLoss, model.net, XDl, YDl, TxRealDl, TxImagDl, WDl);
        [model.net, averageGrad, averageSqGrad] = adamupdate(model.net, gradients, ...
            averageGrad, averageSqGrad, epoch, opts.lr);

        epochLoss = epochLoss + extractdata(loss) * batchSize;
    end

    epochLoss = epochLoss / numel(XTrain);
    losses(epoch) = epochLoss;
    valLoss = local_eval_sequence_loss(model.net, XVal, YVal, TxRealVal, TxImagVal, ...
        wPos, wNeg, executionEnvironment, @modelLossOnly);
    valLosses(epoch) = valLoss;

    if isfinite(valLoss) && (valLoss < bestValLoss - opts.earlyStoppingMinDelta || bestEpoch == 0)
        bestValLoss = valLoss;
        bestNet = model.net;
        bestEpoch = epoch;
        patienceCount = 0;
    else
        patienceCount = patienceCount + 1;
    end
    epochsCompleted = epoch;

    if opts.verbose && (epoch == 1 || mod(epoch, 5) == 0 || epoch == opts.epochs)
        [valScoresNow, valTruthNow] = ml_collect_detector_scores(valRx, valY, @(r) ml_cnn_impulse_detect(r, model));
        valMetricsNow = ml_binary_metrics(valScoresNow, valTruthNow, 0.5);
        fprintf("第%d/%d轮：trainLoss=%.4f, valLoss=%.4f, Val TPR@0.5=%.3f, Val FPR@0.5=%.3f\n", ...
            epoch, opts.epochs, epochLoss, valLoss, valMetricsNow.tpr, valMetricsNow.fpr);
    end

    if opts.enableEarlyStopping && epoch >= opts.minEpochs && patienceCount >= opts.earlyStoppingPatience
        stoppedEarly = true;
        if opts.verbose
            fprintf("验证集损失连续%d轮未提升，提前停止于第%d轮。\n", opts.earlyStoppingPatience, epoch);
        end
        break;
    end
end

losses = losses(1:epochsCompleted);
valLosses = valLosses(1:epochsCompleted);
model.net = bestNet;

[valScores, valTruth] = ml_collect_detector_scores(valRx, valY, @(r) ml_cnn_impulse_detect(r, model));
[model.threshold, thresholdMetrics, thresholdSelection] = ml_select_threshold_for_pfa(valScores, valTruth, opts.pfaTarget, ...
    "policy", opts.thresholdPolicy, "pfaSlack", opts.thresholdPfaSlack);

[testScores, testTruth] = ml_collect_detector_scores(testRx, testY, @(r) ml_cnn_impulse_detect(r, model));
valMetrics = ml_binary_metrics(valScores, valTruth, model.threshold);
testMetrics = ml_binary_metrics(testScores, testTruth, model.threshold);
model.trained = true;

report = struct();
report.domain = dataset.domain;
report.nBlocks = dataset.nBlocks;
report.blockLen = dataset.blockLen;
report.sampleWindowLen = dataset.sampleWindowLen;
report.nSamples = dataset.nBlocks * dataset.blockLen;
report.ebN0dBRange = dataset.ebN0dBRange;
report.ebN0dBPerBlock = dataset.ebN0dBPerBlock;
report.rngSeed = rngSeed;
report.trainingOptions = opts;
report.trainingContext = ml_capture_training_context(p);
report.reloadContext = ml_capture_reload_context(p);
report.datasetSummary = datasetSummary;
report.channelSampling = dataset.channelSampling;
report.channelProfileSummary = dataset.channelProfileSummary;
report.epochs = opts.epochs;
report.epochsCompleted = epochsCompleted;
report.bestEpoch = bestEpoch;
report.stoppedEarly = stoppedEarly;
report.bestValLoss = bestValLoss;
report.finalLoss = losses(end);
report.finalTrainLoss = losses(end);
report.finalValidationLoss = valLosses(end);
report.losses = losses;
report.validationLosses = valLosses;
report.pfaTarget = opts.pfaTarget;
report.threshold = model.threshold;
report.thresholdMetrics = thresholdMetrics;
report.executionEnvironment = executionEnvironment;
report.split = split;
report.train = struct("posRate", trainPosRate, "wPos", wPos, "wNeg", wNeg);
report.validation = local_pack_metrics_report(valMetrics, valPosRate);
report.test = local_pack_metrics_report(testMetrics, testPosRate);
report.pfaEst = testMetrics.pfa;
report.pdEst = testMetrics.pd;
report.earlyStopping = struct( ...
    "enabled", opts.enableEarlyStopping, ...
    "patience", opts.earlyStoppingPatience, ...
    "minDelta", opts.earlyStoppingMinDelta, ...
    "minEpochs", opts.minEpochs, ...
    "monitor", "validation_loss");
report.selection = thresholdSelection;
report.selection.bestCheckpointBy = "validation_loss";
report.selection.testSetHeldOut = true;
report.artifacts = local_empty_artifacts_report();

if opts.saveArtifacts
    [report, ~] = ml_save_training_artifacts(model, report, "impulse_cnn_model", ...
        "saveDir", opts.saveDir, "saveTag", opts.saveTag, "savedBy", opts.savedBy);
end

if opts.verbose
    fprintf("\n训练完成。\n");
    fprintf("最佳模型来自第%d轮，best val loss=%.4f。\n", bestEpoch, bestValLoss);
    fprintf("验证集：Pd=%.3f, Pfa=%.3f, 阈值=%.3f\n", valMetrics.pd, valMetrics.pfa, model.threshold);
    fprintf("测试集：Pd=%.3f, Pfa=%.3f, Pe=%.3f\n", testMetrics.pd, testMetrics.pfa, testMetrics.pe);
end
end

function feats = local_extract_features(rxSet)
feats = cell(numel(rxSet), 1);
for k = 1:numel(rxSet)
    feats{k} = ml_cnn_features(rxSet{k});
end
end

function featsOut = local_normalize_features(featsIn, mu, sigma)
featsOut = cell(size(featsIn));
for k = 1:numel(featsIn)
    featsOut{k} = (featsIn{k} - mu) ./ sigma;
end
end

function arr = local_to_network_inputs(featsIn)
arr = cell(numel(featsIn), 1);
for k = 1:numel(featsIn)
    arr{k} = featsIn{k}.';
end
end

function arr = local_to_label_inputs(labelsIn)
arr = cell(numel(labelsIn), 1);
for k = 1:numel(labelsIn)
    arr{k} = double(labelsIn{k}).';
end
end

function arr = local_to_real_imag_inputs(symSet, part)
arr = cell(numel(symSet), 1);
for k = 1:numel(symSet)
    switch part
        case "real"
            arr{k} = real(symSet{k}).';
        case "imag"
            arr{k} = imag(symSet{k}).';
        otherwise
            error("未知部分: %s", part);
    end
end
end

function rate = local_positive_rate(labelSet)
if isempty(labelSet)
    rate = NaN;
else
    rate = mean(cell2mat(cellfun(@double, labelSet, 'UniformOutput', false)));
end
end

function out = local_pack_metrics_report(metrics, posRate)
out = metrics;
out.posRate = posRate;
end

function out = local_empty_artifacts_report()
out = struct( ...
    "saved", false, ...
    "saveDir", "", ...
    "latestPath", "", ...
    "batchPath", "", ...
    "batchTag", "", ...
    "savedAt", "", ...
    "savedBy", "");
end

function lossVal = local_eval_sequence_loss(net, XSet, YSet, TxRealSet, TxImagSet, wPos, wNeg, executionEnvironment, lossFn)
totalLoss = 0;
for k = 1:numel(XSet)
    XData = XSet{k};
    YData = YSet{k};
    TxRealData = TxRealSet{k};
    TxImagData = TxImagSet{k};

    WData = ones(size(YData), 'single');
    WData(YData == 1) = wPos;
    WData(YData == 0) = wNeg;

    XDl = dlarray(single(XData), 'CTB');
    YDl = dlarray(single(YData), 'CTB');
    TxRealDl = dlarray(single(TxRealData), 'CTB');
    TxImagDl = dlarray(single(TxImagData), 'CTB');
    WDl = dlarray(single(WData), 'CTB');

    if executionEnvironment == "gpu"
        XDl = gpuArray(XDl);
        YDl = gpuArray(YDl);
        TxRealDl = gpuArray(TxRealDl);
        TxImagDl = gpuArray(TxImagDl);
        WDl = gpuArray(WDl);
    end

    loss = dlfeval(lossFn, net, XDl, YDl, TxRealDl, TxImagDl, WDl);
    totalLoss = totalLoss + double(gather(extractdata(loss)));
end
lossVal = totalLoss / max(numel(XSet), 1);
end

function loss = modelLossOnly(net, X, Y, TxReal, TxImag, W)
out = forward(net, X);

pImpulse = sigmoid(out(1,:,:));
reliability = sigmoid(out(2,:,:));
cleanReal = out(3,:,:);
cleanImag = out(4,:,:);

bce = -W .* (Y .* log(pImpulse + 1e-8) + (1 - Y) .* log(1 - pImpulse + 1e-8));
lossBce = mean(bce, 'all');

mse = (cleanReal - TxReal).^2 + (cleanImag - TxImag).^2;
lossMse = mean(mse, 'all');

relTarget = 1 - Y;
relLoss = (reliability - relTarget).^2;
lossRel = mean(relLoss, 'all');

loss = 1.0 * lossBce + 0.5 * lossMse + 0.3 * lossRel;
end

function [loss, gradients] = modelLoss(net, X, Y, TxReal, TxImag, W)
out = forward(net, X);

pImpulse = sigmoid(out(1,:,:));
reliability = sigmoid(out(2,:,:));
cleanReal = out(3,:,:);
cleanImag = out(4,:,:);

bce = -W .* (Y .* log(pImpulse + 1e-8) + (1 - Y) .* log(1 - pImpulse + 1e-8));
lossBce = mean(bce, 'all');

mse = (cleanReal - TxReal).^2 + (cleanImag - TxImag).^2;
lossMse = mean(mse, 'all');

relTarget = 1 - Y;
relLoss = (reliability - relTarget).^2;
lossRel = mean(relLoss, 'all');

loss = 1.0 * lossBce + 0.5 * lossMse + 0.3 * lossRel;
gradients = dlgradient(loss, net.Learnables);
end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-x));
end
