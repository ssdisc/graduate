function [txHopped, hopInfo] = fh_modulate_samples(txSample, fh, waveform)
%FH_MODULATE_SAMPLES  Apply sample-domain slow/fast FH on complex baseband.

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
if ~(isfield(waveform, "sps") && ~isempty(waveform.sps))
    error("waveform.sps is required for sample-domain FH modulation.");
end

nSample = numel(txSample);
hopInfo = fh_sample_hop_info_from_cfg(fh, waveform, nSample);
phaseRot = fh_phase_sequence_samples(hopInfo.freqOffsets, hopInfo.hopLenSamples, nSample, waveform);
txHopped = txSample .* phaseRot;
end
