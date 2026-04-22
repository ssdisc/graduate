function freqSet = select_spread_header_freq_set(freqSetIn, nUse, waveform, channelCfg)
%SELECT_SPREAD_HEADER_FREQ_SET  Pick a spread subset of known FH frequencies for headers.
%
% Prefer leaving one edge frequency unused on each side when enough payload
% FH points exist. This gives known headers some spectral guard instead of
% always pinning copies to the most edge-adjacent payload channels.
%
% If a narrowband jammer region is configured in channelCfg.narrowband,
% candidate frequencies whose signal band overlaps the jammer band are
% dropped before the final evenly-spaced selection.

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
freqCandidates = local_filter_narrowband_overlap_candidates(freqCandidates, nUse, freqSetBase, waveform, channelCfg);

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

function freqCandidates = local_filter_narrowband_overlap_candidates(freqCandidatesIn, nUse, freqSetBase, waveform, channelCfg)
freqCandidates = freqCandidatesIn;
if numel(freqCandidatesIn) <= nUse
    return;
end
if ~(isstruct(channelCfg) && isfield(channelCfg, "narrowband") && isstruct(channelCfg.narrowband))
    return;
end

nbCfg = channelCfg.narrowband;
if ~(isfield(nbCfg, "enable") && ~isempty(nbCfg.enable) && logical(nbCfg.enable))
    return;
end
if isfield(nbCfg, "weight") && ~isempty(nbCfg.weight) && double(nbCfg.weight) <= 0
    return;
end

[centerRs, bandwidthRs, ok] = local_narrowband_region_rs(nbCfg, freqSetBase, waveform);
if ~ok
    return;
end

rolloff = 0;
if isstruct(waveform) && isfield(waveform, "enable") && logical(waveform.enable) ...
        && isfield(waveform, "rolloff") && ~isempty(waveform.rolloff)
    rolloff = double(waveform.rolloff);
end
signalHalf = (1 + rolloff) / 2;
jamHalf = bandwidthRs / 2;
jamLeft = centerRs - jamHalf;
jamRight = centerRs + jamHalf;

sigLeft = double(freqCandidatesIn(:)) - signalHalf;
sigRight = double(freqCandidatesIn(:)) + signalHalf;
overlap = max(0, min(sigRight, jamRight) - max(sigLeft, jamLeft));
keepMask = overlap <= 1e-12;
if nnz(keepMask) >= nUse
    freqCandidates = freqCandidatesIn(keepMask);
end
end

function [centerRs, bandwidthRs, ok] = local_narrowband_region_rs(nbCfg, freqSetBase, waveform)
centerRs = NaN;
bandwidthRs = NaN;
ok = false;

spacingRs = NaN;
freqSetUnique = unique(sort(double(freqSetBase(:))));
if numel(freqSetUnique) >= 2
    spacingVec = diff(freqSetUnique);
    spacingVec = spacingVec(spacingVec > 0);
    if ~isempty(spacingVec)
        spacingRs = median(spacingVec);
    end
end

if isfield(nbCfg, "centerFreqPoints") && ~isempty(nbCfg.centerFreqPoints) ...
        && isfield(nbCfg, "bandwidthFreqPoints") && ~isempty(nbCfg.bandwidthFreqPoints) ...
        && isfinite(spacingRs) && spacingRs > 0
    centerRs = double(nbCfg.centerFreqPoints) * spacingRs;
    bandwidthRs = double(nbCfg.bandwidthFreqPoints) * spacingRs;
    ok = isfinite(centerRs) && isfinite(bandwidthRs) && bandwidthRs > 0;
    return;
end

if isfield(nbCfg, "centerFreq") && ~isempty(nbCfg.centerFreq) ...
        && isfield(nbCfg, "bandwidth") && ~isempty(nbCfg.bandwidth) ...
        && isstruct(waveform) && isfield(waveform, "sampleRateHz") && ~isempty(waveform.sampleRateHz) ...
        && isfield(waveform, "symbolRateHz") && ~isempty(waveform.symbolRateHz)
    sampleRateHz = double(waveform.sampleRateHz);
    symbolRateHz = double(waveform.symbolRateHz);
    if isfinite(sampleRateHz) && sampleRateHz > 0 && isfinite(symbolRateHz) && symbolRateHz > 0
        centerRs = double(nbCfg.centerFreq) * sampleRateHz / symbolRateHz;
        bandwidthRs = double(nbCfg.bandwidth) * sampleRateHz / symbolRateHz;
        ok = isfinite(centerRs) && isfinite(bandwidthRs) && bandwidthRs > 0;
    end
end
end
