function model = ml_narrowband_action_model()
%ML_NARROWBAND_ACTION_MODEL  Return a lightweight MLP for narrowband bandstop gating.

featureNames = ml_narrowband_feature_names();
classNames = ["pass" "bandstop"];

model = struct();
model.name = "narrowband_action_mlp";
model.type = "narrowband_mlp";
model.trained = false;
model.featureVersion = 1;
model.trainingLogicVersion = 1;
model.featureNames = featureNames;
model.classNames = classNames;
model.positiveClass = "bandstop";
model.threshold = 0.5;
model.inputChannels = numel(featureNames);
model.hiddenSizes = [32 16];

layers = [
    featureInputLayer(model.inputChannels, "Name", "input", "Normalization", "none")
    fullyConnectedLayer(model.hiddenSizes(1), "Name", "fc1")
    reluLayer("Name", "relu1")
    fullyConnectedLayer(model.hiddenSizes(2), "Name", "fc2")
    reluLayer("Name", "relu2")
    fullyConnectedLayer(numel(classNames), "Name", "fc_out")
    ];

model.net = dlnetwork(layers);
model.inputMean = zeros(1, model.inputChannels);
model.inputStd = ones(1, model.inputChannels);
end
