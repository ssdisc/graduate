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

[~, syncSymSingle, syncInfo] = make_packet_sync(p.frame, 1);
[syncSym, preambleFhCfg, preambleHopInfo] = local_apply_session_preamble_diversity_local( ...
    syncSymSingle, p, waveform);

switch mode
    case "session_frame_repeat"
        repeatCount = session_frame_repeat_count(p.frame);
        [dataSymBaseTx, ~] = local_encode_session_header_frame(sessionHeaderBits, p, 1);
        [dataSymTx, bodyFhCfg, bodyHopInfo] = local_apply_session_header_body_diversity_local(dataSymBaseTx, p, waveform);
        modInfo = local_session_header_mod_info(numel(sessionHeaderBits), numel(dataSymTx));
        frameTemplate = local_make_frame_template(mode, syncSym, syncInfo, dataSymBaseTx, dataSymTx, waveform, ...
            bodyFhCfg, bodyHopInfo, struct("type", "BPSK"), numel(sessionHeaderBits), 1, ...
            preambleFhCfg, preambleHopInfo);
        sessionFrames = repmat(frameTemplate, repeatCount, 1);
        for idx = 1:repeatCount
            sessionFrames(idx).frameIndex = idx;
        end
    case "session_frame_strong"
        bitRepeat = session_frame_strong_repeat(p.frame);
        [dataSymBaseTx, ~] = local_encode_session_header_frame(sessionHeaderBits, p, bitRepeat);
        [dataSymTx, bodyFhCfg, bodyHopInfo] = local_apply_session_header_body_diversity_local(dataSymBaseTx, p, waveform);
        modInfo = local_session_header_mod_info(numel(sessionHeaderBits), numel(dataSymTx));
        frameTemplate = local_make_frame_template(mode, syncSym, syncInfo, dataSymBaseTx, dataSymTx, waveform, ...
            bodyFhCfg, bodyHopInfo, struct("type", "BPSK"), numel(sessionHeaderBits), bitRepeat, ...
            preambleFhCfg, preambleHopInfo);
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

function frame = local_make_frame_template(mode, syncSym, syncInfo, dataSymBaseTx, dataSymTx, waveform, fhCfg, hopInfo, modCfg, infoBitsLen, symbolRepeat, preambleFhCfg, preambleHopInfo)
[txSymBasebandForSpectrum, txSymForChannel] = ...
    local_build_session_header_path(syncSym, dataSymTx, fhCfg, waveform, preambleFhCfg);
txSymFrame = [syncSym(:); dataSymTx(:)];
bodyDiversityCopies = local_session_header_body_copy_count_local(dataSymBaseTx, dataSymTx);
frame = struct();
frame.transportMode = mode;
frame.frameIndex = 1;
frame.syncSym = syncSym(:);
frame.syncInfo = syncInfo;
frame.dataSymBaseTx = dataSymBaseTx(:);
frame.dataSymTx = dataSymTx(:);
frame.nDemodSym = numel(dataSymBaseTx);
frame.nDataSymBase = numel(dataSymBaseTx);
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
frame.bodyDiversityCopies = bodyDiversityCopies;
frame.bodyDiversityCopyLen = numel(dataSymBaseTx);
frame.preambleFhCfg = preambleFhCfg;
frame.preambleHopInfo = preambleHopInfo;
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

function [dataSymTx, fhCfg, hopInfo] = local_apply_session_header_body_diversity_local(dataSymBaseTx, p, waveform)
dataSymBaseTx = dataSymBaseTx(:);
fhCfg = session_header_body_diversity_cfg(p.frame, p.fh, waveform, p.channel, numel(dataSymBaseTx));
if isfield(fhCfg, "enable") && fhCfg.enable
    dataSymTx = repmat(dataSymBaseTx, fhCfg.nFreqs, 1);
    hopInfo = fh_hop_info_from_cfg(fhCfg, numel(dataSymTx));
    return;
end

fhCfg = local_session_header_fh_cfg(p);
dataSymTx = dataSymBaseTx;
hopInfo = struct('enable', false);
if isfield(fhCfg, "enable") && fhCfg.enable && fh_is_fast(fhCfg)
    [dataSymTx, hopInfo] = fh_fast_symbol_expand(dataSymTx, fhCfg);
elseif isfield(fhCfg, "enable") && fhCfg.enable
    hopInfo = fh_hop_info_from_cfg(fhCfg, numel(dataSymTx));
end
end

function fhCfg = local_session_header_fh_cfg(p)
frameCfg = p.frame;
if isfield(frameCfg, "phyHeaderDiversity") && isstruct(frameCfg.phyHeaderDiversity)
    frameCfg.phyHeaderDiversity.enable = false;
end
fhCfg = phy_header_fh_cfg(frameCfg, p.fh, p.fec);
end

function [syncSymOut, preambleFhCfg, preambleHopInfo] = local_apply_session_preamble_diversity_local(syncSymIn, p, waveform)
syncSymIn = syncSymIn(:);
syncSymOut = syncSymIn;
preambleHopInfo = struct('enable', false);

copyLen = numel(syncSymIn);
preambleFhCfg = preamble_diversity_cfg(p.frame, p.fh, waveform, p.channel, copyLen);
if ~(isfield(preambleFhCfg, "enable") && preambleFhCfg.enable)
    preambleFhCfg = struct('enable', false);
    return;
end

copies = preambleFhCfg.nFreqs;
syncSymOut = repmat(syncSymIn, copies, 1);
preambleHopInfo = fh_hop_info_from_cfg(preambleFhCfg, numel(syncSymOut));
end

function [txSymBasebandForSpectrum, txSymForChannel] = local_build_session_header_path(syncSym, dataSymTx, fhCfg, waveform, preambleFhCfg)
dataSymTx = dataSymTx(:);
txSymFrame = [syncSym(:); dataSymTx(:)];
txSymBasebandForSpectrum = pulse_tx_from_symbol_rate(txSymFrame, waveform);
txSymForChannel = txSymBasebandForSpectrum;
preambleEnabled = isstruct(preambleFhCfg) && isfield(preambleFhCfg, "enable") && preambleFhCfg.enable;
dataEnabled = isfield(fhCfg, "enable") && fhCfg.enable;
if preambleEnabled || dataEnabled
    txSymForChannel = local_apply_fh_segments_to_session_samples( ...
        txSymForChannel, numel(syncSym), preambleFhCfg, fhCfg, waveform);
end
end

function txOut = local_apply_fh_segments_to_session_samples(txIn, nSyncSym, preambleFhCfg, dataFhCfg, waveform)
txOut = txIn(:);
dataStart = local_symbol_boundary_sample_index(nSyncSym, waveform);

if isstruct(preambleFhCfg) && isfield(preambleFhCfg, "enable") && preambleFhCfg.enable
    preambleStop = min(numel(txOut), dataStart - 1);
    if 1 <= preambleStop
        [segOut, ~] = fh_modulate_samples(txOut(1:preambleStop), preambleFhCfg, waveform);
        txOut(1:preambleStop) = segOut;
    end
end

if isstruct(dataFhCfg) && isfield(dataFhCfg, "enable") && dataFhCfg.enable
    dataStart = min(max(1, dataStart), numel(txOut) + 1);
    if dataStart <= numel(txOut)
        [segOut, ~] = fh_modulate_samples(txOut(dataStart:end), dataFhCfg, waveform);
        txOut(dataStart:end) = segOut;
    end
end
end

function sampleIdx = local_symbol_boundary_sample_index(nLeadingSym, waveform)
nLeadingSym = max(0, round(double(nLeadingSym)));
sampleIdx = nLeadingSym * round(double(waveform.sps)) + 1;
end

function copies = local_session_header_body_copy_count_local(dataSymBaseTx, dataSymTx)
copyLen = numel(dataSymBaseTx);
totalLen = numel(dataSymTx);
if copyLen <= 0
    copies = 1;
    return;
end
copies = totalLen / copyLen;
if ~(isfinite(copies) && copies >= 1 && abs(copies - round(copies)) <= 1e-9)
    error("Session header body diversity requires totalLen to be an integer multiple of copyLen.");
end
copies = round(copies);
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
