function samplesPerHop = fh_samples_per_hop(fhCfg, waveform)
%FH_SAMPLES_PER_HOP  Return the sample-domain hop length for fast FH.

if nargin < 2 || ~isstruct(waveform)
    error("fh_samples_per_hop requires FH config and waveform struct.");
end
if fh_mode(fhCfg) ~= "fast"
    error("fh_samples_per_hop only applies to fast FH configs.");
end
if ~(isfield(waveform, "sps") && ~isempty(waveform.sps))
    error("waveform.sps is required for fast FH.");
end

sps = double(waveform.sps);
if ~(isscalar(sps) && isfinite(sps) && abs(sps - round(sps)) < 1e-12 && sps >= 2)
    error("waveform.sps must be an integer scalar >= 2 for fast FH, got %g.", sps);
end
sps = round(sps);
fh_hops_per_symbol(fhCfg);

samplesPerHop = sps;
if samplesPerHop < 1
    error("fast FH produced an invalid samplesPerHop=%g.", samplesPerHop);
end
end
