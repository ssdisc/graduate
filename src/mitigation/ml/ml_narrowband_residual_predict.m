function [y, diagOut] = ml_narrowband_residual_predict(x, model)
%ML_NARROWBAND_RESIDUAL_PREDICT Apply trained narrowband residual CNN.

arguments
    x
    model (1,1) struct
end

local_validate_model_local(model);
r = x(:);
[X, scale] = ml_narrowband_residual_features(r);
if size(X, 2) ~= double(model.inputChannels)
    error("ml_narrowband_residual_predict:FeatureDimensionMismatch", ...
        "Feature dimension %d does not match model.inputChannels=%d.", size(X, 2), double(model.inputChannels));
end

Xn = (X - double(model.inputMean)) ./ (double(model.inputStd) + 1e-8);
out = local_forward_local(Xn, model);
if size(out, 1) ~= 2 || size(out, 2) ~= numel(r)
    error("ml_narrowband_residual_predict:OutputSizeMismatch", ...
        "Expected CNN output [2 x %d], got [%d x %d].", numel(r), size(out, 1), size(out, 2));
end

deltaNorm = complex(out(1, :).', out(2, :).');
maxNorm = double(model.maxResidualNorm);
if ~(isscalar(maxNorm) && isfinite(maxNorm) && maxNorm > 0)
    error("ml_narrowband_residual_predict:InvalidMaxResidualNorm", ...
        "model.maxResidualNorm must be a positive finite scalar.");
end
deltaAbs = abs(deltaNorm);
over = deltaAbs > maxNorm;
if any(over)
    deltaNorm(over) = deltaNorm(over) .* (maxNorm ./ max(deltaAbs(over), eps));
end

gain = double(model.applyGain);
if ~(isscalar(gain) && isfinite(gain) && gain >= 0 && gain <= 1)
    error("ml_narrowband_residual_predict:InvalidApplyGain", ...
        "model.applyGain must be in [0,1].");
end
delta = gain * scale * deltaNorm;
y = r + delta;

diagOut = struct( ...
    "modelName", string(model.name), ...
    "modelType", string(model.type), ...
    "scale", double(scale), ...
    "applyGain", gain, ...
    "maxResidualNorm", maxNorm, ...
    "meanAbsResidual", mean(abs(delta)), ...
    "maxAbsResidual", max(abs(delta)), ...
    "clippedResidualRate", mean(double(over)));
end

function local_validate_model_local(model)
required = ["name" "type" "trained" "net" "inputChannels" "inputMean" "inputStd" ...
    "featureVersion" "trainingLogicVersion" "rxProfile" "rxFrontend" ...
    "maxResidualNorm" "applyGain"];
for idx = 1:numel(required)
    fieldName = required(idx);
    if ~isfield(model, char(fieldName))
        error("ml_narrowband_residual_predict:MissingModelField", ...
            "Narrowband residual model missing field %s.", char(fieldName));
    end
end
if string(model.type) ~= "narrowband_residual_cnn"
    error("ml_narrowband_residual_predict:UnsupportedModelType", ...
        "Expected model.type=narrowband_residual_cnn.");
end
if string(model.rxProfile) ~= "narrowband" ...
        || string(model.rxFrontend) ~= "narrowband_subband_excision_residual_v1"
    error("ml_narrowband_residual_predict:WrongProfileFrontend", ...
        "Residual model was not trained for the narrowband residual front-end.");
end
if ~logical(model.trained)
    error("ml_narrowband_residual_predict:UntrainedModel", ...
        "narrowband_cnn_residual_soft requires a trained residual CNN model.");
end
if numel(model.inputMean) ~= double(model.inputChannels) ...
        || numel(model.inputStd) ~= double(model.inputChannels)
    error("ml_narrowband_residual_predict:InvalidNormalization", ...
        "inputMean/inputStd must match model.inputChannels.");
end
end

function out = local_forward_local(Xn, model)
XDl = dlarray(single(Xn.'), "CTB");
outDl = predict(model.net, XDl);
out = squeeze(double(extractdata(outDl)));
if isvector(out)
    out = reshape(out, [], 1);
end
end
