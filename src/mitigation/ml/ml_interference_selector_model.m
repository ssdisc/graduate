function model = ml_interference_selector_model()
%ML_INTERFERENCE_SELECTOR_MODEL  Return a lightweight MLP for frame-level interference selection.

featureNames = ml_interference_selector_feature_names();
classNames = ml_interference_selector_class_names();

model = struct();
model.name = "interference_selector_mlp";
model.type = "selector_mlp";
model.trained = false;
model.featureVersion = 1;
model.trainingLogicVersion = 5;
model.featureNames = featureNames;
model.classNames = classNames;
model.inputChannels = numel(featureNames);
model.hiddenSizes = [48 24];
model.labelMode = "multilabel_sigmoid";
model.presenceThreshold = 0.5;

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
