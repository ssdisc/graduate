function [freqFeatureMatrix, info] = ml_extract_fh_erasure_freq_features(hopFeatureMatrix, hopFeatureInfo)
%ML_EXTRACT_FH_ERASURE_FREQ_FEATURES  Aggregate hop observations into FH-frequency features.

arguments
    hopFeatureMatrix (:,:) double
    hopFeatureInfo (1,1) struct
end

if ~(isfield(hopFeatureInfo, "freqIdx") && ~isempty(hopFeatureInfo.freqIdx))
    error("ml_extract_fh_erasure_freq_features requires hopFeatureInfo.freqIdx.");
end
if ~(isfield(hopFeatureInfo, "nFreqs") && ~isempty(hopFeatureInfo.nFreqs))
    error("ml_extract_fh_erasure_freq_features requires hopFeatureInfo.nFreqs.");
end
if ~(isfield(hopFeatureInfo, "featureNames") && ~isempty(hopFeatureInfo.featureNames))
    error("ml_extract_fh_erasure_freq_features requires hopFeatureInfo.featureNames.");
end

freqIdx = round(double(hopFeatureInfo.freqIdx(:)));
nFreqs = round(double(hopFeatureInfo.nFreqs));
nHops = numel(freqIdx);
if size(hopFeatureMatrix, 1) ~= nHops
    error("FH frequency feature extraction got %d hop rows, expected %d.", size(hopFeatureMatrix, 1), nHops);
end
if ~(isscalar(nFreqs) && isfinite(nFreqs) && nFreqs >= 1)
    error("hopFeatureInfo.nFreqs must be a positive finite scalar.");
end
if any(~isfinite(freqIdx) | freqIdx < 1 | freqIdx > nFreqs)
    error("hopFeatureInfo.freqIdx must be within [1, nFreqs].");
end

hopNames = string(hopFeatureInfo.featureNames(:).');
requiredHopNames = [ ...
    "hopPowerRatio", ...
    "hopAbsMeanRatio", ...
    "hopAbsStdRatio", ...
    "freqMedianPowerRatio", ...
    "freqMeanPowerRatio", ...
    "freqMaxPowerRatio", ...
    "hopToFreqPowerRatio", ...
    "freqHotFraction", ...
    "freqIndexNorm", ...
    "absFreqOffsetNorm", ...
    "constellationMse", ...
    "iqPowerImbalance", ...
    "edgeHop", ...
    "ruleFreqReliability", ...
    "ruleHopReliability", ...
    "ruleReliability"];
for name = requiredHopNames
    if ~any(hopNames == name)
        error("Missing hop feature required for FH-frequency aggregation: %s.", char(name));
    end
end

freqFeatureMatrix = zeros(nFreqs, numel(ml_fh_erasure_freq_feature_names()));
freqHopCount = zeros(nFreqs, 1);
for freqNow = 1:nFreqs
    use = freqIdx == freqNow;
    if ~any(use)
        error("FH frequency %d has no hop observations; cannot build frequency-level ML features.", freqNow);
    end
    freqHopCount(freqNow) = nnz(use);
    hopRows = hopFeatureMatrix(use, :);
    freqFeatureMatrix(freqNow, :) = local_frequency_feature_row(hopRows, hopNames, nnz(use), nHops);
end
freqFeatureMatrix(~isfinite(freqFeatureMatrix)) = 0;

info = struct();
info.nFreqs = nFreqs;
info.freqIndex = (1:nFreqs).';
info.freqHopCount = freqHopCount;
info.featureNames = ml_fh_erasure_freq_feature_names();
end

function row = local_frequency_feature_row(hopRows, hopNames, nFreqHops, nHops)
hopPower = local_col(hopRows, hopNames, "hopPowerRatio");
constMse = local_col(hopRows, hopNames, "constellationMse");
iqImbalance = local_col(hopRows, hopNames, "iqPowerImbalance");
edgeHop = local_col(hopRows, hopNames, "edgeHop");

row = [ ...
    median(hopPower), ...
    mean(hopPower), ...
    max(hopPower), ...
    local_percentile(hopPower, 90), ...
    median(local_col(hopRows, hopNames, "hopAbsMeanRatio")), ...
    median(local_col(hopRows, hopNames, "hopAbsStdRatio")), ...
    median(local_col(hopRows, hopNames, "freqMedianPowerRatio")), ...
    median(local_col(hopRows, hopNames, "freqMeanPowerRatio")), ...
    median(local_col(hopRows, hopNames, "freqMaxPowerRatio")), ...
    median(local_col(hopRows, hopNames, "freqHotFraction")), ...
    median(local_col(hopRows, hopNames, "hopToFreqPowerRatio")), ...
    median(constMse), ...
    local_percentile(constMse, 90), ...
    median(iqImbalance), ...
    local_percentile(iqImbalance, 90), ...
    median(local_col(hopRows, hopNames, "freqIndexNorm")), ...
    median(local_col(hopRows, hopNames, "absFreqOffsetNorm")), ...
    double(nFreqHops) / max(double(nHops), 1), ...
    mean(edgeHop > 0), ...
    median(local_col(hopRows, hopNames, "ruleFreqReliability")), ...
    min(local_col(hopRows, hopNames, "ruleHopReliability")), ...
    min(local_col(hopRows, hopNames, "ruleReliability"))];
end

function x = local_col(rows, names, name)
idx = find(names == string(name), 1, "first");
if isempty(idx)
    error("Unknown hop feature for FH-frequency aggregation: %s.", char(string(name)));
end
x = double(rows(:, idx));
x = x(isfinite(x));
if isempty(x)
    x = 0;
end
end

function value = local_percentile(x, pct)
x = sort(double(x(:)));
x = x(isfinite(x));
if isempty(x)
    value = 0;
    return;
end
pct = max(0, min(100, double(pct)));
pos = 1 + (numel(x) - 1) * pct / 100;
lo = floor(pos);
hi = ceil(pos);
if lo == hi
    value = x(lo);
else
    value = x(lo) + (pos - lo) * (x(hi) - x(lo));
end
end
