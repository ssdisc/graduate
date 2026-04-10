function [maxAbsPoints, info] = narrowband_center_freq_points_limit(fhCfg, waveform, bandwidthFreqPoints)
%NARROWBAND_CENTER_FREQ_POINTS_LIMIT  Maximum valid narrowband center in FH-point units.

arguments
    fhCfg (1,1) struct
    waveform (1,1) struct
    bandwidthFreqPoints (1,1) double {mustBePositive}
end

if ~(isfield(waveform, "sampleRateHz") && isfinite(double(waveform.sampleRateHz)) ...
        && double(waveform.sampleRateHz) > 0)
    error("waveform.sampleRateHz must be a positive finite scalar.");
end

spacingHz = fh_frequency_spacing_hz(fhCfg, waveform);
spacingNorm = spacingHz / double(waveform.sampleRateHz);
bwPoints = double(bandwidthFreqPoints);
bwNorm = bwPoints * spacingNorm;
maxAbsNorm = 0.5 - bwNorm / 2 - 1e-9;
if ~(isfinite(maxAbsNorm) && maxAbsNorm > 0)
    error("Requested narrowband bandwidth %.12g FH-point(s) leaves no valid center range.", bwPoints);
end

maxAbsPoints = maxAbsNorm / spacingNorm;
info = struct( ...
    "spacingHz", spacingHz, ...
    "spacingNorm", spacingNorm, ...
    "bandwidthFreqPoints", bwPoints, ...
    "bandwidthNorm", bwNorm, ...
    "maxAbsCenterNorm", maxAbsNorm, ...
    "maxAbsCenterFreqPoints", maxAbsPoints);
end
