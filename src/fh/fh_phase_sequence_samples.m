function phaseSeq = fh_phase_sequence_samples(freqOffsets, hopLenSamples, nSample, waveform)
%FH_PHASE_SEQUENCE_SAMPLES  Build a continuous sample-domain FH phase sequence.

arguments
    freqOffsets (:,1) double
    hopLenSamples (1,1) double {mustBePositive, mustBeInteger}
    nSample (1,1) double {mustBeNonnegative, mustBeInteger}
    waveform (1,1) struct
end

if ~(isfield(waveform, "sps") && isfinite(double(waveform.sps)) && double(waveform.sps) > 0)
    error("waveform.sps must be a positive finite scalar.");
end

nSample = round(double(nSample));
if nSample == 0
    phaseSeq = complex(zeros(0, 1));
    return;
end

hopLenSamples = round(double(hopLenSamples));
freqOffsets = double(freqOffsets(:));
if isempty(freqOffsets)
    error("freqOffsets must not be empty.");
end

nHopsRequired = ceil(double(nSample) / double(hopLenSamples));
if numel(freqOffsets) < nHopsRequired
    error("freqOffsets has %d hops but %d are required for %d samples.", ...
        numel(freqOffsets), nHopsRequired, nSample);
end

instFreq = repelem(freqOffsets(1:nHopsRequired), hopLenSamples, 1);
instFreq = instFreq(1:nSample);
phaseCycles = cumsum([0; instFreq(1:end-1)]) / double(waveform.sps);
phaseSeq = exp(1j * 2 * pi * phaseCycles);
end
