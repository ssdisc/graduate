function [txPackets, plan] = build_tx_packets(payloadBits, meta, p, packetIndependentBitChaos, waveform)
% 按配置将整图载荷切分为多个分包并构建发送符号。
payloadBits = uint8(payloadBits(:) ~= 0);
totalBits = numel(payloadBits);
if nargin < 4
    packetIndependentBitChaos = false;
end
if nargin < 5
    waveform = resolve_waveform_cfg(struct());
end

packetEnable = false;
pktBitsPerPacket = totalBits;
if isfield(p, "packet") && isstruct(p.packet) && isfield(p.packet, "enable") && p.packet.enable
    packetEnable = true;
    if isfield(p.packet, "payloadBitsPerPacket") && ~isempty(p.packet.payloadBitsPerPacket)
        pktBitsPerPacket = max(8, round(double(p.packet.payloadBitsPerPacket)));
    else
        pktBitsPerPacket = 4096;
    end
end

% 分包以字节对齐，便于payloadBytes/CRC统计
pktBitsPerPacket = 8 * floor(pktBitsPerPacket / 8);
if pktBitsPerPacket <= 0
    pktBitsPerPacket = 8;
end
if ~packetEnable
    pktBitsPerPacket = max(pktBitsPerPacket, totalBits);
end

rsCfg = resolve_outer_rs_cfg(p);
if rsCfg.enable && ~packetEnable
    error("启用跨包RS外码时，packet.enable 必须为 true。");
end

useCompactPhy = local_use_compact_phy_header(p.frame);
if useCompactPhy && ~packetEnable
    error("packet.enable=false requires frame.phyHeaderMode='legacy_repeat'; compact_fec omits packetDataBytes so the receiver cannot infer the protected payload length.");
end

[outerRsPlan] = build_outer_rs_packet_plan(payloadBits, pktBitsPerPacket, rsCfg);
nPackets = outerRsPlan.totalTxPacketCount;
nDataPackets = outerRsPlan.dataPacketCount;
if nPackets > 65535
    error("分包数量过大(%d)，超出uint16可表示范围。", nPackets);
end

sessionMeta = meta;
sessionMeta.totalPayloadBytes = uint32(meta.payloadBytes);
sessionMeta.totalDataPackets = uint16(nDataPackets);
sessionMeta.totalPackets = uint16(nPackets);
sessionMeta.rsDataPacketsPerBlock = uint16(max(1, outerRsPlan.dataPacketsPerBlock));
sessionMeta.rsParityPacketsPerBlock = uint16(outerRsPlan.parityPacketsPerBlock);
sessionHeader = struct();
sessionHeaderBits = uint8([]);
if session_header_enabled(p.frame)
    [sessionHeaderBits, sessionHeader] = build_session_header_bits(sessionMeta, p.frame);
end
sessionHeaderLenBits = numel(sessionHeaderBits);
[sessionFrames, sessionFramePlan] = build_session_frames(sessionHeaderBits, p, waveform);

phyHeaderLenBits = phy_header_length_bits(p.frame);
phyHeaderSymLen = phy_header_symbol_length(p.frame, p.fec);
[~, firstSyncSym] = make_packet_sync(p.frame, 1);
[~, shortSyncSym] = make_packet_sync(p.frame, 2);

fhEnabled = isfield(p, 'fh') && isfield(p.fh, 'enable') && p.fh.enable;
phyHeaderFhCfg = phy_header_fh_cfg(p.frame, p.fh);
dsssEnable = isfield(p, 'dsss') && isfield(p.dsss, 'enable') && p.dsss.enable ...
    && dsss_effective_spread_factor(p.dsss) > 1;
packetChaosEnable = packetIndependentBitChaos && isfield(p, "chaosEncrypt") ...
    && isfield(p.chaosEncrypt, "enable") && p.chaosEncrypt.enable;

if packetEnable
    if packet_has_session_header(p.frame, 1)
        maxPacketDataBits = sessionHeaderLenBits + pktBitsPerPacket;
    else
        maxPacketDataBits = pktBitsPerPacket;
    end
else
    if packet_has_session_header(p.frame, 1)
        maxPacketDataBits = sessionHeaderLenBits + totalBits;
    else
        maxPacketDataBits = totalBits;
    end
end
maxPacketDataSym = n_symbols_for_info_bits_local(p, maxPacketDataBits);
packetStrideBits = maxPacketDataBits;
packetStrideHops = packet_stride_hops_local(p, maxPacketDataSym);

txPackets = repmat(struct(), nPackets, 1);
txBurstChannelParts = cell(nPackets, 1);
txBurstSpectrumParts = cell(nPackets, 1);
modInfoRef = struct();

for pktIdx = 1:nPackets
    packetSpec = outerRsPlan.packetSpecs(pktIdx);
    startBit = packetSpec.startBit;
    endBit = packetSpec.endBit;
    payloadPktPlain = packetSpec.payloadBitsPlain;
    payloadPkt = payloadPktPlain;
    chaosEncInfoPkt = struct('enabled', false, 'mode', "none");
    if packetChaosEnable
        chaosPktCfg = derive_packet_chaos_cfg(p.chaosEncrypt, pktIdx);
        [payloadPkt, chaosEncInfoPkt] = chaos_encrypt_bits(payloadPktPlain, chaosPktCfg);
    end
    payloadPktTx = payloadPkt;
    if useCompactPhy
        payloadPktTx = fit_bits_length(payloadPktTx, pktBitsPerPacket);
    end
    payloadPktBytes = ceil(numel(payloadPktPlain) / 8);
    if payloadPktBytes > 65535
        error("单包payload过大(%d bytes)，超出uint16可表示范围。", payloadPktBytes);
    end

    offsetsPkt = derive_packet_state_offsets(p, pktIdx);
    hasSessionHeader = offsetsPkt.hasSessionHeader;
    if hasSessionHeader
        packetDataBits = [sessionHeaderBits; payloadPktTx];
    else
        packetDataBits = payloadPktTx;
    end
    packetDataBitsLen = numel(packetDataBits);
    packetDataBytes = ceil(packetDataBitsLen / 8);
    if packetDataBytes > 65535
        error("单包受保护数据过大(%d bytes)，超出uint16可表示范围。", packetDataBytes);
    end

    phyMeta = struct();
    phyMeta.hasSessionHeader = hasSessionHeader;
    phyMeta.packetIndex = uint16(pktIdx);
    if ~useCompactPhy
        phyMeta.packetDataBytes = uint16(packetDataBytes);
    end
    phyMeta.packetDataCrc16 = crc16_ccitt_bits(packetDataBits);
    [phyHeaderBits, phyHeader] = build_phy_header_bits(phyMeta, p.frame);
    phyHeaderSym = encode_phy_header_symbols(phyHeaderBits, p.frame, p.fec);
    phyHeaderFast = phyHeaderFhCfg.enable && fh_is_fast(phyHeaderFhCfg);
    if phyHeaderFhCfg.enable && ~phyHeaderFast
        [phyHeaderSymTx, phyHeaderHopInfo] = fh_modulate(phyHeaderSym, phyHeaderFhCfg);
    else
        phyHeaderSymTx = phyHeaderSym;
        phyHeaderHopInfo = struct('enable', false);
    end

    scrambleCfgPkt = derive_packet_scramble_cfg(p.scramble, pktIdx, offsetsPkt.scrambleOffsetBits);
    dataBitsTxScr = scramble_bits(packetDataBits, scrambleCfgPkt);
    codedBits = fec_encode(dataBitsTxScr, p.fec);
    [codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);
    [dataSymTxBase, modInfo] = modulate_bits(codedBitsInt, p.mod, p.fec);
    dsssCfgPkt = derive_packet_dsss_cfg(p.dsss, pktIdx, offsetsPkt.dsssOffsetChips, numel(dataSymTxBase));
    [dataSymTx, dsssInfo] = dsss_spread(dataSymTxBase, dsssCfgPkt);
    modInfo.spreadFactor = dsssInfo.spreadFactor;
    modInfo.bitLoad = modInfo.bitsPerSymbol * modInfo.codeRate / dsssInfo.spreadFactor;
    modInfoRef = modInfo;

    dataFast = false;
    if fhEnabled
        fhCfgPkt = derive_packet_fh_cfg(p.fh, pktIdx, offsetsPkt.fhOffsetHops, numel(dataSymTx));
        dataFast = fh_is_fast(fhCfgPkt);
        if dataFast
            dataSymHop = dataSymTx;
            hopInfo = struct('enable', false);
        else
            [dataSymHop, hopInfo] = fh_modulate(dataSymTx, fhCfgPkt);
        end
    else
        dataSymHop = dataSymTx;
        hopInfo = struct('enable', false);
        fhCfgPkt = struct('enable', false);
    end

    [~, syncSymPkt, syncInfoPkt] = make_packet_sync(p.frame, pktIdx);
    txSymPkt = [syncSymPkt; phyHeaderSymTx; dataSymHop];
    txSymForChannel = pulse_tx_from_symbol_rate(txSymPkt, waveform);
    txSymForSpectrum = txSymForChannel;
    if phyHeaderFast || dataFast
        txSymForChannel = local_apply_fast_fh_segments_to_packet_samples( ...
            txSymForChannel, numel(syncSymPkt), numel(phyHeaderSym), phyHeaderFhCfg, fhCfgPkt, waveform);
    end

    txPackets(pktIdx).packetIndex = pktIdx;
    txPackets(pktIdx).isDataPacket = logical(packetSpec.isDataPacket);
    txPackets(pktIdx).isParityPacket = logical(packetSpec.isParityPacket);
    txPackets(pktIdx).sourcePacketIndex = double(packetSpec.sourcePacketIndex);
    txPackets(pktIdx).blockIndex = double(packetSpec.blockIndex);
    txPackets(pktIdx).blockDataCount = double(packetSpec.blockDataCount);
    txPackets(pktIdx).blockParityCount = double(packetSpec.blockParityCount);
    txPackets(pktIdx).blockLocalDataIndex = double(packetSpec.blockLocalDataIndex);
    txPackets(pktIdx).blockLocalParityIndex = double(packetSpec.blockLocalParityIndex);
    txPackets(pktIdx).syncKind = syncInfoPkt.kind;
    txPackets(pktIdx).syncSym = syncSymPkt;
    txPackets(pktIdx).startBit = startBit;
    txPackets(pktIdx).endBit = endBit;
    txPackets(pktIdx).hasSessionHeader = hasSessionHeader;
    txPackets(pktIdx).sessionHeader = sessionHeader;
    txPackets(pktIdx).sessionHeaderBits = ternary_bits_local(hasSessionHeader, sessionHeaderBits, uint8([]));
    txPackets(pktIdx).payloadBitsPlain = payloadPktPlain;
    txPackets(pktIdx).payloadBits = payloadPkt;
    txPackets(pktIdx).payloadBytes = payloadPktBytes;
    txPackets(pktIdx).packetDataBits = packetDataBits;
    txPackets(pktIdx).packetDataBytes = packetDataBytes;
    txPackets(pktIdx).packetDataCrc16 = phyMeta.packetDataCrc16;
    txPackets(pktIdx).chaosEncInfo = chaosEncInfoPkt;
    txPackets(pktIdx).phyHeader = phyHeader;
    txPackets(pktIdx).phyHeaderBits = phyHeaderBits;
    txPackets(pktIdx).phyHeaderSym = phyHeaderSym;
    txPackets(pktIdx).phyHeaderSymTx = phyHeaderSymTx;
    txPackets(pktIdx).phyHeaderFhCfg = phyHeaderFhCfg;
    txPackets(pktIdx).phyHeaderHopInfo = phyHeaderHopInfo;
    txPackets(pktIdx).stateOffsets = offsetsPkt;
    txPackets(pktIdx).scrambleCfg = scrambleCfgPkt;
    txPackets(pktIdx).dsssCfg = dsssCfgPkt;
    txPackets(pktIdx).dsssInfo = dsssInfo;
    txPackets(pktIdx).dataSymBaseTx = dataSymTxBase;
    txPackets(pktIdx).dataSymTx = dataSymTx;
    txPackets(pktIdx).fhCfg = fhCfgPkt;
    txPackets(pktIdx).hopInfo = hopInfo;
    txPackets(pktIdx).intState = intState;
    txPackets(pktIdx).txSymPkt = txSymPkt;
    txPackets(pktIdx).txSymForChannel = txSymForChannel;
    txBurstChannelParts{pktIdx} = txSymForChannel;
    txBurstSpectrumParts{pktIdx} = txSymForSpectrum;
end

plan = struct();
plan.packetEnable = packetEnable;
plan.nPackets = nPackets;
plan.nDataPackets = nDataPackets;
plan.sessionHeaderLenBits = sessionHeaderLenBits;
plan.phyHeaderLenBits = phyHeaderLenBits;
plan.phyHeaderSymLen = phyHeaderSymLen;
plan.firstSyncSymLen = numel(firstSyncSym);
plan.shortSyncSymLen = numel(shortSyncSym);
plan.packetStrideBits = packetStrideBits;
plan.packetStrideHops = packetStrideHops;
plan.fhEnabled = fhEnabled;
plan.dsssEnable = dsssEnable;
plan.packetChaosEnable = packetChaosEnable;
plan.waveform = waveform;
plan.modInfo = modInfoRef;
plan.outerRs = outerRsPlan;
plan.sessionMeta = sessionMeta;
plan.sessionFrames = sessionFrames;
plan.sessionFramePlan = sessionFramePlan;
plan.txBurstForChannel = vertcat(sessionFramePlan.txBurstForChannel(:), vertcat(txBurstChannelParts{:}));
plan.txBurstBasebandForSpectrum = vertcat(sessionFramePlan.txBurstBasebandForSpectrum(:), vertcat(txBurstSpectrumParts{:}));
end

function nSym = n_symbols_for_info_bits_local(p, nInfoBits)
bitsPerSym = bits_per_symbol_local(p.mod);
codedBitsLen = coded_bits_length_local(nInfoBits, p.fec);
[codedBitsInt, ~] = interleave_bits(zeros(codedBitsLen, 1, "uint8"), p.interleaver);
nBaseSym = ceil(numel(codedBitsInt) / bitsPerSym);
nSym = dsss_symbol_count(nBaseSym, p.dsss);
end

function nHops = packet_stride_hops_local(p, nSym)
if ~isfield(p, "fh") || ~isstruct(p.fh) || ~isfield(p.fh, "enable") || ~p.fh.enable
    nHops = 0;
    return;
end
if fh_is_fast(p.fh)
    if ~(isfield(p, "waveform") && isstruct(p.waveform))
        error("Fast FH packet stride requires waveform config.");
    end
    samplesPerHop = fh_samples_per_hop(p.fh, p.waveform);
    nHops = ceil(double(nSym) * double(p.waveform.sps) / double(samplesPerHop));
    return;
end
nHops = ceil(double(nSym) / double(p.fh.symbolsPerHop));
end

function nBits = coded_bits_length_local(nInfoBits, fec)
nBits = fec_coded_bits_length(nInfoBits, fec);
end

function bitsPerSym = bits_per_symbol_local(mod)
switch upper(string(mod.type))
    case "BPSK"
        bitsPerSym = 1;
    case "QPSK"
        bitsPerSym = 2;
    case "MSK"
        bitsPerSym = 1;
    otherwise
        error("Unsupported modulation for packet build: %s", mod.type);
end
end

function bits = ternary_bits_local(cond, bitsTrue, bitsFalse)
if cond
    bits = bitsTrue;
else
    bits = bitsFalse;
end
end

function txOut = local_apply_fast_fh_segments_to_packet_samples(txIn, nSyncSym, nHeaderSym, headerFhCfg, dataFhCfg, waveform)
txOut = txIn(:);

headerStart = local_symbol_boundary_sample_index(nSyncSym, waveform);
dataStart = local_symbol_boundary_sample_index(nSyncSym + nHeaderSym, waveform);

if isstruct(headerFhCfg) && isfield(headerFhCfg, "enable") && headerFhCfg.enable && fh_is_fast(headerFhCfg)
    headerStop = min(numel(txOut), dataStart - 1);
    if headerStart <= headerStop
        [segOut, ~] = fh_modulate_samples(txOut(headerStart:headerStop), headerFhCfg, waveform);
        txOut(headerStart:headerStop) = segOut;
    end
end

if isstruct(dataFhCfg) && isfield(dataFhCfg, "enable") && dataFhCfg.enable && fh_is_fast(dataFhCfg)
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

function tf = local_use_compact_phy_header(frameCfg)
tf = true;
if isfield(frameCfg, "phyHeaderMode") && strlength(string(frameCfg.phyHeaderMode)) > 0
    tf = lower(string(frameCfg.phyHeaderMode)) == "compact_fec";
end
end
