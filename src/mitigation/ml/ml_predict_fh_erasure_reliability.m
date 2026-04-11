function [reliabilityHop, pBad, probabilities, info] = ml_predict_fh_erasure_reliability(featureMatrix, model, opts)
%ML_PREDICT_FH_ERASURE_RELIABILITY  Predict per-hop reliability from FH-erasure features.

arguments
    featureMatrix (:,:) double
    model (1,1) struct
    opts.minReliability (1,1) double = NaN
end

if ~(isfield(model, "type") && string(model.type) == "fh_erasure_mlp")
    error("ml_predict_fh_erasure_reliability:UnsupportedModelType", ...
        "Only fh_erasure_mlp models are supported.");
end
if ~(isfield(model, "trained") && logical(model.trained))
    error("ml_predict_fh_erasure_reliability:UntrainedModel", ...
        "The FH-erasure model must be trained before inference.");
end
if ~(isfield(model, "inputMean") && isfield(model, "inputStd"))
    error("ml_predict_fh_erasure_reliability:MissingNormalization", ...
        "The FH-erasure model is missing inputMean/inputStd.");
end
if size(featureMatrix, 2) ~= numel(model.inputMean)
    error("ml_predict_fh_erasure_reliability:FeatureCountMismatch", ...
        "Feature matrix has %d columns, model expects %d.", size(featureMatrix, 2), numel(model.inputMean));
end

Xn = (double(featureMatrix) - double(model.inputMean(:).')) ./ (double(model.inputStd(:).') + 1e-8);
scoresDl = predict(model.net, dlarray(single(Xn.'), "CB"));
scores = double(extractdata(scoresDl));
scores = scores - max(scores, [], 1);
expScores = exp(max(min(scores, 30), -30));
probabilities = (expScores ./ max(sum(expScores, 1), eps)).';

badIdx = find(string(model.classNames(:).') == string(model.positiveClass), 1, "first");
if isempty(badIdx)
    error("ml_predict_fh_erasure_reliability:MissingPositiveClass", ...
        "Model positiveClass %s is not present in classNames.", char(string(model.positiveClass)));
end
pBad = probabilities(:, badIdx);

minReliability = opts.minReliability;
if isnan(minReliability)
    if ~(isfield(model, "minReliability") && ~isempty(model.minReliability))
        error("ml_predict_fh_erasure_reliability:MissingMinReliability", ...
            "minReliability must be provided or stored in the model.");
    end
    minReliability = double(model.minReliability);
end
if ~(isscalar(minReliability) && isfinite(minReliability) && minReliability >= 0 && minReliability <= 1)
    error("ml_predict_fh_erasure_reliability:InvalidMinReliability", ...
        "minReliability must be a finite scalar in [0, 1].");
end

reliabilityHop = max(minReliability, min(1, 1 - pBad));
info = struct( ...
    "badClassIndex", badIdx, ...
    "scores", scores.', ...
    "classNames", string(model.classNames(:).'));
end
