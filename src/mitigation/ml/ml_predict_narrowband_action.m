function [shouldBandstop, probability, probabilities, info] = ml_predict_narrowband_action(featureRow, model)
%ML_PREDICT_NARROWBAND_ACTION  Predict whether FFT bandstop should be applied.

featureRow = double(featureRow(:).');
if ~(isfield(model, "type") && string(model.type) == "narrowband_mlp")
    error("ml_predict_narrowband_action:UnsupportedModelType", ...
        "Only narrowband_mlp models are supported.");
end
if ~(isfield(model, "trained") && logical(model.trained))
    error("ml_predict_narrowband_action:UntrainedModel", ...
        "The narrowband action model must be trained before inference.");
end

Xn = (featureRow - double(model.inputMean(:).')) ./ (double(model.inputStd(:).') + 1e-8);
XDl = dlarray(single(Xn.'), "CB");
scoresDl = predict(model.net, XDl);
scores = double(extractdata(scoresDl(:)));
probabilities = local_softmax(scores);

positiveIdx = find(string(model.classNames(:).') == string(model.positiveClass), 1, "first");
if isempty(positiveIdx)
    error("ml_predict_narrowband_action:MissingPositiveClass", ...
        "Model positiveClass %s is not present in classNames.", char(string(model.positiveClass)));
end

probability = probabilities(positiveIdx);
threshold = local_threshold(model);
shouldBandstop = probability >= threshold;
info = struct( ...
    "scores", scores, ...
    "positiveClassIndex", positiveIdx, ...
    "threshold", threshold);
end

function threshold = local_threshold(model)
threshold = 0.5;
if isfield(model, "threshold") && ~isempty(model.threshold)
    threshold = double(model.threshold);
end
if ~(isscalar(threshold) && isfinite(threshold) && threshold >= 0 && threshold <= 1)
    error("ml_predict_narrowband_action:InvalidThreshold", ...
        "Model threshold must be a finite scalar in [0, 1].");
end
end

function p = local_softmax(scores)
scores = scores(:);
scores = scores - max(scores);
expScores = exp(max(min(scores, 30), -30));
p = expScores / max(sum(expScores), eps);
end
