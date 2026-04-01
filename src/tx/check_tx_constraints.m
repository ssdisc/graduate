function report = check_tx_constraints(txWave, waveform, txConstraint)
%CHECK_TX_CONSTRAINTS  Measure emitted burst and enforce Tx time/power limits.
%
% 发射功率口径:
%   averagePowerLin = mean(abs(txWave).^2) * sampleRateHz / symbolRateHz
% 这样可以把RRC过采样后的采样功率换算回“等效1 sps复基带”口径，
% 避免仅因sps变化导致功率统计被稀释。

arguments
    txWave (:,1)
    waveform (1,1) struct
    txConstraint (1,1) struct
end

requiredFields = ["enable" "maxBurstDurationSec" "maxAveragePowerLin"];
for k = 1:numel(requiredFields)
    fieldName = requiredFields(k);
    if ~isfield(txConstraint, fieldName)
        error("check_tx_constraints:MissingField", ...
            "Missing required txConstraint.%s.", fieldName);
    end
end

if isempty(txWave)
    error("check_tx_constraints:EmptyBurst", "Tx burst is empty.");
end

Fs = local_positive_struct_scalar(waveform, "sampleRateHz");
Rs = local_positive_struct_scalar(waveform, "symbolRateHz");
enable = local_logical_scalar(txConstraint.enable, "txConstraint.enable");
maxBurstDurationSec = local_positive_scalar(txConstraint.maxBurstDurationSec, "txConstraint.maxBurstDurationSec");
maxAveragePowerLin = local_positive_scalar(txConstraint.maxAveragePowerLin, "txConstraint.maxAveragePowerLin");

txWave = txWave(:);
avgSamplePower = mean(abs(txWave).^2);
peakSamplePower = max(abs(txWave).^2);
powerNormalizationFactor = Fs / Rs;
averagePowerLin = avgSamplePower * powerNormalizationFactor;
peakPowerLin = peakSamplePower * powerNormalizationFactor;

report = struct( ...
    "enabled", enable, ...
    "checked", false, ...
    "powerMetric", "mean_abs2_symbol_rate_equivalent", ...
    "maxBurstDurationSec", maxBurstDurationSec, ...
    "maxAveragePowerLin", maxAveragePowerLin, ...
    "nSamples", numel(txWave), ...
    "sampleRateHz", Fs, ...
    "symbolRateHz", Rs, ...
    "powerNormalizationFactor", powerNormalizationFactor, ...
    "burstDurationSec", numel(txWave) / Fs, ...
    "averageSamplePower", avgSamplePower, ...
    "peakSamplePower", peakSamplePower, ...
    "averagePowerLin", averagePowerLin, ...
    "peakPowerLin", peakPowerLin);

if ~enable
    return;
end

tol = 1e-12;
if report.burstDurationSec > maxBurstDurationSec + tol
    error("check_tx_constraints:BurstDurationExceeded", ...
        "Tx burst duration %.6f s exceeds txConstraint.maxBurstDurationSec %.6f s.", ...
        report.burstDurationSec, maxBurstDurationSec);
end

if report.averagePowerLin > maxAveragePowerLin + tol
    error("check_tx_constraints:AveragePowerExceeded", ...
        "Tx average power %.6f exceeds txConstraint.maxAveragePowerLin %.6f (1 sps equivalent).", ...
        report.averagePowerLin, maxAveragePowerLin);
end

report.checked = true;
end

function value = local_positive_struct_scalar(s, fieldName)
if ~isfield(s, fieldName)
    error("check_tx_constraints:MissingWaveformField", ...
        "Missing required waveform.%s.", fieldName);
end
value = local_positive_scalar(s.(fieldName), "waveform." + string(fieldName));
end

function value = local_positive_scalar(raw, fieldName)
value = double(raw);
if ~isscalar(value) || ~isfinite(value) || value <= 0
    error("check_tx_constraints:InvalidPositiveScalar", ...
        "%s must be a positive finite scalar.", fieldName);
end
end

function value = local_logical_scalar(raw, fieldName)
if ~(isscalar(raw) && (islogical(raw) || isnumeric(raw)))
    error("check_tx_constraints:InvalidLogicalScalar", ...
        "%s must be a logical scalar.", fieldName);
end
value = logical(raw);
end
