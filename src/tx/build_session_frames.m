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
        [dataSymBaseTx, modInfo] = local_encode_session_header_frame(sessionHeaderBits, p, 1);
        frameTemplate = local_make_frame_template(mode, syncSym, syncInfo, dataSymBaseTx, waveform, ...
            local_session_header_fh_cfg(p), struct("type", "BPSK"), numel(sessionHeaderBits), 1);
        sessionFrames = repmat(frameTemplate, repeatCount, 1);
        for idx = 1:repeatCount
            sessionFrames(idx).frameIndex = idx;
        end
    case "session_frame_strong"
        bitRepeat = session_frame_strong_repeat(p.frame);
        [dataSymBaseTx, modInfo] = local_encode_session_header_frame(sessionHeaderBits, p, bitRepeat);
        frameTemplate = local_make_frame_template(mode, syncSym, syncInfo, dataSymBaseTx, waveform, ...
            local_session_header_fh_cfg(p), struct("type", "BPSK"), numel(sessionHeaderBits), bitRepeat);
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

function frame = local_make_frame_template(mode, syncSym, syncInfo, dataSymBaseTx, waveform, fhCfg, modCfg, infoBitsLen, symbolRepeat)
[dataSymTx, hopInfo, txSymBasebandForSpectrum, txSymForChannel] = ...
    local_build_session_header_path(syncSym, dataSymBaseTx, fhCfg, waveform);
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
frame.infoBitsLen = infoBitsLen;
frame.decodeKind = "protected_header";
frame.symbolRepeat = symbolRepeat;
frame.dsssCfg = struct("enable", false);
frame.dsssInfo = struct("enable", false, "spreadFactor", 1);
frame.fhCfg = fhCfg;
frame.hopInfo = hopInfo;
end

function [dataSymBaseTx, modInfo] = local_encode_session_header_frame(sessionHeaderBits, p, symbolRepeat)
dataSymBaseTx = encode_protected_header_symbols(sessionHeaderBits, p.frame, p.fec);
symbolRepeat = max(1, round(double(symbolRepeat)));
if symbolRepeat > 1
    dataSymBaseTx = repelem(dataSymBaseTx(:), symbolRepeat);
else
    dataSymBaseTx = dataSymBaseTx(:);
end
modInfo = local_session_header_mod_info(numel(sessionHeaderBits), numel(dataSymBaseTx));
end

function fhCfg = local_session_header_fh_cfg(p)
fhCfg = phy_header_fh_cfg(p.frame, p.fh);
end

function [dataSymTx, hopInfo, txSymBasebandForSpectrum, txSymForChannel] = local_build_session_header_path(syncSym, dataSymBaseTx, fhCfg, waveform)
dataSymTx = dataSymBaseTx(:);
hopInfo = struct('enable', false);
if isfield(fhCfg, "enable") && fhCfg.enable && ~fh_is_fast(fhCfg)
    [dataSymTx, hopInfo] = fh_modulate(dataSymTx, fhCfg);
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

function modInfo = local_session_header_mod_info(infoBitsLen, nSym)
nSym = max(1, round(double(nSym)));
codeRate = double(infoBitsLen) / double(nSym);
codeRate = min(max(codeRate, 0), 1);
modInfo = struct( ...
    "type", "BPSK", ...
    "bitsPerSymbol", 1, ...
    "codeRate", codeRate, ...
    "spreadFactor", 1, ...
    "bitLoad", codeRate);
end
