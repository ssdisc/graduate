function freqSet = select_spread_header_freq_set(freqSetIn, nUse, waveform, channelCfg)
%SELECT_SPREAD_HEADER_FREQ_SET  Pick a spread subset of known FH frequencies for headers.
%
% Prefer leaving one edge frequency unused on each side when enough payload
% FH points exist. This gives known headers some spectral guard instead of
% always pinning copies to the most edge-adjacent payload channels.
%
% The selection is intentionally independent of the current interference
% realization so diversity performance is measured against actual jammer hits
% instead of being pre-optimized around them.

arguments
    freqSetIn (1,:) double
    nUse (1,1) double {mustBePositive, mustBeInteger}
    waveform struct = struct()
    channelCfg struct = struct()
end

freqSetBase = double(freqSetIn(:).');
if any(~isfinite(freqSetBase))
    error("Header FH frequency selection requires finite frequencies.");
end

nBase = numel(freqSetBase);
if nBase < nUse
    error("Requested %d header FH frequencies, but only %d payload frequencies are available.", ...
        nUse, nBase);
end

freqCandidates = local_edge_guard_candidates(freqSetBase, nUse);

idx = round(linspace(1, numel(freqCandidates), nUse));
idx = max(1, min(numel(freqCandidates), idx));
if numel(unique(idx, "stable")) ~= nUse
    error("Could not choose %d distinct header FH frequencies from %d candidates.", ...
        nUse, numel(freqCandidates));
end

freqSet = freqCandidates(idx);
end

function freqCandidates = local_edge_guard_candidates(freqSetBase, nUse)
freqCandidates = freqSetBase;
if numel(freqSetBase) >= nUse + 2
    freqCandidates = freqSetBase(2:end-1);
end
end
