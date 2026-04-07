function [sessionFrames, plan] = build_session_frames(sessionHeaderBits, p, waveform)
%BUILD_SESSION_FRAMES  Construct dedicated over-the-air session frames.

sessionHeaderBits = uint8(sessionHeaderBits(:) ~= 0);
mode = session_transport_mode(p.frame);

sessionFrames = repmat(struct(), 0, 1);
plan = struct();
plan.enabled = false;
plan.mode = mode;
plan.nFrames = 0;
plan.txBurstForChannel = complex(zeros(0, 1));

if isempty(sessionHeaderBits) || ~session_frame_enabled(p.frame)
    return;
end

[~, syncSym, syncInfo] = make_packet_sync(p.frame, 1);

switch mode
    case "session_frame_repeat"
        repeatCount = session_frame_repeat_count(p.frame);
        [dataSymTx, modInfo, intState, fecCfg] = local_encode_repeat_session_frame(sessionHeaderBits, p);
        frameTemplate = local_make_frame_template(mode, syncSym, syncInfo, dataSymTx, waveform, ...
            p.mod, fecCfg, intState, 1, numel(sessionHeaderBits), "payload_like");
        sessionFrames = repmat(frameTemplate, repeatCount, 1);
        for idx = 1:repeatCount
            sessionFrames(idx).frameIndex = idx;
        end
    case "session_frame_strong"
        [dataSymTx, modInfo, fecCfg, bitRepeat] = local_encode_strong_session_frame(sessionHeaderBits, p);
        frameTemplate = local_make_frame_template(mode, syncSym, syncInfo, dataSymTx, waveform, ...
            struct("type", "BPSK"), fecCfg, struct(), bitRepeat, numel(sessionHeaderBits), "strong_bpsk");
        frameTemplate.frameIndex = 1;
        sessionFrames = frameTemplate;
    otherwise
        error("Dedicated session frame builder only supports session_frame_repeat/session_frame_strong, got %s.", string(mode));
end

txParts = cell(numel(sessionFrames), 1);
for idx = 1:numel(sessionFrames)
    txParts{idx} = sessionFrames(idx).txSymForChannel;
end

plan.enabled = true;
plan.mode = mode;
plan.nFrames = numel(sessionFrames);
plan.modInfo = modInfo;
plan.txBurstForChannel = vertcat(txParts{:});
end

function frame = local_make_frame_template(mode, syncSym, syncInfo, dataSymTx, waveform, modCfg, fecCfg, intState, bitRepeat, infoBitsLen, decodeKind)
txSymFrame = [syncSym(:); dataSymTx(:)];
frame = struct();
frame.transportMode = mode;
frame.frameIndex = 1;
frame.syncSym = syncSym(:);
frame.syncInfo = syncInfo;
frame.dataSymTx = dataSymTx(:);
frame.nDataSym = numel(dataSymTx);
frame.txSymFrame = txSymFrame;
frame.txSymForChannel = pulse_tx_from_symbol_rate(txSymFrame, waveform);
frame.modCfg = modCfg;
frame.fecCfg = fecCfg;
frame.intState = intState;
frame.bitRepeat = bitRepeat;
frame.infoBitsLen = infoBitsLen;
frame.decodeKind = decodeKind;
end

function [dataSymTx, modInfo, intState, fecCfg] = local_encode_repeat_session_frame(sessionHeaderBits, p)
fecCfg = local_session_term_fec_cfg(p.fec);
codedBits = local_term_fec_encode(sessionHeaderBits, fecCfg);
[codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);
[dataSymTx, modInfo] = modulate_bits(codedBitsInt, p.mod, fecCfg);
end

function [dataSymTx, modInfo, fecCfg, bitRepeat] = local_encode_strong_session_frame(sessionHeaderBits, p)
fecCfg = local_session_term_fec_cfg(p.fec);
bitRepeat = session_frame_strong_repeat(p.frame);
codedBits = local_term_fec_encode(sessionHeaderBits, fecCfg);
codedBitsStrong = repelem(codedBits(:), bitRepeat);
[dataSymTx, modInfo] = modulate_bits(codedBitsStrong, struct("type", "BPSK"), fecCfg);
end

function fecCfg = local_session_term_fec_cfg(fecBase)
fecCfg = fecBase;
fecCfg.kind = "conv";
fecCfg.opmode = 'term';
fecCfg.tracebackDepth = max(double(fecBase.tracebackDepth), 5 * local_conv_memory_bits(fecBase.trellis));
end

function memoryBits = local_conv_memory_bits(trellis)
memoryBits = max(0, round(log2(trellis.numStates)));
end

function codedBits = local_term_fec_encode(bits, fecCfg)
bits = uint8(bits(:) ~= 0);
tailBits = local_conv_termination_bits(fecCfg.trellis);
bitsTerm = [bits; zeros(tailBits, 1, "uint8")];
codedBits = convenc(bitsTerm, fecCfg.trellis);
end

function nTail = local_conv_termination_bits(trellis)
numInputBits = max(1, round(log2(trellis.numInputSymbols)));
memoryBits = local_conv_memory_bits(trellis);
tailSymbols = ceil(double(memoryBits) / double(numInputBits));
nTail = tailSymbols * numInputBits;
end
