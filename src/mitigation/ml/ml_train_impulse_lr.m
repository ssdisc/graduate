function [model, report] = ml_train_impulse_lr(p, opts)
%ML_TRAIN_IMPULSE_LR  训练带 train/val/test 划分的采样级逻辑回归脉冲检测器。

arguments
    p (1,1) struct
    opts.nBlocks (1,1) double {mustBePositive} = 200
    opts.blockLen (1,1) double {mustBeInteger, mustBePositive} = 4096 % 采样窗口长度
    opts.ebN0dBRange (1,2) double = [0 10]
    opts.pfaTarget (1,1) double = 0.01
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 25
    opts.batchSize (1,1) double {mustBeInteger, mustBePositive} = 65536
    opts.lr (1,1) double {mustBePositive} = 0.2
    opts.l2 (1,1) double {mustBeNonnegative} = 1e-3
    opts.valFraction (1,1) double = 0.15
    opts.testFraction (1,1) double = 0.15
    opts.splitSeed (1,1) double = 1
    opts.rngSeed (1,1) double = NaN
    opts.enableEarlyStopping (1,1) logical = true
    opts.earlyStoppingPatience (1,1) double {mustBeInteger, mustBePositive} = 5
    opts.earlyStoppingMinDelta (1,1) double {mustBeNonnegative} = 1e-5
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
    opts.narrowbandCenterHzRange (1,2) double = [NaN NaN]
    opts.narrowbandBandwidthHzRange (1,2) double = [NaN NaN]
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
    opts.verbose (1,1) logical = true
end

if ~(opts.pfaTarget > 0 && opts.pfaTarget < 1)
    error("pfaTarget must be in (0,1).");
end
if ~(opts.valFraction > 0 && opts.valFraction < 1)
    error("valFraction 必须在 (0,1) 内。");
end
if ~(opts.testFraction > 0 && opts.testFraction < 1)
    error("testFraction 必须在 (0,1) 内。");
end

rngSeed = ml_resolve_rng_seed(p, opts.rngSeed);
rngScope = ml_rng_scope(rngSeed); %#ok<NASGU>

if opts.verbose
    fprintf("正在为LR生成训练/验证/测试数据...\n");
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
    "narrowbandCenterHzRange", opts.narrowbandCenterHzRange, ...
    "narrowbandBandwidthHzRange", opts.narrowbandBandwidthHzRange, ...
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
    error("当前LR训练流程要求独立的验证集和测试集，请增大 nBlocks 或调整 val/test 占比。");
end

allFeat = cell(numel(dataset.rxInput), 1);
for b = 1:numel(dataset.rxInput)
    allFeat{b} = ml_impulse_features(dataset.rxInput{b});
end

XTrain = cell2mat(allFeat(split.trainIdx));
XVal = cell2mat(allFeat(split.valIdx));
XTest = cell2mat(allFeat(split.testIdx));
yTrain = logical(cell2mat(dataset.impMask(split.trainIdx)));
yVal = logical(cell2mat(dataset.impMask(split.valIdx)));
yTest = logical(cell2mat(dataset.impMask(split.testIdx)));

mu = mean(XTrain, 1);
sigma = std(XTrain, 0, 1);
sigma(sigma == 0) = 1;

XnTrain = (double(XTrain) - mu) ./ sigma;
XnVal = (double(XVal) - mu) ./ sigma;
XnTest = (double(XTest) - mu) ./ sigma;

trainPos = yTrain;
trainNeg = ~yTrain;
trainPosRate = mean(trainPos);
valPosRate = mean(yVal);
testPosRate = mean(yTest);
wPos = 0.5 / max(trainPosRate, eps);
wNeg = 0.5 / max(1 - trainPosRate, eps);
weights = ones(numel(yTrain), 1);
weights(trainPos) = wPos;
weights(trainNeg) = wNeg;

if opts.verbose
    fprintf("训练标签总体正样本率：%.2f%%（块均值 %.2f%%，范围 %.2f%%~%.2f%%）\n", ...
        100 * datasetSummary.overallPosRate, ...
        100 * datasetSummary.blockPosRateMean, ...
        100 * datasetSummary.blockPosRateMin, ...
        100 * datasetSummary.blockPosRateMax);
    fprintf("数据划分：train=%d, val=%d, test=%d\n", split.nTrain, split.nVal, split.nTest);
    fprintf("训练集脉冲率：%.2f%%，验证集：%.2f%%，测试集：%.2f%%\n", ...
        100 * trainPosRate, 100 * valPosRate, 100 * testPosRate);
end

w = zeros(size(XnTrain, 2), 1);
b = 0;
bestW = w;
bestB = b;
bestEpoch = 0;
bestValLoss = inf;
patienceCount = 0;
epochsCompleted = 0;
stoppedEarly = false;
trainLosses = nan(opts.epochs, 1);
valLosses = nan(opts.epochs, 1);

for epoch = 1:opts.epochs
    perm = randperm(size(XnTrain, 1));
    for start = 1:opts.batchSize:size(XnTrain, 1)
        stop = min(start + opts.batchSize - 1, size(XnTrain, 1));
        sel = perm(start:stop);

        xb = XnTrain(sel, :);
        yb = double(yTrain(sel));
        wb = weights(sel);

        logit = xb * w + b;
        logit = max(min(logit, 30), -30);
        pHat = 1 ./ (1 + exp(-logit));

        diff = (pHat - yb) .* wb;
        gw = (xb.' * diff) / numel(sel) + opts.l2 * w;
        gb = mean(diff);

        w = w - opts.lr * gw;
        b = b - opts.lr * gb;
    end

    trainLossNow = local_lr_weighted_bce(XnTrain, yTrain, w, b, wPos, wNeg, opts.l2);
    valLossNow = local_lr_weighted_bce(XnVal, yVal, w, b, wPos, wNeg, 0);
    trainLosses(epoch) = trainLossNow;
    valLosses(epoch) = valLossNow;

    if isfinite(valLossNow) && (valLossNow < bestValLoss - opts.earlyStoppingMinDelta || bestEpoch == 0)
        bestValLoss = valLossNow;
        bestW = w;
        bestB = b;
        bestEpoch = epoch;
        patienceCount = 0;
    else
        patienceCount = patienceCount + 1;
    end
    epochsCompleted = epoch;

    if opts.verbose && (epoch == 1 || mod(epoch, 5) == 0 || epoch == opts.epochs)
        pValNow = local_lr_predict(XnVal, w, b);
        valMetricsNow = ml_binary_metrics(pValNow, yVal, 0.5);
        fprintf("epoch %d/%d: trainLoss=%.4f, valLoss=%.4f, Val TPR@0.5=%.3f, Val FPR@0.5=%.3f\n", ...
            epoch, opts.epochs, trainLossNow, valLossNow, valMetricsNow.tpr, valMetricsNow.fpr);
    end

    if opts.enableEarlyStopping && epoch >= opts.minEpochs && patienceCount >= opts.earlyStoppingPatience
        stoppedEarly = true;
        if opts.verbose
            fprintf("验证集损失连续%d轮未提升，提前停止于第%d轮。\n", opts.earlyStoppingPatience, epoch);
        end
        break;
    end
end

w = bestW;
b = bestB;
trainLosses = trainLosses(1:epochsCompleted);
valLosses = valLosses(1:epochsCompleted);

pVal = local_lr_predict(XnVal, w, b);
[threshold, thresholdMetrics, thresholdSelection] = ml_select_threshold_for_pfa(pVal, yVal, opts.pfaTarget, ...
    "policy", opts.thresholdPolicy, "pfaSlack", opts.thresholdPfaSlack);
pTest = local_lr_predict(XnTest, w, b);

valMetrics = ml_binary_metrics(pVal, yVal, threshold);
testMetrics = ml_binary_metrics(pTest, yTest, threshold);

model = ml_impulse_lr_model();
model.trained = true;
model.mu = mu(:);
model.sigma = sigma(:);
model.w = w(:);
model.b = b;
model.threshold = threshold;

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
report.datasetSummary = datasetSummary;
report.channelSampling = dataset.channelSampling;
report.channelProfileSummary = dataset.channelProfileSummary;
report.pfaTarget = opts.pfaTarget;
report.epochs = opts.epochs;
report.epochsCompleted = epochsCompleted;
report.bestEpoch = bestEpoch;
report.stoppedEarly = stoppedEarly;
report.bestValLoss = bestValLoss;
report.batchSize = opts.batchSize;
report.lr = opts.lr;
report.l2 = opts.l2;
report.finalTrainLoss = trainLosses(end);
report.finalValidationLoss = valLosses(end);
report.trainLosses = trainLosses;
report.validationLosses = valLosses;
report.split = split;
report.train = struct("posRate", trainPosRate, "wPos", wPos, "wNeg", wNeg);
report.validation = local_pack_metrics_report(valMetrics, valPosRate);
report.test = local_pack_metrics_report(testMetrics, testPosRate);
report.threshold = threshold;
report.thresholdMetrics = thresholdMetrics;
report.pfaEst = testMetrics.pfa;
report.pdEst = testMetrics.pd;
report.peEst = testMetrics.pe;
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
    [report, ~] = ml_save_training_artifacts(model, report, "impulse_lr_model", ...
        "saveDir", opts.saveDir, "saveTag", opts.saveTag, "savedBy", opts.savedBy);
end

if opts.verbose
    fprintf("LR训练完成。\n");
    fprintf("最佳模型来自第%d轮，best val loss=%.4f。\n", bestEpoch, bestValLoss);
    fprintf("验证集：Pd=%.3f, Pfa=%.3f, 阈值=%.3f\n", valMetrics.pd, valMetrics.pfa, threshold);
    fprintf("测试集：Pd=%.3f, Pfa=%.3f, Pe=%.3f\n", testMetrics.pd, testMetrics.pfa, testMetrics.pe);
end
end

function p = local_lr_predict(Xn, w, b)
logit = Xn * w + b;
logit = max(min(logit, 30), -30);
p = 1 ./ (1 + exp(-logit));
end

function loss = local_lr_weighted_bce(Xn, y, w, b, wPos, wNeg, l2)
scores = local_lr_predict(Xn, w, b);
weights = ones(numel(y), 1);
weights(y) = wPos;
weights(~y) = wNeg;
lossVec = -weights .* (double(y) .* log(scores + 1e-8) + (1 - double(y)) .* log(1 - scores + 1e-8));
loss = mean(lossVec) + 0.5 * l2 * sum(w.^2);
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
