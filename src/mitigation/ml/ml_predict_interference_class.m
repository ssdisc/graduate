function [className, confidence, probabilities, info] = ml_predict_interference_class(featureRow, model)
%ML_PREDICT_INTERFERENCE_CLASS  Predict the dominant interference class from frame-level features.

featureRow = double(featureRow(:).');
if ~(isfield(model, "type") && string(model.type) == "selector_mlp")
    error("ml_predict_interference_class:UnsupportedModelType", ...
        "Only selector_mlp models are supported.");
end
if ~(isfield(model, "trained") && logical(model.trained))
    error("ml_predict_interference_class:UntrainedModel", ...
        "The interference selector model must be trained before inference.");
end

Xn = (featureRow - double(model.inputMean(:).')) ./ (double(model.inputStd(:).') + 1e-8);
XDl = dlarray(single(Xn.'), "CB");
scoresDl = predict(model.net, XDl);
scores = double(extractdata(scoresDl(:)));
probabilities = local_softmax(scores);

[confidence, idx] = max(probabilities);
className = string(model.classNames(idx));
info = struct("scores", scores, "classIndex", idx);
end

function p = local_softmax(scores)
scores = scores(:);
scores = scores - max(scores);
expScores = exp(max(min(scores, 30), -30));
p = expScores / max(sum(expScores), eps);
end
