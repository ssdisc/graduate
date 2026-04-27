function bandwidthPoints = narrowband_prespread_fh_bandwidth_points(fhCfg, waveform, dsssCfg)
%NARROWBAND_PRESPREAD_FH_BANDWIDTH_POINTS Resolve the narrowband width that
%matches one pre-DSSS FH subchannel bandwidth.

arguments
    fhCfg (1,1) struct
    waveform (1,1) struct
    dsssCfg (1,1) struct
end

if ~(isfield(fhCfg, "freqSet") && ~isempty(fhCfg.freqSet))
    error("fhCfg.freqSet is required to resolve pre-spread FH bandwidth.");
end
freqSet = unique(sort(double(fhCfg.freqSet(:))));
if numel(freqSet) < 2
    error("fhCfg.freqSet must contain at least two distinct frequencies.");
end
spacingRs = median(diff(freqSet));
if ~(isscalar(spacingRs) && isfinite(spacingRs) && spacingRs > 0)
    error("Resolved FH spacing must be a positive finite scalar.");
end

rolloff = 0;
if isfield(waveform, "enable") && logical(waveform.enable)
    if ~(isfield(waveform, "rolloff") && isfinite(double(waveform.rolloff)) && double(waveform.rolloff) >= 0)
        error("waveform.rolloff must be a nonnegative finite scalar when waveform.enable=true.");
    end
    rolloff = double(waveform.rolloff);
end

spreadFactor = dsss_effective_spread_factor(dsssCfg);
preSpreadBandwidthRs = (1 + rolloff) / double(spreadFactor);
bandwidthPoints = preSpreadBandwidthRs / spacingRs;
if ~(isscalar(bandwidthPoints) && isfinite(bandwidthPoints) && bandwidthPoints > 0)
    error("Resolved pre-spread narrowband bandwidth must be a positive finite scalar.");
end
end
