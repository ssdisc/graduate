function [model, report] = ml_train_multipath_equalizer(p, opts)
%ML_TRAIN_MULTIPATH_EQUALIZER  Train an offline MLP symbol equalizer for FH multipath.

arguments
    p (1,1) struct
    opts.nChannels (1,1) double {mustBeInteger, mustBePositive} = 2500
    opts.samplesPerChannel (1,1) double {mustBeInteger, mustBePositive} = 32
    opts.blockLen (1,1) double {mustBeInteger, mustBePositive} = 192
    opts.ebN0dBRange (1,2) double = [6 14]
    opts.rayleighProbability (1,1) double = 0.8
    opts.bpskProbability (1,1) double = 0.35
    opts.epochs (1,1) double {mustBeInteger, mustBePositive} = 45
    opts.batchSize (1,1) double {mustBeInteger, mustBePositive} = 512
    opts.lr (1,1) double {mustBePositive} = 0.001
    opts.valFraction (1,1) double = 0.15
    opts.testFraction (1,1) double = 0.15
    opts.splitSeed (1,1) double = 1
    opts.rngSeed (1,1) double = NaN
    opts.enableEarlyStopping (1,1) logical = true
    opts.earlyStoppingPatience (1,1) double {mustBeInteger, mustBePositive} = 6
    opts.earlyStoppingMinDelta (1,1) double {mustBeNonnegative} = 1e-5
    opts.minEpochs (1,1) double {mustBeInteger, mustBePositive} = 8
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
if ~(opts.rayleighProbability >= 0 && opts.rayleighProbability <= 1)
    error("rayleighProbability must be in [0, 1].");
end
if ~(opts.bpskProbability >= 0 && opts.bpskProbability <= 1)
    error("bpskProbability must be in [0, 1].");
end

rngSeed = ml_resolve_rng_seed(p, opts.rngSeed);
rngScope = ml_rng_scope(rngSeed); %#ok<NASGU>

model = ml_multipath_equalizer_model();
model.eqLen = local_required_positive_integer(p.rxSync.multipathEq, "nTaps");
model.channelLen = local_channel_len_symbols(p.channel);
model.delay = model.channelLen - 1;
model.featureNames = local_feature_names(model.eqLen, model.channelLen);
model.inputChannels = numel(model.featureNames);
model.outputChannels = 2;
model.net = local_build_net(model.inputChannels, model.outputChannels, model.hiddenSizes);

if opts.useGpu && canUseGPU()
    executionEnvironment = "gpu";
else
    executionEnvironment = "cpu";
end
if opts.verbose
    fprintf("训练多径离线ML均衡器: %d channel blocks, %d samples/block, env=%s\n", ...
        opts.nChannels, opts.samplesPerChannel, executionEnvironment);
end

dataset = local_generate_dataset(p, model, opts);
split = ml_split_dataset_indices(dataset.nSamples, opts.valFraction, opts.testFraction, opts.splitSeed);
if split.nVal < 1 || split.nTest < 1
    error("Offline multipath equalizer training requires non-empty validation and test sets.");
end

XTrain = dataset.X(split.trainIdx, :);
YTrain = dataset.Y(split.trainIdx, :);
BTrain = dataset.baselineY(split.trainIdx, :);
TTrain = dataset.targetY(split.trainIdx, :);
XVal = dataset.X(split.valIdx, :);
YVal = dataset.Y(split.valIdx, :);
BVal = dataset.baselineY(split.valIdx, :);
TVal = dataset.targetY(split.valIdx, :);
XTest = dataset.X(split.testIdx, :);
YTest = dataset.Y(split.testIdx, :);
BTest = dataset.baselineY(split.testIdx, :);
TTest = dataset.targetY(split.testIdx, :);

model.inputMean = mean(XTrain, 1);
model.inputStd = std(XTrain, 0, 1);
model.inputStd(model.inputStd < 1e-6) = 1;
model.outputMean = mean(YTrain, 1);
model.outputStd = std(YTrain, 0, 1);
model.outputStd(model.outputStd < 1e-6) = 1;

XTrain = (XTrain - model.inputMean) ./ model.inputStd;
XVal = (XVal - model.inputMean) ./ model.inputStd;
XTest = (XTest - model.inputMean) ./ model.inputStd;
YTrain = (YTrain - model.outputMean) ./ model.outputStd;
YVal = (YVal - model.outputMean) ./ model.outputStd;
YTest = (YTest - model.outputMean) ./ model.outputStd;

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
        YBatch = dlarray(single(YTrain(batchIdx, :).'), "CB");
        if executionEnvironment == "gpu"
            XBatch = gpuArray(XBatch);
            YBatch = gpuArray(YBatch);
        end
        [loss, gradients] = dlfeval(@local_regression_loss, model.net, XBatch, YBatch);
        [model.net, averageGrad, averageSqGrad] = adamupdate(model.net, gradients, ...
            averageGrad, averageSqGrad, epoch, opts.lr);
        epochLoss = epochLoss + double(gather(extractdata(loss))) * numel(batchIdx);
    end

    epochLoss = epochLoss / size(XTrain, 1);
    losses(epoch) = epochLoss;
    valLoss = local_eval_loss(model.net, XVal, YVal, executionEnvironment);
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
        fprintf("第%d/%d轮：trainMSE=%.5f, valMSE=%.5f\n", epoch, opts.epochs, epochLoss, valLoss);
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

trainMetrics = local_symbol_metrics(model, XTrain, YTrain, BTrain, TTrain, executionEnvironment);
valMetrics = local_symbol_metrics(model, XVal, YVal, BVal, TVal, executionEnvironment);
testMetrics = local_symbol_metrics(model, XTest, YTest, BTest, TTest, executionEnvironment);

report = struct();
report.nSamples = dataset.nSamples;
report.nChannels = opts.nChannels;
report.samplesPerChannel = opts.samplesPerChannel;
report.ebN0dBRange = opts.ebN0dBRange;
report.rayleighProbability = opts.rayleighProbability;
report.bpskProbability = opts.bpskProbability;
report.rngSeed = rngSeed;
report.trainingOptions = opts;
report.trainingContext = ml_capture_training_context(p);
report.reloadContext = ml_capture_multipath_equalizer_reload_context(p);
report.featureNames = model.featureNames;
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
report.train = trainMetrics;
report.validation = valMetrics;
report.test = testMetrics;
report.selection = struct("bestCheckpointBy", "validation_loss", "testSetHeldOut", true);
report.artifacts = local_empty_artifacts_report();

if opts.saveArtifacts
    [report, ~] = ml_save_training_artifacts(model, report, "multipath_equalizer_model", ...
        "saveDir", opts.saveDir, "saveTag", opts.saveTag, "savedBy", opts.savedBy);
end

if opts.verbose
    fprintf("\n多径离线ML均衡器训练完成。\n");
    fprintf("最佳模型来自第%d轮，test residual MSE=%.5f，test EVM=%.4f，baseline EVM=%.4f。\n", ...
        bestEpoch, testMetrics.normalizedMse, testMetrics.evm, testMetrics.baselineEvm);
end
end

function dataset = local_generate_dataset(p, model, opts)
freqSet = local_training_freq_set(p);
pathDelays = local_path_delays(p.channel);
pathGainsDb = local_path_gains_db(p.channel, numel(pathDelays));
symbolDelays = (0:model.channelLen-1).';
nSamples = opts.nChannels * opts.samplesPerChannel;
X = zeros(nSamples, model.inputChannels);
Y = zeros(nSamples, 2);
baselineY = zeros(nSamples, 2);
targetY = zeros(nSamples, 2);

row = 0;
blockLen = max(opts.blockLen, model.eqLen + model.delay + 32);
[~, preambleSym] = make_packet_sync(p.frame, 1);
preambleSym = preambleSym(:);
for chanIdx = 1:opts.nChannels
    hBase = local_random_channel(pathDelays, pathGainsDb, model.channelLen, opts.rayleighProbability);
    freq = freqSet(randi(numel(freqSet)));
    hNow = hBase .* exp(-1j * 2 * pi * double(freq) * symbolDelays);
    ebN0dB = opts.ebN0dBRange(1) + diff(opts.ebN0dBRange) * rand();
    N0 = 10.^(-double(ebN0dB) / 10);
    rxPreamble = filter(hBase, 1, preambleSym) + sqrt(N0/2) * (randn(numel(preambleSym), 1) + 1j * randn(numel(preambleSym), 1));
    hEstBase = local_estimate_channel_from_preamble(preambleSym, rxPreamble, model.channelLen);
    hFeatNow = hEstBase .* exp(-1j * 2 * pi * double(freq) * symbolDelays);
    tx = local_random_symbols(blockLen, opts.bpskProbability);
    rx = filter(hNow, 1, tx) + sqrt(N0/2) * (randn(blockLen, 1) + 1j * randn(blockLen, 1));
    minPos = min(blockLen, model.delay + 1);
    pos = randi([minPos, blockLen], opts.samplesPerChannel, 1);
    [XBlock, baselineBlock] = ml_multipath_equalizer_features(rx, repmat(freq, blockLen, 1), hFeatNow, freq, N0, model);
    for k = 1:opts.samplesPerChannel
        row = row + 1;
        idx = pos(k);
        target = tx(idx);
        residual = target - baselineBlock(idx);
        X(row, :) = XBlock(idx, :);
        Y(row, :) = [real(residual), imag(residual)];
        baselineY(row, :) = [real(baselineBlock(idx)), imag(baselineBlock(idx))];
        targetY(row, :) = [real(target), imag(target)];
    end
end

dataset = struct();
dataset.X = X;
dataset.Y = Y;
dataset.baselineY = baselineY;
dataset.targetY = targetY;
dataset.nSamples = nSamples;
dataset.freqSet = freqSet;
dataset.pathDelaysSymbols = pathDelays;
dataset.pathGainsDb = pathGainsDb;
end

function hEst = local_estimate_channel_from_preamble(txPreamble, rxPreamble, channelLen)
tx = txPreamble(:);
rx = rxPreamble(:);
L = min(numel(tx), numel(rx));
if L < max(8, 2 * channelLen)
    error("Multipath equalizer training preamble is too short for a %d-tap channel estimate.", channelLen);
end
tx = tx(1:L);
rx = rx(1:L);
Xfull = toeplitz([tx; zeros(channelLen - 1, 1)], [tx(1); zeros(channelLen - 1, 1)]);
X = Xfull(1:L, :);
if rank(X) < channelLen
    error("Training preamble is rank-deficient for a %d-tap channel estimate.", channelLen);
end
hEst = X \ rx;
if any(~isfinite(hEst))
    error("Training multipath channel estimate contains non-finite values.");
end
end

function freqSet = local_training_freq_set(p)
freqSet = 0;
if isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "freqSet") && ~isempty(p.fh.freqSet)
    freqSet = [freqSet, double(p.fh.freqSet(:).')];
end
if isfield(p, "frame") && isstruct(p.frame) ...
        && isfield(p.frame, "phyHeaderFhFreqSet") && ~isempty(p.frame.phyHeaderFhFreqSet)
    freqSet = [freqSet, double(p.frame.phyHeaderFhFreqSet(:).')];
end
freqSet = unique(freqSet, "stable");
if isempty(freqSet) || any(~isfinite(freqSet))
    error("Multipath equalizer training requires finite FH frequency points.");
end
end

function h = local_random_channel(pathDelays, pathGainsDb, channelLen, rayleighProbability)
amp = 10.^(double(pathGainsDb(:)) / 20);
if rand() < rayleighProbability
    coeff = amp .* (randn(size(amp)) + 1j * randn(size(amp))) / sqrt(2);
else
    coeff = amp .* exp(1j * 2 * pi * rand(size(amp)));
end
h = complex(zeros(channelLen, 1));
for k = 1:numel(pathDelays)
    tap = round(double(pathDelays(k))) + 1;
    h(tap) = h(tap) + coeff(k);
end
if ~any(abs(h) > 1e-10)
    h(1) = 1;
end
end

function tx = local_random_symbols(n, bpskProbability)
if rand() < bpskProbability
    bits = randi([0 1], n, 1);
    tx = complex(2 * bits - 1, 0);
else
    bits = randi([0 1], n, 2);
    tx = complex(2 * bits(:, 1) - 1, 2 * bits(:, 2) - 1) / sqrt(2);
end
end

function [loss, gradients] = local_regression_loss(net, XBatch, YBatch)
YPred = forward(net, XBatch);
err = YPred - YBatch;
loss = mean(err.^2, "all");
gradients = dlgradient(loss, net.Learnables);
end

function loss = local_eval_loss(net, X, Y, executionEnvironment)
if isempty(X)
    loss = NaN;
    return;
end
XBatch = dlarray(single(X.'), "CB");
YBatch = dlarray(single(Y.'), "CB");
if executionEnvironment == "gpu"
    XBatch = gpuArray(XBatch);
    YBatch = gpuArray(YBatch);
end
YPred = predict(net, XBatch);
err = YPred - YBatch;
loss = double(gather(extractdata(mean(err.^2, "all"))));
end

function metrics = local_symbol_metrics(model, X, Y, baselineY, targetY, executionEnvironment)
loss = local_eval_loss(model.net, X, Y, executionEnvironment);
XBatch = dlarray(single(X.'), "CB");
if executionEnvironment == "gpu"
    XBatch = gpuArray(XBatch);
end
YPredNorm = double(gather(extractdata(predict(model.net, XBatch)))).';
outputStd = double(model.outputStd(:).');
outputMean = double(model.outputMean(:).');
YPred = YPredNorm .* outputStd + outputMean;
YTrue = Y .* outputStd + outputMean;
residualErr = YPred - YTrue;
symbolPred = baselineY + YPred;
symbolErr = symbolPred - targetY;
baselineErr = baselineY - targetY;
residualMse = mean(sum(residualErr.^2, 2));
symbolMse = mean(sum(symbolErr.^2, 2));
baselineMse = mean(sum(baselineErr.^2, 2));
refPower = mean(sum(targetY.^2, 2));
metrics = struct();
metrics.normalizedMse = double(loss);
metrics.residualMse = residualMse;
metrics.symbolMse = symbolMse;
metrics.baselineSymbolMse = baselineMse;
metrics.evm = sqrt(symbolMse / max(refPower, eps));
metrics.baselineEvm = sqrt(baselineMse / max(refPower, eps));
end

function value = local_required_positive_integer(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("p.rxSync.multipathEq.%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 1)
    error("p.rxSync.multipathEq.%s must be a positive integer scalar.", fieldName);
end
value = round(value);
end

function Lh = local_channel_len_symbols(channelCfg)
pathDelays = local_path_delays(channelCfg);
Lh = max(1, round(max(pathDelays)) + 1);
end

function pathDelays = local_path_delays(channelCfg)
if ~(isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols))
    error("Multipath equalizer training requires channel.multipath.pathDelaysSymbols.");
end
pathDelays = double(channelCfg.multipath.pathDelaysSymbols(:));
if any(~isfinite(pathDelays)) || any(pathDelays < 0) || any(abs(pathDelays - round(pathDelays)) > 1e-12)
    error("channel.multipath.pathDelaysSymbols must contain nonnegative integer delays.");
end
pathDelays = round(pathDelays);
end

function pathGainsDb = local_path_gains_db(channelCfg, nPaths)
if ~(isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "pathGainsDb") && ~isempty(channelCfg.multipath.pathGainsDb))
    error("Multipath equalizer training requires channel.multipath.pathGainsDb.");
end
pathGainsDb = double(channelCfg.multipath.pathGainsDb(:));
if numel(pathGainsDb) ~= nPaths || any(~isfinite(pathGainsDb))
    error("channel.multipath.pathGainsDb must match pathDelaysSymbols and be finite.");
end
end

function net = local_build_net(inputChannels, outputChannels, hiddenSizes)
layers = [
    featureInputLayer(inputChannels, "Name", "input", "Normalization", "none")
    fullyConnectedLayer(hiddenSizes(1), "Name", "fc1")
    reluLayer("Name", "relu1")
    fullyConnectedLayer(hiddenSizes(2), "Name", "fc2")
    reluLayer("Name", "relu2")
    fullyConnectedLayer(hiddenSizes(3), "Name", "fc3")
    reluLayer("Name", "relu3")
    fullyConnectedLayer(outputChannels, "Name", "fc_out")
    ];
net = dlnetwork(layers);
end

function names = local_feature_names(eqLen, channelLen)
tmp = ml_multipath_equalizer_model();
if eqLen == tmp.eqLen && channelLen == tmp.channelLen
    names = tmp.featureNames;
    return;
end
names = strings(1, 0);
for k = 1:eqLen
    names(end + 1) = "rxRe" + k; %#ok<AGROW>
end
for k = 1:eqLen
    names(end + 1) = "rxIm" + k; %#ok<AGROW>
end
for k = 1:channelLen
    names(end + 1) = "hRe" + k; %#ok<AGROW>
end
for k = 1:channelLen
    names(end + 1) = "hIm" + k; %#ok<AGROW>
end
names = [names, "freq", "freqAbs", "freqSquared", "log10N0", "log10WindowPower", ...
    "mmseBaselineRe", "mmseBaselineIm"];
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
