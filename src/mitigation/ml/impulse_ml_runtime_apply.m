function [rOut, reliability] = impulse_ml_runtime_apply(rIn, cleanSym, suppressWeight, pImpulse, threshold, outputMode, hardMode)
%IMPULSE_ML_RUNTIME_APPLY Apply impulse ML outputs to runtime suppression samples.

arguments
    rIn
    cleanSym
    suppressWeight
    pImpulse
    threshold (1,1) double
    outputMode
    hardMode (1,1) logical = false
end

r = rIn(:);
cleanSym = cleanSym(:);
suppressWeight = double(gather(suppressWeight(:)));
pImpulse = double(gather(pImpulse(:)));
outputMode = string(outputMode);

if ~(numel(r) == numel(cleanSym) && numel(cleanSym) == numel(suppressWeight) && numel(suppressWeight) == numel(pImpulse))
    error("impulse_ml_runtime_apply requires matched input/output lengths.");
end

mask = pImpulse >= double(threshold);
if hardMode
    rOut = r;
    rOut(mask) = 0;
    reliability = ones(size(r));
    reliability(mask) = 0;
    return;
end

switch outputMode
    case "soft_blanking_distilled"
        keepWeight = max(min(1 - suppressWeight, 1), 0);
        keep = ones(size(r));
        keep(mask) = keepWeight(mask);
        rOut = keep .* r;
        reliability = keep;
    case "gated_residual_suppressor"
        [blendWeight, reliability] = impulse_ml_postprocess(pImpulse, suppressWeight, cleanSym, r, threshold);
        rOut = (1 - blendWeight) .* r + blendWeight .* cleanSym;
    otherwise
        error("Unsupported outputMode for impulse ML runtime apply: %s", char(outputMode));
end

rOut = double(gather(rOut));
reliability = double(gather(reliability));
end
