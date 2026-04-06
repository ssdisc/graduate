function [model, report] = ml_train_interference_selector(p, opts)
%ML_TRAIN_INTERFERENCE_SELECTOR  Train a frame-level MLP selector for dominant interference class.

arguments
    p (1,1) struct
    opts.nBlocks (1,1) double {mustBePositive} = 900
    opts.dataSymbolsPerBlock (1,1) double {mustBeInteger, mustBePositive} = 512
    opts.ebN0dBRange (1,2) double = [-2 14]
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 40
    opts.batchSize (1,1) double {mustBeInteger, mustBePositive} = 64
    opts.lr (1,1) double {mustBePositive} = 0.001
    opts.valFraction (1,1) double = 0.15
    opts.testFraction (1,1) double = 0.15
    opts.splitSeed (1,1) double = 1
    opts.rngSeed (1,1) double = NaN
    opts.enableEarlyStopping (1,1) logical = true
    opts.earlyStoppingPatience (1,1) double {mustBeInteger, mustBePositive} = 5
    opts.earlyStoppingMinDelta (1,1) double {mustBeNonnegative} = 1e-4
    opts.minEpochs (1,1) double {mustBeInteger, mustBePositive} = 5
    opts.maxRetriesPerBlock (1,1) double {mustBeInteger, mustBePositive} = 8
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
        fprintf("使用GPU训练干扰选择器\n");
    end
else
    executionEnvironment = "cpu";
    if opts.verbose
        fprintf("使用CPU训练干扰选择器\n");
    end
end

dataset = ml_generate_interference_selector_dataset(p, opts.nBlocks, opts.dataSymbolsPerBlock, opts.ebN0dBRange, ...
    "maxRetriesPerBlock", opts.maxRetriesPerBlock, "verbose", opts.verbose);
split = ml_split_dataset_indices(dataset.nBlocks, opts.valFraction, opts.testFraction, opts.splitSeed);
if split.nVal < 1 || split.nTest < 1
    error("当前选择器训练流程要求独立的验证集和测试集，请增大 nBlocks 或调整 val/test 占比。");
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

model = ml_interference_selector_model();
model.inputMean = inputMean;
model.inputStd = inputStd;

classCountTrain = accumarray(yTrain(:), 1, [nClasses 1], @sum, 0);
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

        [loss, gradients] = dlfeval(@local_selector_loss, model.net, XBatch, yBatch, classWeights, nClasses);
        [model.net, averageGrad, averageSqGrad] = adamupdate(model.net, gradients, ...
            averageGrad, averageSqGrad, epoch, opts.lr);
        epochLoss = epochLoss + extractdata(loss) * numel(batchIdx);
    end

    epochLoss = epochLoss / size(XTrain, 1);
    losses(epoch) = epochLoss;
    valLoss = local_eval_selector_loss(model.net, XVal, yVal, classWeights, nClasses, executionEnvironment);
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
        valMetricsNow = local_selector_metrics(model.net, XVal, yVal, classNames);
        fprintf("第%d/%d轮：trainLoss=%.4f, valLoss=%.4f, Val Acc=%.3f\n", ...
            epoch, opts.epochs, epochLoss, valLoss, valMetricsNow.accuracy);
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

valMetrics = local_selector_metrics(model.net, XVal, yVal, classNames);
testMetrics = local_selector_metrics(model.net, XTest, yTest, classNames);

report = struct();
report.nBlocks = dataset.nBlocks;
report.dataSymbolsPerBlock = dataset.dataSymbolsPerBlock;
report.ebN0dBRange = dataset.ebN0dBRange;
report.rngSeed = rngSeed;
report.trainingOptions = opts;
report.trainingContext = ml_capture_training_context(p);
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
    [report, ~] = ml_save_training_artifacts(model, report, "interference_selector_model", ...
        "saveDir", opts.saveDir, "saveTag", opts.saveTag, "savedBy", opts.savedBy);
end

if opts.verbose
    fprintf("\n干扰选择器训练完成。\n");
    fprintf("最佳模型来自第%d轮，best val loss=%.4f。\n", bestEpoch, bestValLoss);
    fprintf("验证集准确率=%.3f，测试集准确率=%.3f。\n", valMetrics.accuracy, testMetrics.accuracy);
end
end

function [loss, gradients] = local_selector_loss(net, XBatch, yBatch, classWeights, nClasses)
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

function loss = local_eval_selector_loss(net, XVal, yVal, classWeights, nClasses, executionEnvironment)
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

function metrics = local_selector_metrics(net, X, y, classNames)
prob = local_predict_probabilities(net, X);
[~, predIdx] = max(prob, [], 2);
confMat = zeros(numel(classNames), numel(classNames));
for k = 1:numel(y)
    confMat(y(k), predIdx(k)) = confMat(y(k), predIdx(k)) + 1;
end
metrics = struct();
metrics.accuracy = mean(predIdx == y);
metrics.confusionMatrix = confMat;
metrics.classNames = classNames;
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
