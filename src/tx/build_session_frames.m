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
plan.txBurstBasebandForSpectrum = complex(zeros(0, 1));

if isempty(sessionHeaderBits) || ~session_frame_enabled(p.frame)
    return;
end

[~, syncSym, syncInfo] = make_packet_sync(p.frame, 1);

switch mode
    case "session_frame_repeat"
        repeatCount = session_frame_repeat_count(p.frame);
        [dataSymBaseTx, modInfo, intState, fecCfg] = local_encode_repeat_session_frame(sessionHeaderBits, p);
        frameTemplate = local_make_frame_template(mode, syncSym, syncInfo, dataSymBaseTx, waveform, p, ...
            p.mod, fecCfg, intState, 1, numel(sessionHeaderBits), "payload_like");
        modInfo = local_apply_session_link_to_mod_info(modInfo, frameTemplate.dsssInfo);
        sessionFrames = repmat(frameTemplate, repeatCount, 1);
        for idx = 1:repeatCount
            sessionFrames(idx).frameIndex = idx;
        end
    case "session_frame_strong"
        [dataSymBaseTx, modInfo, fecCfg, bitRepeat] = local_encode_strong_session_frame(sessionHeaderBits, p);
        frameTemplate = local_make_frame_template(mode, syncSym, syncInfo, dataSymBaseTx, waveform, p, ...
            struct("type", "BPSK"), fecCfg, struct(), bitRepeat, numel(sessionHeaderBits), "strong_bpsk");
        modInfo = local_apply_session_link_to_mod_info(modInfo, frameTemplate.dsssInfo);
        frameTemplate.frameIndex = 1;
        sessionFrames = frameTemplate;
    otherwise
        error("Dedicated session frame builder only supports session_frame_repeat/session_frame_strong, got %s.", string(mode));
end

txParts = cell(numel(sessionFrames), 1);
basebandParts = cell(numel(sessionFrames), 1);
for idx = 1:numel(sessionFrames)
    txParts{idx} = sessionFrames(idx).txSymForChannel;
    basebandParts{idx} = sessionFrames(idx).txSymBasebandForSpectrum;
end

plan.enabled = true;
plan.mode = mode;
plan.nFrames = numel(sessionFrames);
plan.modInfo = modInfo;
plan.txBurstForChannel = vertcat(txParts{:});
plan.txBurstBasebandForSpectrum = vertcat(basebandParts{:});
end

function frame = local_make_frame_template(mode, syncSym, syncInfo, dataSymBaseTx, waveform, p, modCfg, fecCfg, intState, bitRepeat, infoBitsLen, decodeKind)
[dataSymTx, dsssCfg, dsssInfo, fhCfg, hopInfo, txSymBasebandForSpectrum, txSymForChannel] = ...
    local_build_session_data_path(syncSym, dataSymBaseTx, p, waveform);
txSymFrame = [syncSym(:); dataSymTx(:)];
frame = struct();
frame.transportMode = mode;
frame.frameIndex = 1;
frame.syncSym = syncSym(:);
frame.syncInfo = syncInfo;
frame.dataSymBaseTx = dataSymBaseTx(:);
frame.dataSymTx = dataSymTx(:);
frame.nDemodSym = numel(dataSymBaseTx);
frame.nDataSym = numel(dataSymTx);
frame.txSymFrame = txSymFrame;
frame.txSymForChannel = txSymForChannel;
frame.txSymBasebandForSpectrum = txSymBasebandForSpectrum;
frame.modCfg = modCfg;
frame.fecCfg = fecCfg;
frame.intState = intState;
frame.bitRepeat = bitRepeat;
frame.infoBitsLen = infoBitsLen;
frame.decodeKind = decodeKind;
frame.dsssCfg = dsssCfg;
frame.dsssInfo = dsssInfo;
frame.fhCfg = fhCfg;
frame.hopInfo = hopInfo;
end

function [dataSymBaseTx, modInfo, intState, fecCfg] = local_encode_repeat_session_frame(sessionHeaderBits, p)
fecCfg = local_session_term_fec_cfg(p.fec);
codedBits = local_term_fec_encode(sessionHeaderBits, fecCfg);
[codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);
[dataSymBaseTx, modInfo] = modulate_bits(codedBitsInt, p.mod, fecCfg);
end

function [dataSymBaseTx, modInfo, fecCfg, bitRepeat] = local_encode_strong_session_frame(sessionHeaderBits, p)
fecCfg = local_session_term_fec_cfg(p.fec);
bitRepeat = session_frame_strong_repeat(p.frame);
codedBits = local_term_fec_encode(sessionHeaderBits, fecCfg);
codedBitsStrong = repelem(codedBits(:), bitRepeat);
[dataSymBaseTx, modInfo] = modulate_bits(codedBitsStrong, struct("type", "BPSK"), fecCfg);
end

function [dataSymTx, dsssCfg, dsssInfo, fhCfg, hopInfo, txSymBasebandForSpectrum, txSymForChannel] = local_build_session_data_path(syncSym, dataSymBaseTx, p, waveform)
dsssCfg = derive_packet_dsss_cfg(p.dsss, 1, 0, numel(dataSymBaseTx));
[dataSymSpread, dsssInfo] = dsss_spread(dataSymBaseTx(:), dsssCfg);
fhCfg = derive_packet_fh_cfg(p.fh, 1, 0, numel(dataSymSpread));

dataSymTx = dataSymSpread;
hopInfo = struct('enable', false);
if isfield(fhCfg, "enable") && fhCfg.enable && ~fh_is_fast(fhCfg)
    [dataSymTx, hopInfo] = fh_modulate(dataSymSpread, fhCfg);
end

txSymFrame = [syncSym(:); dataSymTx(:)];
txSymBasebandForSpectrum = pulse_tx_from_symbol_rate(txSymFrame, waveform);
txSymForChannel = txSymBasebandForSpectrum;
if isfield(fhCfg, "enable") && fhCfg.enable && fh_is_fast(fhCfg)
    txSymForChannel = local_apply_fast_fh_to_session_samples(txSymForChannel, numel(syncSym), fhCfg, waveform);
end
end

function txOut = local_apply_fast_fh_to_session_samples(txIn, nSyncSym, fhCfg, waveform)
txOut = txIn(:);
dataStart = local_symbol_boundary_sample_index(nSyncSym, waveform);
dataStart = min(max(1, dataStart), numel(txOut) + 1);
if dataStart > numel(txOut)
    return;
end

[segOut, ~] = fh_modulate_samples(txOut(dataStart:end), fhCfg, waveform);
txOut(dataStart:end) = segOut;
end

function sampleIdx = local_symbol_boundary_sample_index(nLeadingSym, waveform)
nLeadingSym = max(0, round(double(nLeadingSym)));
sampleIdx = nLeadingSym * round(double(waveform.sps)) + 1;
end

function modInfo = local_apply_session_link_to_mod_info(modInfo, dsssInfo)
if ~(isstruct(dsssInfo) && isfield(dsssInfo, "spreadFactor"))
    return;
end
modInfo.spreadFactor = dsssInfo.spreadFactor;
if isfield(modInfo, "bitsPerSymbol") && isfield(modInfo, "codeRate")
    modInfo.bitLoad = modInfo.bitsPerSymbol * modInfo.codeRate / dsssInfo.spreadFactor;
end
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
