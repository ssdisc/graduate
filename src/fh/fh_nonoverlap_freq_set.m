function [freqSet, info] = fh_nonoverlap_freq_set(waveform, targetN)
%FH_NONOVERLAP_FREQ_SET  Build a non-overlapping FH center set.

arguments
    waveform (1,1) struct
    targetN (1,1) double {mustBePositive, mustBeInteger} = NaN
end

if ~(isfield(waveform, "sps") && isfinite(double(waveform.sps)) && double(waveform.sps) >= 1)
    error("waveform.sps must be a positive finite scalar.");
end

sps = double(waveform.sps);
rolloff = 0;
if isfield(waveform, "enable") && logical(waveform.enable)
    if ~(isfield(waveform, "rolloff") && isfinite(double(waveform.rolloff)) && double(waveform.rolloff) >= 0)
        error("waveform.rolloff must be a nonnegative finite scalar when waveform.enable=true.");
    end
    rolloff = double(waveform.rolloff);
end

channelWidthRs = 1 + rolloff;
halfChannelWidthRs = channelWidthRs / 2;
maxCenterAbsRs = sps / 2 - halfChannelWidthRs;
if ~(isfinite(maxCenterAbsRs) && maxCenterAbsRs >= 0)
    error("Current waveform leaves no valid FH center range.");
end

maxN = floor((2 * maxCenterAbsRs) / channelWidthRs) + 1;
if maxN < 2
    error("Current waveform only supports %d non-overlapping FH point(s). Increase waveform.sps or reduce rolloff.", maxN);
end

if isnan(targetN)
    nUse = maxN;
else
    nUse = round(double(targetN));
    if nUse > maxN
        error("Current waveform supports at most %d non-overlapping FH point(s), requested %d.", maxN, nUse);
    end
    if nUse < 2
        error("At least 2 non-overlapping FH points are required, requested %d.", nUse);
    end
end

centerSpanRs = (nUse - 1) * channelWidthRs / 2;
freqSet = linspace(-centerSpanRs, centerSpanRs, nUse);
freqSet = double(freqSet(:).');

info = struct( ...
    "channelWidthRs", channelWidthRs, ...
    "halfChannelWidthRs", halfChannelWidthRs, ...
    "maxCenterAbsRs", maxCenterAbsRs, ...
    "maxN", maxN, ...
    "nUse", nUse);
end
