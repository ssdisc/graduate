function [model, report] = ml_train_fh_erasure(p, opts)
%ML_TRAIN_FH_ERASURE  Train a per-hop ML model for FH soft erasure.

arguments
    p (1,1) struct
    opts.nBlocks (1,1) double {mustBeInteger, mustBePositive} = 600
    opts.ebN0dBRange (1,2) double = [-4 16]
    opts.hopsPerBlockRange (1,2) double {mustBePositive} = [64 256]
    opts.jsrDbRange (1,2) double = [-12 3]
    opts.narrowbandProbability (1,1) double = 0.90
    opts.bandwidthFreqPointsRange (1,2) double {mustBePositive} = [0.6 1.4]
    opts.centerFreqPointsRange (1,2) double = [NaN NaN]
    opts.configuredCenterProbability (1,1) double = 0.35
    opts.minOverlapFraction (1,1) double = 0.15
    opts.badHopErrorRateThreshold (1,1) double = 0.22
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 45
    opts.batchSize (1,1) double {mustBeInteger, mustBePositive} = 128
    opts.lr (1,1) double {mustBePositive} = 0.001
    opts.valFraction (1,1) double = 0.15
    opts.testFraction (1,1) double = 0.15
    opts.splitSeed (1,1) double = 1
    opts.rngSeed (1,1) double = NaN
    opts.enableEarlyStopping (1,1) logical = true
    opts.earlyStoppingPatience (1,1) double {mustBeInteger, mustBePositive} = 6
    opts.earlyStoppingMinDelta (1,1) double {mustBeNonnegative} = 1e-4
    opts.minEpochs (1,1) double {mustBeInteger, mustBePositive} = 6
    opts.saveArtifacts (1,1) logical = false
    opts.saveDir (1,1) string = "models"
    opts.saveTag (1,1) string = ""
    opts.savedBy (1,1) string = ""
    opts.useGpu (1,1) logical = true
    opts.verbose (1,1) logical = true
end

if ~(opts.valFraction > 0 && opts.valFraction < 1)
    error("valFraction must be in (0, 1).");
end
if ~(opts.testFraction > 0 && opts.testFraction < 1)
    error("testFraction must be in (0, 1).");
end

rngSeed = ml_resolve_rng_seed(p, opts.rngSeed);
rngScope = ml_rng_scope(rngSeed); %#ok<NASGU>

if opts.useGpu && canUseGPU()
    executionEnvironment = "gpu";
    if opts.verbose
        fprintf("使用GPU训练FH软擦除模型\n");
    end
else
    executionEnvironment = "cpu";
    if opts.verbose
        fprintf("使用CPU训练FH软擦除模型\n");
    end
end

dataset = ml_generate_fh_erasure_dataset(p, opts.nBlocks, opts.ebN0dBRange, ...
    "hopsPerBlockRange", opts.hopsPerBlockRange, ...
    "jsrDbRange", opts.jsrDbRange, ...
    "narrowbandProbability", opts.narrowbandProbability, ...
    "bandwidthFreqPointsRange", opts.bandwidthFreqPointsRange, ...
    "centerFreqPointsRange", opts.centerFreqPointsRange, ...
    "configuredCenterProbability", opts.configuredCenterProbability, ...
    "minOverlapFraction", opts.minOverlapFraction, ...
    "badHopErrorRateThreshold", opts.badHopErrorRateThreshold, ...
    "verbose", opts.verbose);
split = ml_split_dataset_indices(dataset.nHops, opts.valFraction, opts.testFraction, opts.splitSeed);
if split.nVal < 1 || split.nTest < 1
    error("FH软擦除训练需要独立验证集和测试集，请增大nBlocks或调整val/test占比。");
end

XTrain = dataset.featureMatrix(split.trainIdx, :);
XVal = dataset.featureMatrix(split.valIdx, :);
XTest = dataset.featureMatrix(split.testIdx, :);
yTrain = dataset.labelIndex(split.trainIdx);
yVal = dataset.labelIndex(split.valIdx);
yTest = dataset.labelIndex(split.testIdx);
classNames = dataset.classNames;
nClasses = numel(classNames);

inputMean = mean(XTrain, 1);
inputStd = std(XTrain, 0, 1);
inputStd(inputStd < 1e-6) = 1;

XTrain = (XTrain - inputMean) ./ inputStd;
XVal = (XVal - inputMean) ./ inputStd;
XTest = (XTest - inputMean) ./ inputStd;

model = ml_fh_erasure_model();
model.inputMean = inputMean;
model.inputStd = inputStd;
model.minReliability = double(p.mitigation.fhErasure.minReliability);

classCountTrain = accumarray(yTrain(:), 1, [nClasses 1], @sum, 0);
if any(classCountTrain == 0)
    error("FH软擦除训练集缺少类别样本，classCounts=%s。", mat2str(classCountTrain(:).'));
end
classWeights = sum(classCountTrain) ./ max(classCountTrain, 1);
classWeights = classWeights / mean(classWeights);

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
    perm = randperm(size(XTrain, 1));
    epochLoss = 0;
    for bStart = 1:opts.batchSize:size(XTrain, 1)
        bEnd = min(bStart + opts.batchSize - 1, size(XTrain, 1));
        batchIdx = perm(bStart:bEnd);
        XBatch = dlarray(single(XTrain(batchIdx, :).'), "CB");
        yBatch = double(yTrain(batchIdx));
        if executionEnvironment == "gpu"
            XBatch = gpuArray(XBatch);
        end

        [loss, gradients] = dlfeval(@local_fh_erasure_loss, model.net, XBatch, yBatch, classWeights, nClasses);
        [model.net, averageGrad, averageSqGrad] = adamupdate(model.net, gradients, ...
            averageGrad, averageSqGrad, epoch, opts.lr);
        epochLoss = epochLoss + extractdata(loss) * numel(batchIdx);
    end

    epochLoss = epochLoss / size(XTrain, 1);
    losses(epoch) = epochLoss;
    valLoss = local_eval_fh_erasure_loss(model.net, XVal, yVal, classWeights, nClasses, executionEnvironment);
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
        valMetricsNow = local_fh_erasure_metrics(model.net, XVal, yVal, classNames);
        fprintf("第%d/%d轮：trainLoss=%.4f, valLoss=%.4f, Val Acc=%.3f, Bad Recall=%.3f\n", ...
            epoch, opts.epochs, epochLoss, valLoss, valMetricsNow.accuracy, valMetricsNow.badRecall);
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
model.trained = true;

valMetrics = local_fh_erasure_metrics(model.net, XVal, yVal, classNames);
testMetrics = local_fh_erasure_metrics(model.net, XTest, yTest, classNames);

report = struct();
report.nBlocks = dataset.nBlocks;
report.nHops = dataset.nHops;
report.ebN0dBRange = dataset.ebN0dBRange;
report.hopsPerBlockRange = opts.hopsPerBlockRange;
report.jsrDbRange = opts.jsrDbRange;
report.bandwidthFreqPointsRange = opts.bandwidthFreqPointsRange;
report.centerFreqPointsRange = opts.centerFreqPointsRange;
report.configuredCenterProbability = opts.configuredCenterProbability;
report.rngSeed = rngSeed;
report.trainingOptions = opts;
report.trainingContext = ml_capture_fh_erasure_reload_context(p);
report.reloadContext = report.trainingContext;
report.featureNames = dataset.featureNames;
report.classNames = dataset.classNames;
report.classCounts = dataset.classCounts;
report.epochs = opts.epochs;
report.epochsCompleted = epochsCompleted;
report.bestEpoch = bestEpoch;
report.stoppedEarly = stoppedEarly;
report.bestValLoss = bestValLoss;
report.finalTrainLoss = losses(end);
report.finalValidationLoss = valLosses(end);
report.losses = losses;
report.validationLosses = valLosses;
report.executionEnvironment = executionEnvironment;
report.split = split;
report.train = struct("classCounts", classCountTrain, "classWeights", classWeights);
report.validation = valMetrics;
report.test = testMetrics;
report.selection = struct("bestCheckpointBy", "validation_loss", "testSetHeldOut", true);
report.artifacts = local_empty_artifacts_report();

if opts.saveArtifacts
    [report, ~] = ml_save_training_artifacts(model, report, "fh_erasure_model", ...
        "saveDir", opts.saveDir, "saveTag", opts.saveTag, "savedBy", opts.savedBy);
end

if opts.verbose
    fprintf("\nFH软擦除模型训练完成。\n");
    fprintf("最佳模型来自第%d轮，best val loss=%.4f。\n", bestEpoch, bestValLoss);
    fprintf("验证集准确率=%.3f，测试集准确率=%.3f，测试Bad Recall=%.3f。\n", ...
        valMetrics.accuracy, testMetrics.accuracy, testMetrics.badRecall);
end
end

function [loss, gradients] = local_fh_erasure_loss(net, XBatch, yBatch, classWeights, nClasses)
scores = forward(net, XBatch);
Y = local_one_hot(yBatch, nClasses);
YDl = dlarray(single(Y), "CB");
if isa(XBatch, "gpuArray")
    YDl = gpuArray(YDl);
end
sampleWeights = classWeights(yBatch(:)).';
weightDl = dlarray(single(sampleWeights), "CB");
if isa(XBatch, "gpuArray")
    weightDl = gpuArray(weightDl);
end
loss = local_cross_entropy_loss(scores, YDl, weightDl);
gradients = dlgradient(loss, net.Learnables);
end

function loss = local_eval_fh_erasure_loss(net, XVal, yVal, classWeights, nClasses, executionEnvironment)
if isempty(XVal)
    loss = NaN;
    return;
end
X = dlarray(single(XVal.'), "CB");
Y = dlarray(single(local_one_hot(yVal, nClasses)), "CB");
W = dlarray(single(classWeights(yVal(:)).'), "CB");
if executionEnvironment == "gpu"
    X = gpuArray(X);
    Y = gpuArray(Y);
    W = gpuArray(W);
end
scores = predict(net, X);
loss = double(gather(extractdata(local_cross_entropy_loss(scores, Y, W))));
end

function metrics = local_fh_erasure_metrics(net, X, y, classNames)
prob = local_predict_probabilities(net, X);
[~, predIdx] = max(prob, [], 2);
confMat = zeros(numel(classNames), numel(classNames));
for k = 1:numel(y)
    confMat(y(k), predIdx(k)) = confMat(y(k), predIdx(k)) + 1;
end
badIdx = find(classNames == "bad", 1, "first");
badTp = confMat(badIdx, badIdx);
badTotal = sum(confMat(badIdx, :));
badPred = sum(confMat(:, badIdx));
metrics = struct();
metrics.accuracy = mean(predIdx == y);
metrics.confusionMatrix = confMat;
metrics.classNames = classNames;
metrics.badRecall = badTp / max(badTotal, 1);
metrics.badPrecision = badTp / max(badPred, 1);
end

function prob = local_predict_probabilities(net, X)
if isempty(X)
    prob = zeros(0, 0);
    return;
end
scores = predict(net, dlarray(single(X.'), "CB"));
scores = double(extractdata(scores));
scores = scores - max(scores, [], 1);
expScores = exp(max(min(scores, 30), -30));
prob = (expScores ./ max(sum(expScores, 1), eps)).';
end

function Y = local_one_hot(y, nClasses)
y = double(y(:));
Y = zeros(nClasses, numel(y), "single");
for k = 1:numel(y)
    Y(y(k), k) = 1;
end
end

function loss = local_cross_entropy_loss(scores, Y, sampleWeights)
scores = scores - max(scores, [], 1);
expScores = exp(scores);
prob = expScores ./ max(sum(expScores, 1), eps);
ce = -sum(Y .* log(prob + 1e-8), 1);
loss = sum(ce .* sampleWeights, "all") / max(sum(sampleWeights, "all"), eps);
end

function artifacts = local_empty_artifacts_report()
artifacts = struct( ...
    "saved", false, ...
    "saveDir", "", ...
    "latestPath", "", ...
    "batchPath", "", ...
    "batchTag", "", ...
    "savedAt", "", ...
    "savedBy", "");
end
