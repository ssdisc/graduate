function [yEq, info] = ml_predict_multipath_equalizer_symbols(rx, freqBySymbol, hBank, bankFreqs, N0, model)
%ML_PREDICT_MULTIPATH_EQUALIZER_SYMBOLS  Apply the offline MLP multipath equalizer.

arguments
    rx (:,1)
    freqBySymbol (:,1) double
    hBank (:,:) double
    bankFreqs (:,1) double
    N0 (1,1) double {mustBeNonnegative}
    model (1,1) struct
end

if ~(isfield(model, "type") && string(model.type) == "multipath_equalizer_symbol_mlp")
    error("ml_predict_multipath_equalizer_symbols:UnsupportedModelType", ...
        "Only multipath_equalizer_symbol_mlp models are supported.");
end
if ~(isfield(model, "trained") && logical(model.trained))
    error("ml_predict_multipath_equalizer_symbols:UntrainedModel", ...
        "The multipath equalizer MLP must be trained before inference.");
end
if ~(isfield(model, "inputMean") && isfield(model, "inputStd") ...
        && isfield(model, "outputMean") && isfield(model, "outputStd"))
    error("ml_predict_multipath_equalizer_symbols:MissingNormalization", ...
        "The multipath equalizer MLP is missing normalization statistics.");
end
if ~(isfield(model, "outputMode") && string(model.outputMode) == "mmse_residual")
    error("ml_predict_multipath_equalizer_symbols:UnsupportedOutputMode", ...
        "The multipath equalizer MLP must use outputMode='mmse_residual'.");
end

[X, baseline] = ml_multipath_equalizer_features(rx, freqBySymbol, hBank, bankFreqs, N0, model);
if size(X, 2) ~= numel(model.inputMean)
    error("ml_predict_multipath_equalizer_symbols:FeatureCountMismatch", ...
        "Feature matrix has %d columns, model expects %d.", size(X, 2), numel(model.inputMean));
end

Xn = (double(X) - double(model.inputMean(:).')) ./ (double(model.inputStd(:).') + 1e-8);
YDl = predict(model.net, dlarray(single(Xn.'), "CB"));
Y = double(extractdata(YDl)).';
Y = Y .* (double(model.outputStd(:).') + 1e-8) + double(model.outputMean(:).');
if size(Y, 2) ~= 2
    error("ml_predict_multipath_equalizer_symbols:OutputCountMismatch", ...
        "Model output must have two columns [real imag], got %d.", size(Y, 2));
end

residual = complex(Y(:, 1), Y(:, 2));
residual = local_clip_residual(residual, model);
yEq = baseline + residual;
info = struct("nSymbols", numel(yEq), "baseline", baseline, "residual", residual);
end

function residual = local_clip_residual(residual, model)
if ~(isfield(model, "residualClip") && ~isempty(model.residualClip))
    error("ml_predict_multipath_equalizer_symbols:MissingResidualClip", ...
        "The multipath equalizer MLP must define residualClip.");
end
clipValue = double(model.residualClip);
if ~(isscalar(clipValue) && isfinite(clipValue) && clipValue >= 0)
    error("ml_predict_multipath_equalizer_symbols:InvalidResidualClip", ...
        "model.residualClip must be a finite nonnegative scalar.");
end
if clipValue <= 0
    residual(:) = 0;
    return;
end
mag = abs(residual);
tooLarge = mag > clipValue;
if any(tooLarge)
    residual(tooLarge) = residual(tooLarge) .* (clipValue ./ mag(tooLarge));
end
end
