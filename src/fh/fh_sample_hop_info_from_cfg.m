function hopInfo = fh_sample_hop_info_from_cfg(fhCfg, waveform, nSample)
%FH_SAMPLE_HOP_INFO_FROM_CFG  Build sample-domain hop metadata from FH config.

arguments
    fhCfg (1,1) struct
    waveform (1,1) struct
    nSample (1,1) double {mustBeNonnegative, mustBeInteger}
end

if ~(isfield(fhCfg, "enable") && fhCfg.enable)
    hopInfo = struct("enable", false);
    return;
end
if ~(isfield(fhCfg, "freqSet") && ~isempty(fhCfg.freqSet))
    error("fh.freqSet must not be empty when FH is enabled.");
end
if ~(isfield(waveform, "sps") && ~isempty(waveform.sps))
    error("waveform.sps is required for sample-domain FH.");
end

nSample = round(double(nSample));
hopLenSamples = fh_samples_per_hop(fhCfg, waveform);
nHops = ceil(double(nSample) / double(hopLenSamples));
[freqIdx, pnState] = fh_generate_sequence(nHops, fhCfg);
freqOffsets = double(fhCfg.freqSet(freqIdx));

sps = double(waveform.sps);
if any(abs(freqOffsets) >= sps / 2)
    error("FH freqSet exceeds sample-domain Nyquist support: abs(freqOffset) must be < waveform.sps/2.");
end

hopInfo = struct();
hopInfo.enable = true;
hopInfo.mode = fh_mode(fhCfg);
hopInfo.nHops = nHops;
if fh_is_fast(fhCfg)
    hopInfo.hopLen = 0;
else
    hopInfo.hopLen = round(double(fhCfg.symbolsPerHop));
end
hopInfo.hopLenSamples = hopLenSamples;
hopInfo.freqIdx = freqIdx;
hopInfo.freqOffsets = freqOffsets;
hopInfo.pnState = pnState;
hopInfo.nFreqs = fhCfg.nFreqs;
hopInfo.freqSet = fhCfg.freqSet;
hopInfo.phaseContinuous = true;
end
