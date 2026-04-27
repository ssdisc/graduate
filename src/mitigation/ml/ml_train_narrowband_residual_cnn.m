function [model, report] = ml_train_narrowband_residual_cnn(p, opts)
%ML_TRAIN_NARROWBAND_RESIDUAL_CNN Train narrowband post-excision residual CNN.

arguments
    p (1,1) struct
    opts.nBlocks (1,1) double {mustBeInteger, mustBePositive} = 160
    opts.blockLen (1,1) double {mustBeInteger, mustBePositive} = 512
    opts.ebN0dBRange (1,2) double = [4 10]
    opts.jsrDbRange (1,2) double = [-1 3]
    opts.centerFreqPointsList double = -3:0.5:3
    opts.bandwidthFreqPointsList double = 1.0
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 8
    opts.batchSize (1,1) double {mustBeInteger, mustBePositive} = 16
    opts.lr (1,1) double {mustBePositive} = 0.001
    opts.valFraction (1,1) double = 0.15
    opts.testFraction (1,1) double = 0.15
    opts.splitSeed (1,1) double = 1
    opts.rngSeed (1,1) double = NaN
    opts.targetClipNorm (1,1) double {mustBePositive} = 2.0
    opts.errorWeightSlope (1,1) double {mustBeNonnegative} = 2.0
    opts.enableEarlyStopping (1,1) logical = true
    opts.earlyStoppingPatience (1,1) double {mustBeInteger, mustBePositive} = 3
    opts.earlyStoppingMinDelta (1,1) double {mustBeNonnegative} = 1e-4
    opts.minEpochs (1,1) double {mustBeInteger, mustBePositive} = 3
    opts.useGpu (1,1) logical = true
    opts.saveArtifacts (1,1) logical = false
    opts.saveDir (1,1) string = "models"
    opts.saveTag (1,1) string = ""
    opts.savedBy (1,1) string = ""
    opts.verbose (1,1) logical = true
end

if ~(opts.valFraction > 0 && opts.valFraction < 1)
    error("valFraction must be in (0,1).");
end
if ~(opts.testFraction > 0 && opts.testFraction < 1)
    error("testFraction must be in (0,1).");
end

rngSeed = ml_resolve_rng_seed(p, opts.rngSeed);
rngScope = ml_rng_scope(rngSeed); %#ok<NASGU>

if opts.useGpu && canUseGPU()
    executionEnvironment = "gpu";
else
    executionEnvironment = "cpu";
end
if opts.verbose
    fprintf("Narrowband residual CNN training on %s.\n", executionEnvironment);
end

dataset = ml_generate_narrowband_residual_blocks(p, opts.nBlocks, opts.blockLen, ...
    "ebN0dBRange", opts.ebN0dBRange, ...
    "jsrDbRange", opts.jsrDbRange, ...
    "centerFreqPointsList", opts.centerFreqPointsList, ...
    "bandwidthFreqPointsList", opts.bandwidthFreqPointsList, ...
    "targetClipNorm", opts.targetClipNorm, ...
    "errorWeightSlope", opts.errorWeightSlope, ...
    "verbose", opts.verbose);

split = ml_split_dataset_indices(dataset.nBlocks, opts.valFraction, opts.testFraction, opts.splitSeed);
if split.nVal < 1 || split.nTest < 1
    error("Need non-empty validation and test sets. Increase nBlocks or adjust split fractions.");
end

trainX = dataset.inputFeatures(split.trainIdx);
valX = dataset.inputFeatures(split.valIdx);
testX = dataset.inputFeatures(split.testIdx);
trainY = dataset.targetResidual(split.trainIdx);
valY = dataset.targetResidual(split.valIdx);
testY = dataset.targetResidual(split.testIdx);
trainW = dataset.sampleWeight(split.trainIdx);
valW = dataset.sampleWeight(split.valIdx);
testW = dataset.sampleWeight(split.testIdx);

allTrainX = cell2mat(trainX);
inputMean = mean(allTrainX, 1);
inputStd = std(allTrainX, 0, 1);
inputStd(inputStd < 1e-6) = 1;
trainX = local_normalize_feature_cells_local(trainX, inputMean, inputStd);
valX = local_normalize_feature_cells_local(valX, inputMean, inputStd);
testX = local_normalize_feature_cells_local(testX, inputMean, inputStd);

model = ml_narrowband_residual_cnn_model();
model.inputMean = inputMean;
model.inputStd = inputStd;

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
    perm = randperm(numel(trainX));
    epochLoss = 0;
    epochSamples = 0;
    for bStart = 1:opts.batchSize:numel(trainX)
        bEnd = min(bStart + opts.batchSize - 1, numel(trainX));
        batchIdx = perm(bStart:bEnd);
        [XDl, YDl, WDl] = local_batch_dlarray_local(trainX, trainY, trainW, batchIdx, executionEnvironment);
        [loss, gradients] = dlfeval(@local_weighted_mse_loss_local, model.net, XDl, YDl, WDl);
        [model.net, averageGrad, averageSqGrad] = adamupdate(model.net, gradients, ...
            averageGrad, averageSqGrad, epoch, opts.lr);
        nNow = numel(batchIdx) * opts.blockLen;
        epochLoss = epochLoss + double(gather(extractdata(loss))) * nNow;
        epochSamples = epochSamples + nNow;
    end

    losses(epoch) = epochLoss / max(epochSamples, 1);
    valLoss = local_eval_loss_local(model.net, valX, valY, valW, executionEnvironment, opts.batchSize);
    valLosses(epoch) = valLoss;
    if isfinite(valLoss) && (bestEpoch == 0 || valLoss < bestValLoss - opts.earlyStoppingMinDelta)
        bestValLoss = valLoss;
        bestNet = model.net;
        bestEpoch = epoch;
        patienceCount = 0;
    else
        patienceCount = patienceCount + 1;
    end
    epochsCompleted = epoch;

    if opts.verbose
        fprintf("NB residual epoch %d/%d: trainLoss=%.5f valLoss=%.5f\n", ...
            epoch, opts.epochs, losses(epoch), valLoss);
    end
    if opts.enableEarlyStopping && epoch >= opts.minEpochs && patienceCount >= opts.earlyStoppingPatience
        stoppedEarly = true;
        break;
    end
end

model.net = bestNet;
model.trained = true;

testLoss = local_eval_loss_local(model.net, testX, testY, testW, executionEnvironment, opts.batchSize);
report = struct();
report.nBlocks = dataset.nBlocks;
report.blockLen = dataset.blockLen;
report.rngSeed = rngSeed;
report.trainingOptions = opts;
report.executionEnvironment = executionEnvironment;
report.split = split;
report.epochs = opts.epochs;
report.epochsCompleted = epochsCompleted;
report.bestEpoch = bestEpoch;
report.stoppedEarly = stoppedEarly;
report.bestValLoss = bestValLoss;
report.testLoss = testLoss;
report.losses = losses(1:epochsCompleted);
report.validationLosses = valLosses(1:epochsCompleted);
report.featureNames = dataset.featureNames;
report.centerFreqPointsList = opts.centerFreqPointsList;
report.bandwidthFreqPointsList = opts.bandwidthFreqPointsList;
report.trainingContext = ml_capture_training_context(p);
report.reloadContext = local_residual_reload_context_local(p);
report.artifacts = struct("saved", false);

if opts.saveArtifacts
    [report, ~] = ml_save_training_artifacts(model, report, "narrowband_residual_cnn_model", ...
        "saveDir", opts.saveDir, "saveTag", opts.saveTag, "savedBy", opts.savedBy);
end

function ctx = local_residual_reload_context_local(p)
ctx = struct();
ctx.profile = "narrowband";
ctx.frontend = "narrowband_subband_excision_residual_v1";
ctx.modType = string(p.mod.type);
ctx.fh = struct( ...
    "enable", logical(p.fh.enable), ...
    "nFreqs", double(p.fh.nFreqs), ...
    "freqSet", double(p.fh.freqSet(:).'), ...
    "symbolsPerHop", double(p.fh.symbolsPerHop));
ctx.dsss = struct( ...
    "enable", logical(p.dsss.enable), ...
    "spreadFactor", double(p.dsss.spreadFactor));
ctx.narrowbandNotchSoft = p.mitigation.narrowbandNotchSoft;
end

if opts.verbose
    fprintf("Narrowband residual CNN done: bestEpoch=%d bestValLoss=%.5f testLoss=%.5f\n", ...
        bestEpoch, bestValLoss, testLoss);
end
end

function XOut = local_normalize_feature_cells_local(XIn, inputMean, inputStd)
XOut = XIn;
for idx = 1:numel(XIn)
    XOut{idx} = (XIn{idx} - inputMean) ./ (inputStd + 1e-8);
end
end

function [XDl, YDl, WDl] = local_batch_dlarray_local(XCell, YCell, WCell, batchIdx, executionEnvironment)
XBatch = local_transpose_cells_local(XCell(batchIdx));
XData = cat(3, XBatch{:});
YData = cat(3, YCell{batchIdx});
WData = cat(3, WCell{batchIdx});
XDl = dlarray(single(XData), "CTB");
YDl = dlarray(single(YData), "CTB");
WDl = dlarray(single(WData), "CTB");
if executionEnvironment == "gpu"
    XDl = gpuArray(XDl);
    YDl = gpuArray(YDl);
    WDl = gpuArray(WDl);
end
end

function out = local_transpose_cells_local(cellsIn)
out = cell(size(cellsIn));
for idx = 1:numel(cellsIn)
    out{idx} = cellsIn{idx}.';
end
end

function [loss, gradients] = local_weighted_mse_loss_local(net, X, Y, W)
pred = forward(net, X);
err = pred - Y;
W2 = repmat(W, [size(err, 1), 1, 1]);
loss = sum(W2 .* (err .^ 2), "all") / (sum(W2, "all") + eps);
gradients = dlgradient(loss, net.Learnables);
end

function lossValue = local_eval_loss_local(net, XCell, YCell, WCell, executionEnvironment, batchSize)
totalLoss = 0;
totalSamples = 0;
for bStart = 1:batchSize:numel(XCell)
    bEnd = min(bStart + batchSize - 1, numel(XCell));
    batchIdx = bStart:bEnd;
    [XDl, YDl, WDl] = local_batch_dlarray_local(XCell, YCell, WCell, batchIdx, executionEnvironment);
    pred = predict(net, XDl);
    err = pred - YDl;
    W2 = repmat(WDl, [size(err, 1), 1, 1]);
    loss = sum(W2 .* (err .^ 2), "all") / (sum(W2, "all") + eps);
    nNow = numel(batchIdx) * size(XCell{1}, 1);
    totalLoss = totalLoss + double(gather(extractdata(loss))) * nNow;
    totalSamples = totalSamples + nNow;
end
lossValue = totalLoss / max(totalSamples, 1);
end
