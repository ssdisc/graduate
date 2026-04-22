function training = ml_build_training_tx_burst(p, payloadBits, waveform)
%ML_BUILD_TRAINING_TX_BURST  Build a real over-the-air training burst via the main packet chain.

arguments
    p (1,1) struct
    payloadBits (:,1)
    waveform (1,1) struct = resolve_waveform_cfg(p)
end

payloadBits = uint8(payloadBits(:) ~= 0);
payloadBitsLen = max(numel(payloadBits), 8);
payloadBitsLen = 8 * ceil(double(payloadBitsLen) / 8);
if numel(payloadBits) < payloadBitsLen
    payloadBits = [payloadBits; zeros(payloadBitsLen - numel(payloadBits), 1, "uint8")];
end
payloadBytes = ceil(payloadBitsLen / 8);

meta = struct( ...
    "rows", uint16(32), ...
    "cols", uint16(32), ...
    "channels", uint8(1), ...
    "bitsPerPixel", uint8(8), ...
    "payloadBytes", uint32(payloadBytes));

[txPackets, txPlan] = build_tx_packets(payloadBits, meta, p, false, waveform);

training = struct();
training.payloadBits = payloadBits;
training.payloadBitsLen = payloadBitsLen;
training.payloadBytes = payloadBytes;
training.meta = meta;
training.txPackets = txPackets;
training.txPlan = txPlan;
training.sessionFrames = txPlan.sessionFrames;
training.txBurstForChannel = txPlan.txBurstForChannel;
training.txBurstBasebandForSpectrum = txPlan.txBurstBasebandForSpectrum;
end
