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
scFdeCfg = sc_fde_payload_config(p);
phyHeaderFhCfg = phy_header_fh_cfg(p.frame, p.fh, p.fec);
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
packetStrideHops = packet_stride_hops_local(p, maxPacketDataSym, scFdeCfg);

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
    if phyHeaderFast
        [phyHeaderSymTx, phyHeaderHopInfo] = fh_fast_symbol_expand(phyHeaderSym, phyHeaderFhCfg);
    elseif phyHeaderFhCfg.enable
        phyHeaderSymTx = phyHeaderSym;
        phyHeaderHopInfo = fh_hop_info_from_cfg(phyHeaderFhCfg, numel(phyHeaderSymTx));
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
    scFdeInfo = sc_fde_payload_plan(numel(dataSymTx), scFdeCfg);
    dataSymForFh = dataSymTx;
    if scFdeInfo.enable
        [dataSymForFh, scFdeInfo] = sc_fde_payload_pack(dataSymTx, scFdeCfg, pktIdx);
        overheadFactor = double(scFdeInfo.hopLen) / double(scFdeInfo.dataSymbolsPerHop);
        modInfo.scFdeEnable = true;
        modInfo.scFdeOverheadFactor = overheadFactor;
        modInfo.spreadFactor = double(modInfo.spreadFactor) * overheadFactor;
        modInfo.bitLoad = modInfo.bitsPerSymbol * modInfo.codeRate / modInfo.spreadFactor;
    else
        modInfo.scFdeEnable = false;
        modInfo.scFdeOverheadFactor = 1.0;
    end
    [dataSymForFh, payloadDiversityInfo] = local_apply_payload_fh_diversity_tx_local(dataSymForFh, p.fh, scFdeInfo);
    modInfo.payloadDiversityEnable = logical(payloadDiversityInfo.enable);
    modInfo.payloadDiversityCopies = double(payloadDiversityInfo.copies);
    if payloadDiversityInfo.enable
        modInfo.spreadFactor = double(modInfo.spreadFactor) * double(payloadDiversityInfo.overheadFactor);
        modInfo.bitLoad = modInfo.bitsPerSymbol * modInfo.codeRate / modInfo.spreadFactor;
    end
    modInfoRef = modInfo;

    dataFast = false;
    if fhEnabled
        fhCfgPkt = derive_packet_fh_cfg(p.fh, pktIdx, offsetsPkt.fhOffsetHops, numel(dataSymForFh));
        dataFast = fh_is_fast(fhCfgPkt);
        if dataFast
            [dataSymHop, hopInfo] = fh_fast_symbol_expand(dataSymForFh, fhCfgPkt);
        else
            dataSymHop = dataSymForFh;
            hopInfo = fh_hop_info_from_cfg(fhCfgPkt, numel(dataSymHop));
        end
    else
        dataSymHop = dataSymForFh;
        hopInfo = struct('enable', false);
        fhCfgPkt = struct('enable', false);
    end

    [~, syncSymPktSingle, syncInfoPkt] = make_packet_sync(p.frame, pktIdx);
    [syncSymPkt, preambleFhCfg, preambleHopInfo] = local_apply_preamble_diversity_local( ...
        syncSymPktSingle, p, pktIdx, waveform);
    txSymPkt = [syncSymPkt; phyHeaderSymTx; dataSymHop];
    txSymForChannel = pulse_tx_from_symbol_rate(txSymPkt, waveform);
    txSymForSpectrum = txSymForChannel;
    [preambleSampleHopInfo, phyHeaderSampleHopInfo, dataSampleHopInfo] = local_packet_sample_hop_info_local( ...
        txSymForChannel, numel(syncSymPkt), numel(phyHeaderSymTx), preambleFhCfg, phyHeaderFhCfg, fhCfgPkt, waveform);
    if (isfield(preambleFhCfg, "enable") && preambleFhCfg.enable) ...
            || (isfield(phyHeaderFhCfg, "enable") && phyHeaderFhCfg.enable) ...
            || (isfield(fhCfgPkt, "enable") && fhCfgPkt.enable)
        txSymForChannel = local_apply_fh_segments_to_packet_samples( ...
            txSymForChannel, numel(syncSymPkt), numel(phyHeaderSymTx), preambleFhCfg, phyHeaderFhCfg, fhCfgPkt, waveform);
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
    txPackets(pktIdx).phyHeaderSampleHopInfo = phyHeaderSampleHopInfo;
    txPackets(pktIdx).preambleFhCfg = preambleFhCfg;
    txPackets(pktIdx).preambleHopInfo = preambleHopInfo;
    txPackets(pktIdx).preambleSampleHopInfo = preambleSampleHopInfo;
    txPackets(pktIdx).stateOffsets = offsetsPkt;
    txPackets(pktIdx).scrambleCfg = scrambleCfgPkt;
    txPackets(pktIdx).dsssCfg = dsssCfgPkt;
    txPackets(pktIdx).dsssInfo = dsssInfo;
    txPackets(pktIdx).dataSymBaseTx = dataSymTxBase;
    txPackets(pktIdx).dataSymTx = dataSymTx;
    txPackets(pktIdx).dataSymScFdeTx = dataSymForFh;
    txPackets(pktIdx).scFdeInfo = scFdeInfo;
    txPackets(pktIdx).payloadDiversityInfo = payloadDiversityInfo;
    txPackets(pktIdx).dataSymHop = dataSymHop;
    txPackets(pktIdx).nDemodSym = numel(dataSymTxBase);
    txPackets(pktIdx).nDataSymBase = numel(dataSymTx);
    txPackets(pktIdx).nDataSymTx = numel(dataSymHop);
    txPackets(pktIdx).nPhyHeaderSymBase = numel(phyHeaderSym);
    txPackets(pktIdx).nPhyHeaderSymTx = numel(phyHeaderSymTx);
    txPackets(pktIdx).fhCfg = fhCfgPkt;
    txPackets(pktIdx).hopInfo = hopInfo;
    txPackets(pktIdx).sampleHopInfo = dataSampleHopInfo;
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
plan.scFdeEnable = scFdeCfg.enable;
plan.scFdeCfg = scFdeCfg;
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

function nHops = packet_stride_hops_local(p, nSym, scFdeCfg)
if ~isfield(p, "fh") || ~isstruct(p.fh) || ~isfield(p.fh, "enable") || ~p.fh.enable
    nHops = 0;
    return;
end
if nargin >= 3 && isstruct(scFdeCfg) && isfield(scFdeCfg, "enable") && logical(scFdeCfg.enable)
    scFdePlan = sc_fde_payload_plan(nSym, scFdeCfg);
    nHops = scFdePlan.nHops;
    return;
end
if fh_is_fast(p.fh)
    nHops = double(nSym) * double(fh_hops_per_symbol(p.fh));
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

function txOut = local_apply_fh_segments_to_packet_samples(txIn, nSyncSym, nHeaderSym, preambleFhCfg, headerFhCfg, dataFhCfg, waveform)
txOut = txIn(:);

headerStart = local_symbol_boundary_sample_index(nSyncSym, waveform);
dataStart = local_symbol_boundary_sample_index(nSyncSym + nHeaderSym, waveform);

if isstruct(preambleFhCfg) && isfield(preambleFhCfg, "enable") && preambleFhCfg.enable
    preambleStop = min(numel(txOut), headerStart - 1);
    if 1 <= preambleStop
        [segOut, ~] = fh_modulate_samples(txOut(1:preambleStop), preambleFhCfg, waveform);
        txOut(1:preambleStop) = segOut;
    end
end

if isstruct(headerFhCfg) && isfield(headerFhCfg, "enable") && headerFhCfg.enable
    headerStop = min(numel(txOut), dataStart - 1);
    if headerStart <= headerStop
        [segOut, ~] = fh_modulate_samples(txOut(headerStart:headerStop), headerFhCfg, waveform);
        txOut(headerStart:headerStop) = segOut;
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

function [syncSymOut, preambleFhCfg, preambleHopInfo] = local_apply_preamble_diversity_local(syncSymIn, p, pktIdx, waveform)
syncSymIn = syncSymIn(:);
preambleFhCfg = struct('enable', false);
preambleHopInfo = struct('enable', false);
syncSymOut = syncSymIn;

if ~is_long_sync_packet(p.frame, pktIdx)
    return;
end

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

function [preambleHopInfo, headerHopInfo, dataHopInfo] = local_packet_sample_hop_info_local(txIn, nSyncSym, nHeaderSym, preambleFhCfg, headerFhCfg, dataFhCfg, waveform)
txIn = txIn(:);
headerStart = local_symbol_boundary_sample_index(nSyncSym, waveform);
dataStart = local_symbol_boundary_sample_index(nSyncSym + nHeaderSym, waveform);

preambleHopInfo = struct('enable', false);
headerHopInfo = struct('enable', false);
dataHopInfo = struct('enable', false);

if isstruct(preambleFhCfg) && isfield(preambleFhCfg, "enable") && preambleFhCfg.enable
    preambleStop = min(numel(txIn), headerStart - 1);
    if preambleStop >= 1
        preambleHopInfo = fh_sample_hop_info_from_cfg(preambleFhCfg, waveform, preambleStop);
    end
end

if isstruct(headerFhCfg) && isfield(headerFhCfg, "enable") && headerFhCfg.enable
    headerStop = min(numel(txIn), dataStart - 1);
    if headerStart <= headerStop
        headerHopInfo = fh_sample_hop_info_from_cfg(headerFhCfg, waveform, headerStop - headerStart + 1);
    end
end

if isstruct(dataFhCfg) && isfield(dataFhCfg, "enable") && dataFhCfg.enable
    dataStart = min(max(1, dataStart), numel(txIn) + 1);
    if dataStart <= numel(txIn)
        dataHopInfo = fh_sample_hop_info_from_cfg(dataFhCfg, waveform, numel(txIn) - dataStart + 1);
    end
end
end

function [txOut, info] = local_apply_payload_fh_diversity_tx_local(txIn, fhCfg, scFdeInfo)
txOut = txIn(:);
inputSymbols = numel(txOut);
info = struct( ...
    "enable", false, ...
    "copies", 1, ...
    "logicalHops", 0, ...
    "physicalHops", 0, ...
    "hopLen", 0, ...
    "inputSymbols", inputSymbols, ...
    "logicalSymbolsPadded", inputSymbols, ...
    "overheadFactor", 1.0);

if ~(isfield(fhCfg, "payloadDiversity") && isstruct(fhCfg.payloadDiversity) ...
        && isfield(fhCfg.payloadDiversity, "enable") && logical(fhCfg.payloadDiversity.enable))
    return;
end
if ~(isfield(fhCfg, "enable") && logical(fhCfg.enable))
    error("fh.payloadDiversity requires fh.enable=true.");
end
if fh_is_fast(fhCfg)
    error("fh.payloadDiversity only supports slow FH.");
end

copies = local_required_positive_integer_local(fhCfg.payloadDiversity, "copies", "fh.payloadDiversity");
if copies < 2
    error("fh.payloadDiversity.copies must be >= 2 when enabled.");
end

if isstruct(scFdeInfo) && isfield(scFdeInfo, "enable") && logical(scFdeInfo.enable)
    hopLen = local_required_positive_integer_local(scFdeInfo, "hopLen", "scFdeInfo");
    nLogicalHops = local_required_nonnegative_integer_local(scFdeInfo, "nHops", "scFdeInfo");
    logicalSymbolsPadded = nLogicalHops * hopLen;
    if numel(txOut) ~= logicalSymbolsPadded
        error("payload diversity TX expects %d SC-FDE symbols, got %d.", logicalSymbolsPadded, numel(txOut));
    end
else
    hopLen = local_required_positive_integer_local(fhCfg, "symbolsPerHop", "fh");
    nLogicalHops = ceil(double(numel(txOut)) / double(hopLen));
    logicalSymbolsPadded = nLogicalHops * hopLen;
    if logicalSymbolsPadded > numel(txOut)
        txOut = [txOut; complex(zeros(logicalSymbolsPadded - numel(txOut), 1))];
    end
end

if logicalSymbolsPadded == 0
    info = struct( ...
        "enable", true, ...
        "copies", copies, ...
        "logicalHops", 0, ...
        "physicalHops", 0, ...
        "hopLen", hopLen, ...
        "inputSymbols", inputSymbols, ...
        "logicalSymbolsPadded", 0, ...
        "overheadFactor", 1.0);
    return;
end

txMat = reshape(txOut, hopLen, nLogicalHops);
txOut = kron(txMat, ones(1, copies));
txOut = txOut(:);
overheadFactor = 1.0;
if inputSymbols > 0
    overheadFactor = double(numel(txOut)) / double(inputSymbols);
end
info = struct( ...
    "enable", true, ...
    "copies", copies, ...
    "logicalHops", nLogicalHops, ...
    "physicalHops", nLogicalHops * copies, ...
    "hopLen", hopLen, ...
    "inputSymbols", inputSymbols, ...
    "logicalSymbolsPadded", logicalSymbolsPadded, ...
    "overheadFactor", overheadFactor);
end

function value = local_required_positive_integer_local(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s.%s is required.", ownerName, fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 1)
    error("%s.%s must be a positive integer scalar, got %g.", ownerName, fieldName, value);
end
value = round(value);
end

function value = local_required_nonnegative_integer_local(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s.%s is required.", ownerName, fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 0)
    error("%s.%s must be a nonnegative integer scalar, got %g.", ownerName, fieldName, value);
end
value = round(value);
end
