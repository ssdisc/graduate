function rxDehopped = fh_demodulate_samples(rxSample, hopInfo, waveform)
%FH_DEMODULATE_SAMPLES  Remove sample-domain slow/fast FH on complex baseband.

arguments
    rxSample (:,1)
    hopInfo (1,1) struct
    waveform (1,1) struct
end

if ~isfield(hopInfo, "enable") || ~hopInfo.enable
    rxDehopped = rxSample;
    return;
end
if ~(isfield(hopInfo, "mode") && any(string(hopInfo.mode) == ["slow" "fast"]))
    error("fh_demodulate_samples requires a slow/fast FH hopInfo struct.");
end
if ~(isfield(hopInfo, "hopLenSamples") && ~isempty(hopInfo.hopLenSamples))
    error("sample-domain FH hopInfo.hopLenSamples is required.");
end
if ~(isfield(waveform, "sps") && ~isempty(waveform.sps))
    error("waveform.sps is required for sample-domain FH demodulation.");
end

nSample = numel(rxSample);
hopLenSamples = round(double(hopInfo.hopLenSamples));
freqOffsets = double(hopInfo.freqOffsets(:));
if hopLenSamples < 1
    error("hopInfo.hopLenSamples must be >= 1, got %g.", hopLenSamples);
end
if isempty(freqOffsets)
    error("sample-domain FH hopInfo.freqOffsets must not be empty.");
end
if any(abs(freqOffsets) >= double(waveform.sps) / 2)
    error("FH freqOffsets exceed sample-domain Nyquist support: abs(freqOffset) must be < waveform.sps/2.");
end

nHops = ceil(nSample / hopLenSamples);
if numel(freqOffsets) < nHops
    error("sample-domain FH hopInfo has %d hops but %d are required for %d samples.", ...
        numel(freqOffsets), nHops, nSample);
end

phaseRot = fh_phase_sequence_samples(freqOffsets, hopLenSamples, nSample, waveform);
rxDehopped = rxSample .* conj(phaseRot);
end
