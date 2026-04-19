function [probabilities, classNames, info] = ml_predict_interference_presence(featureRow, model)
%ML_PREDICT_INTERFERENCE_PRESENCE  Multilabel presence probabilities for the selector MLP.

featureRow = double(featureRow(:).');
if ~(isfield(model, "type") && string(model.type) == "selector_mlp")
    error("ml_predict_interference_presence:UnsupportedModelType", ...
        "Only selector_mlp models are supported.");
end
if ~(isfield(model, "trained") && logical(model.trained))
    error("ml_predict_interference_presence:UntrainedModel", ...
        "The interference selector model must be trained before inference.");
end

Xn = (featureRow - double(model.inputMean(:).')) ./ (double(model.inputStd(:).') + 1e-8);
XDl = dlarray(single(Xn.'), "CB");
scoresDl = predict(model.net, XDl);
scores = double(gather(extractdata(scoresDl(:))));
probabilities = 1 ./ (1 + exp(-max(min(scores, 30), -30)));
probabilities = probabilities(:);
classNames = string(model.classNames(:));
info = struct("scores", scores);
end
