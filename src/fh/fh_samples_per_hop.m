function samplesPerHop = fh_samples_per_hop(fhCfg, waveform)
%FH_SAMPLES_PER_HOP  Return the sample-domain hop length for slow/fast FH.

if nargin < 2 || ~isstruct(waveform)
    error("fh_samples_per_hop requires FH config and waveform struct.");
end
if ~(isfield(waveform, "sps") && ~isempty(waveform.sps))
    error("waveform.sps is required for sample-domain FH.");
end

sps = double(waveform.sps);
if ~(isscalar(sps) && isfinite(sps) && abs(sps - round(sps)) < 1e-12 && sps >= 1)
    error("waveform.sps must be an integer scalar >= 1 for sample-domain FH, got %g.", sps);
end
sps = round(sps);

switch fh_mode(fhCfg)
    case "fast"
        fh_hops_per_symbol(fhCfg);
        samplesPerHop = sps;
    case "slow"
        if ~(isfield(fhCfg, "symbolsPerHop") && ~isempty(fhCfg.symbolsPerHop))
            error("slow FH requires fh.symbolsPerHop.");
        end
        symbolsPerHop = double(fhCfg.symbolsPerHop);
        if ~(isscalar(symbolsPerHop) && isfinite(symbolsPerHop) ...
                && abs(symbolsPerHop - round(symbolsPerHop)) < 1e-12 && symbolsPerHop >= 1)
            error("fh.symbolsPerHop must be an integer scalar >= 1, got %g.", symbolsPerHop);
        end
        samplesPerHop = round(symbolsPerHop) * sps;
    otherwise
        error("Unsupported FH mode: %s", string(fh_mode(fhCfg)));
end

if samplesPerHop < 1
    error("sample-domain FH produced an invalid samplesPerHop=%g.", samplesPerHop);
end
end
