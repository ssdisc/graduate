function model = ml_fh_erasure_model()
%ML_FH_ERASURE_MODEL  Return a lightweight per-hop bad-hop classifier.

featureNames = ml_fh_erasure_feature_names();
classNames = ["good" "bad"];

model = struct();
model.name = "fh_erasure_mlp";
model.type = "fh_erasure_mlp";
model.trained = false;
model.featureVersion = 2;
model.trainingLogicVersion = 2;
model.featureNames = featureNames;
model.classNames = classNames;
model.positiveClass = "bad";
model.inputChannels = numel(featureNames);
model.hiddenSizes = [48 24];
model.minReliability = 0.02;

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
