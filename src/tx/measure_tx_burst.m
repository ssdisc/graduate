function report = measure_tx_burst(txWave, waveform)
%MEASURE_TX_BURST  Record emitted burst duration and power on a unified metric basis.
%
% 发射功率口径:
%   averagePowerLin = mean(abs(txWave).^2) * sampleRateHz / symbolRateHz
% 这样可以把RRC过采样后的采样功率换算回“等效1 sps复基带”口径，
% 避免仅因sps变化导致功率统计被稀释。

arguments
    txWave (:,1)
    waveform (1,1) struct
end

if isempty(txWave)
    error("measure_tx_burst:EmptyBurst", "Tx burst is empty.");
end

Fs = local_positive_struct_scalar(waveform, "sampleRateHz");
Rs = local_positive_struct_scalar(waveform, "symbolRateHz");

txWave = txWave(:);
avgSamplePower = mean(abs(txWave).^2);
peakSamplePower = max(abs(txWave).^2);
powerNormalizationFactor = Fs / Rs;
averagePowerLin = avgSamplePower * powerNormalizationFactor;
peakPowerLin = peakSamplePower * powerNormalizationFactor;

report = struct( ...
    "recorded", true, ...
    "powerMetric", "mean_abs2_symbol_rate_equivalent", ...
    "nSamples", numel(txWave), ...
    "sampleRateHz", Fs, ...
    "symbolRateHz", Rs, ...
    "powerNormalizationFactor", powerNormalizationFactor, ...
    "burstDurationSec", numel(txWave) / Fs, ...
    "averageSamplePower", avgSamplePower, ...
    "peakSamplePower", peakSamplePower, ...
    "averagePowerLin", averagePowerLin, ...
    "averagePowerDb", 10 * log10(max(averagePowerLin, realmin('double'))), ...
    "peakPowerLin", peakPowerLin, ...
    "peakPowerDb", 10 * log10(max(peakPowerLin, realmin('double'))));
end

function value = local_positive_struct_scalar(s, fieldName)
if ~isfield(s, fieldName)
    error("measure_tx_burst:MissingWaveformField", ...
        "Missing required waveform.%s.", fieldName);
end
value = local_positive_scalar(s.(fieldName), "waveform." + string(fieldName));
end

function value = local_positive_scalar(raw, fieldName)
value = double(raw);
if ~isscalar(value) || ~isfinite(value) || value <= 0
    error("measure_tx_burst:InvalidPositiveScalar", ...
        "%s must be a positive finite scalar.", fieldName);
end
end
