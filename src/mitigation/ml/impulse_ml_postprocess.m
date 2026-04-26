function [blendWeight, reliability, info] = impulse_ml_postprocess(pImpulse, suppressWeight, cleanSym, rIn, threshold)
%IMPULSE_ML_POSTPROCESS Convert ML impulse outputs into suppression and reliability.

arguments
    pImpulse
    suppressWeight
    cleanSym
    rIn
    threshold (1,1) double
end

pImpulse = double(gather(pImpulse(:)));
suppressWeight = double(gather(suppressWeight(:)));
cleanSym = cleanSym(:);
r = rIn(:);

if ~(numel(pImpulse) == numel(suppressWeight) && numel(suppressWeight) == numel(cleanSym) && numel(cleanSym) == numel(r))
    error("impulse_ml_postprocess requires matched pImpulse/suppressWeight/cleanSym/r lengths.");
end

suppressWeight = max(min(suppressWeight, 1), 0);
hardGate = local_threshold_gate_probability_local(pImpulse, threshold);
severityGate = suppressWeight .* (0.25 + 0.75 * sqrt(max(pImpulse, 0)));
blendWeight = max(hardGate, severityGate);
blendWeight = max(min(blendWeight, 1), 0);

deltaMag = abs(cleanSym - r);
signalScale = max(median(abs(r)), eps);
repairRatio = min(deltaMag / max(2.5 * signalScale, eps), 1);
reliability = 1 - blendWeight .* (0.30 + 0.70 * repairRatio);
reliability = max(min(reliability, 1), 0.05);

info = struct( ...
    "threshold", double(threshold), ...
    "meanBlendWeight", mean(blendWeight), ...
    "meanSuppressWeight", mean(suppressWeight), ...
    "meanRepairRatio", mean(repairRatio), ...
    "hardGateRate", mean(double(hardGate > 0)));
end

function w = local_threshold_gate_probability_local(p, threshold)
threshold = double(gather(threshold));
if isempty(threshold) || ~isfinite(threshold)
    error("Impulse ML threshold is invalid.");
end
threshold = min(max(threshold(1), 0), 0.999);
w = zeros(size(p));
if threshold >= 0.999
    return;
end
active = p >= threshold;
w(active) = (p(active) - threshold) / max(1 - threshold, eps);
w = max(min(w, 1), 0);
end
