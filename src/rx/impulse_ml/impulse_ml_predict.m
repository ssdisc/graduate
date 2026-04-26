function [mask, suppressWeight, cleanSym, pImpulse, diagOut] = impulse_ml_predict(rIn, model, expectedType)
%IMPULSE_ML_PREDICT Predict impulse probability, suppression weight, and correction.

arguments
    rIn
    model (1,1) struct
    expectedType (1,1) string
end

r = rIn(:);
N = numel(r);
local_validate_model_contract(model, expectedType);

X = impulse_ml_features(r);
if size(X, 2) ~= model.inputChannels
    error("impulse_ml_predict:FeatureDimensionMismatch", ...
        "Impulse ML feature dimension is %d, model expects %d. Retrain the model.", ...
        size(X, 2), model.inputChannels);
end

Xn = (X - double(model.inputMean)) ./ (double(model.inputStd) + 1e-8);
out = local_forward_network(Xn, model);
if size(out, 1) ~= 4
    error("impulse_ml_predict:OutputSizeMismatch", ...
        "Impulse ML model must output 4 channels, got %d.", size(out, 1));
end
if size(out, 2) ~= N
    error("impulse_ml_predict:OutputLengthMismatch", ...
        "Impulse ML output length %d differs from input length %d.", size(out, 2), N);
end

outputMode = string(model.cleanOutputMode);
pImpulse = local_sigmoid(out(1,:).');
mask = pImpulse >= double(model.threshold);
switch outputMode
    case "soft_blanking_distilled"
        keepWeight = local_sigmoid(out(2,:).');
        keepWeight = max(min(keepWeight, 1), 0);
        suppressWeight = 1 - keepWeight;
        cleanSym = keepWeight .* r;
    case "gated_residual_suppressor"
        suppressWeight = local_sigmoid(out(2,:).');
        deltaReal = out(3,:).';
        deltaImag = out(4,:).';
        cleanSym = r + complex(deltaReal, deltaImag);
    otherwise
        error("impulse_ml_predict:UnsupportedOutputMode", ...
            "Unsupported impulse ML cleanOutputMode: %s.", char(outputMode));
end

diagOut = struct( ...
    "modelName", string(model.name), ...
    "modelType", string(model.type), ...
    "rxProfile", string(model.rxProfile), ...
    "rxFrontend", string(model.rxFrontend), ...
    "threshold", double(model.threshold), ...
    "featureVersion", double(model.featureVersion), ...
    "trainingLogicVersion", double(model.trainingLogicVersion), ...
    "cleanOutputMode", outputMode, ...
    "meanImpulseProbability", mean(double(pImpulse)), ...
    "meanSuppressWeight", mean(double(suppressWeight)), ...
    "hardImpulseRate", mean(double(mask)));
end

function local_validate_model_contract(model, expectedType)
if ~(isfield(model, "type") && string(model.type) == expectedType)
    error("impulse_ml_predict:UnsupportedModelType", ...
        "Expected impulse ML model type %s.", char(expectedType));
end
requiredFields = ["name" "net" "inputChannels" "inputMean" "inputStd" ...
    "threshold" "featureVersion" "trainingLogicVersion" "cleanOutputMode" ...
    "rxProfile" "rxFrontend"];
for idx = 1:numel(requiredFields)
    fieldName = requiredFields(idx);
    if ~isfield(model, fieldName)
        error("impulse_ml_predict:MissingModelField", ...
            "Impulse ML model is missing field %s.", char(fieldName));
    end
end
if ~any(string(model.cleanOutputMode) == ["gated_residual_suppressor" "soft_blanking_distilled"])
    error("impulse_ml_predict:UnsupportedOutputMode", ...
        "Impulse ML model cleanOutputMode is unsupported.");
end
if string(model.rxProfile) ~= "impulse" || string(model.rxFrontend) ~= "impulse_profile_ml_frontend_v1"
    error("impulse_ml_predict:WrongProfileFrontend", ...
        "Impulse ML model was not trained for impulse_profile_ml_frontend_v1.");
end
if ~(numel(model.inputMean) == model.inputChannels && numel(model.inputStd) == model.inputChannels)
    error("impulse_ml_predict:InvalidNormalization", ...
        "inputMean/inputStd length must equal inputChannels.");
end
if ~(isscalar(model.threshold) && isfinite(double(model.threshold)) ...
        && double(model.threshold) >= 0 && double(model.threshold) <= 1)
    error("impulse_ml_predict:InvalidThreshold", ...
        "Model threshold must be a finite scalar in [0,1].");
end
end

function out = local_forward_network(Xn, model)
XDl = dlarray(single(Xn.'), 'CTB');
outDl = predict(model.net, XDl);
out = squeeze(double(extractdata(outDl)));
if isvector(out)
    out = reshape(out, [], 1);
end
end

function y = local_sigmoid(x)
y = 1 ./ (1 + exp(-max(min(x, 30), -30)));
end
