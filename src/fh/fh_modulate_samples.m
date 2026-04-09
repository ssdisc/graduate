function [txHopped, hopInfo] = fh_modulate_samples(txSample, fh, waveform)
%FH_MODULATE_SAMPLES  Apply true fast FH on sample-domain complex baseband.

arguments
    txSample (:,1)
    fh (1,1) struct
    waveform (1,1) struct
end

if ~isfield(fh, "enable") || ~fh.enable
    txHopped = txSample;
    hopInfo = struct('enable', false);
    return;
end
if fh_mode(fh) ~= "fast"
    error("fh_modulate_samples only supports fh.mode='fast'.");
end
if ~(isfield(waveform, "sps") && ~isempty(waveform.sps))
    error("waveform.sps is required for fast FH modulation.");
end

nSample = numel(txSample);
hopLenSamples = fh_samples_per_hop(fh, waveform);
nHops = ceil(nSample / hopLenSamples);
[freqIdx, pnState] = fh_generate_sequence(nHops, fh);
freqOffsets = fh.freqSet(freqIdx);

txHopped = complex(zeros(size(txSample)));
sps = double(waveform.sps);
for hop = 1:nHops
    startIdx = (hop - 1) * hopLenSamples + 1;
    endIdx = min(hop * hopLenSamples, nSample);
    segLen = endIdx - startIdx + 1;
    fHop = freqOffsets(hop);
    n = (0:segLen-1).';
    phaseRot = exp(1j * 2 * pi * (fHop / sps) * n);
    txHopped(startIdx:endIdx) = txSample(startIdx:endIdx) .* phaseRot;
end

hopInfo = struct();
hopInfo.enable = true;
hopInfo.mode = "fast";
hopInfo.nHops = nHops;
hopInfo.hopLen = 0;
hopInfo.hopLenSamples = hopLenSamples;
hopInfo.freqIdx = freqIdx;
hopInfo.freqOffsets = freqOffsets;
hopInfo.pnState = pnState;
hopInfo.nFreqs = fh.nFreqs;
hopInfo.freqSet = fh.freqSet;
end
