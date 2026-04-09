function rxDehopped = fh_demodulate_samples(rxSample, hopInfo, waveform)
%FH_DEMODULATE_SAMPLES  Remove true fast FH on sample-domain complex baseband.

arguments
    rxSample (:,1)
    hopInfo (1,1) struct
    waveform (1,1) struct
end

if ~isfield(hopInfo, "enable") || ~hopInfo.enable
    rxDehopped = rxSample;
    return;
end
if ~(isfield(hopInfo, "mode") && string(hopInfo.mode) == "fast")
    error("fh_demodulate_samples requires a fast-FH hopInfo struct.");
end
if ~(isfield(hopInfo, "hopLenSamples") && ~isempty(hopInfo.hopLenSamples))
    error("fast-FH hopInfo.hopLenSamples is required.");
end
if ~(isfield(waveform, "sps") && ~isempty(waveform.sps))
    error("waveform.sps is required for fast FH demodulation.");
end

nSample = numel(rxSample);
hopLenSamples = round(double(hopInfo.hopLenSamples));
freqOffsets = double(hopInfo.freqOffsets(:));
if hopLenSamples < 1
    error("hopInfo.hopLenSamples must be >= 1, got %g.", hopLenSamples);
end
if isempty(freqOffsets)
    error("fast-FH hopInfo.freqOffsets must not be empty.");
end

rxDehopped = complex(zeros(size(rxSample)));
sps = double(waveform.sps);
nHops = ceil(nSample / hopLenSamples);
if numel(freqOffsets) < nHops
    error("fast-FH hopInfo has %d hops but %d are required for %d samples.", ...
        numel(freqOffsets), nHops, nSample);
end

for hop = 1:nHops
    startIdx = (hop - 1) * hopLenSamples + 1;
    endIdx = min(hop * hopLenSamples, nSample);
    segLen = endIdx - startIdx + 1;
    fHop = freqOffsets(hop);
    n = (0:segLen-1).';
    phaseDerot = exp(-1j * 2 * pi * (fHop / sps) * n);
    rxDehopped(startIdx:endIdx) = rxSample(startIdx:endIdx) .* phaseDerot;
end
end
