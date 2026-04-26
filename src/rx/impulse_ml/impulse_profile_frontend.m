function [rOut, reliability, diagOut] = impulse_profile_frontend(rIn, method, mitigation)
%IMPULSE_PROFILE_FRONTEND Dedicated impulse-profile suppression front-end.

arguments
    rIn
    method (1,1) string
    mitigation (1,1) struct
end

r = rIn(:);
method = lower(string(method));
reliability = ones(numel(r), 1);
diagOut = struct("frontEndMethod", method, "ok", true);

switch method
    case "none"
        rOut = r;

    case "blanking"
        threshold = local_impulse_threshold(r, mitigation);
        mask = abs(r) > threshold;
        rOut = r;
        rOut(mask) = 0;
        reliability(mask) = 0;
        diagOut.threshold = threshold;
        diagOut.hardImpulseRate = mean(double(mask));

    case "clipping"
        threshold = local_impulse_threshold(r, mitigation);
        mag = abs(r);
        scale = ones(size(r));
        mask = mag > threshold;
        scale(mask) = threshold ./ max(mag(mask), eps);
        rOut = r .* scale;
        reliability(mask) = scale(mask);
        diagOut.threshold = threshold;
        diagOut.hardImpulseRate = mean(double(mask));

    case {"ml_cnn", "ml_cnn_hard"}
        model = local_required_model(mitigation, "mlCnn", @ml_cnn_impulse_model, method);
        [mask, suppressWeight, cleanSym, pImpulse, modelDiag] = impulse_ml_predict(r, model, "cnn_dl");
        [rOut, reliability] = local_apply_ml_output(r, cleanSym, suppressWeight, pImpulse, model, method);
        diagOut = local_merge_diag(diagOut, modelDiag);

    case {"ml_gru", "ml_gru_hard"}
        model = local_required_model(mitigation, "mlGru", @ml_gru_impulse_model, method);
        [mask, suppressWeight, cleanSym, pImpulse, modelDiag] = impulse_ml_predict(r, model, "gru_dl");
        [rOut, reliability] = local_apply_ml_output(r, cleanSym, suppressWeight, pImpulse, model, method);
        diagOut = local_merge_diag(diagOut, modelDiag);

    otherwise
        [rOut, reliability] = mitigate_impulses(r, method, mitigation);
        diagOut.fallbackToGenericMitigation = true;
end

rOut = double(gather(rOut));
reliability = double(gather(reliability));
end

function threshold = local_impulse_threshold(r, mitigation)
if ~isfield(mitigation, "thresholdStrategy")
    error("impulse_profile_frontend requires mitigation.thresholdStrategy.");
end
switch string(mitigation.thresholdStrategy)
    case "median"
        local_require_field(mitigation, "thresholdAlpha");
        threshold = double(mitigation.thresholdAlpha) * median(abs(r));
    case "fixed"
        local_require_field(mitigation, "thresholdFixed");
        threshold = double(mitigation.thresholdFixed);
    otherwise
        error("Unknown impulse threshold strategy: %s.", string(mitigation.thresholdStrategy));
end
if ~(isscalar(threshold) && isfinite(threshold) && threshold >= 0)
    error("Impulse threshold must be a finite nonnegative scalar.");
end
end

function model = local_required_model(mitigation, fieldName, factoryFn, method)
fieldName = char(string(fieldName));
if isfield(mitigation, fieldName) && ~isempty(mitigation.(fieldName))
    model = mitigation.(fieldName);
else
    model = factoryFn();
end
requireTrained = isfield(mitigation, "requireTrainedModels") ...
    && logical(mitigation.requireTrainedModels);
if requireTrained && ~(isfield(model, "trained") && logical(model.trained))
    error("impulse_profile_frontend:MissingTrainedModel", ...
        "Method %s requires a trained impulse ML model.", char(method));
end
end

function [rOut, reliability] = local_apply_ml_output(r, cleanSym, suppressWeight, pImpulse, model, method)
method = lower(string(method));
hardMode = endsWith(method, "_hard");
[rOut, reliability] = impulse_ml_runtime_apply( ...
    r, cleanSym, suppressWeight, pImpulse, model.threshold, model.cleanOutputMode, hardMode);
end

function diagOut = local_merge_diag(base, extra)
diagOut = base;
fields = string(fieldnames(extra));
for idx = 1:numel(fields)
    fieldName = fields(idx);
    diagOut.(fieldName) = extra.(fieldName);
end
end

function local_require_field(s, fieldName)
fieldName = char(string(fieldName));
if ~isfield(s, fieldName)
    error("mitigation.%s is required.", fieldName);
end
end
