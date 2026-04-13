function model = ml_multipath_equalizer_model()
%ML_MULTIPATH_EQUALIZER_MODEL  Offline symbol-domain MLP equalizer for FH multipath.

model = struct();
model.name = "multipath_equalizer_symbol_mlp";
model.type = "multipath_equalizer_symbol_mlp";
model.trained = false;
model.featureVersion = 2;
model.trainingLogicVersion = 5;
model.eqLen = 9;
model.channelLen = 3;
model.delay = 2;
model.hiddenSizes = [96 64 32];
model.baselineLambdaFactor = 1.0;
model.outputMode = "mmse_residual";
model.preambleGateMinGain = 0.15;
model.residualSnrMinDb = 7;
model.residualSnrFullDb = 10;
model.residualClip = 0.5;
model.featureNames = local_feature_names(model.eqLen, model.channelLen);
model.inputChannels = numel(model.featureNames);
model.outputChannels = 2;

layers = [
    featureInputLayer(model.inputChannels, "Name", "input", "Normalization", "none")
    fullyConnectedLayer(model.hiddenSizes(1), "Name", "fc1")
    reluLayer("Name", "relu1")
    fullyConnectedLayer(model.hiddenSizes(2), "Name", "fc2")
    reluLayer("Name", "relu2")
    fullyConnectedLayer(model.hiddenSizes(3), "Name", "fc3")
    reluLayer("Name", "relu3")
    fullyConnectedLayer(model.outputChannels, "Name", "fc_out")
    ];

model.net = dlnetwork(layers);
model.inputMean = zeros(1, model.inputChannels);
model.inputStd = ones(1, model.inputChannels);
model.outputMean = zeros(1, model.outputChannels);
model.outputStd = ones(1, model.outputChannels);
end

function names = local_feature_names(eqLen, channelLen)
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
