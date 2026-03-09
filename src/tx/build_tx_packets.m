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

nPackets = max(1, ceil(totalBits / pktBitsPerPacket));
if nPackets > 65535
    error("分包数量过大(%d)，超出uint16可表示范围。", nPackets);
end

sessionMeta = meta;
sessionMeta.totalPayloadBytes = uint32(meta.payloadBytes);
sessionMeta.totalPackets = uint16(nPackets);
[sessionHeaderBits, sessionHeader] = build_session_header_bits(sessionMeta, p.frame);
sessionHeaderLenBits = numel(sessionHeaderBits);

phyHeaderLenBits = 16 + 8 + 16 + 16 + 16 + 16;
phyRepeat = phy_header_repeat_local(p.frame);
phyHeaderSymLen = phyHeaderLenBits * phyRepeat;
[~, firstSyncSym] = make_packet_sync(p.frame, 1);
[~, shortSyncSym] = make_packet_sync(p.frame, 2);

fhEnabled = isfield(p, 'fh') && isfield(p.fh, 'enable') && p.fh.enable;
packetChaosEnable = packetIndependentBitChaos && isfield(p, "chaosEncrypt") ...
    && isfield(p.chaosEncrypt, "enable") && p.chaosEncrypt.enable;

if packetEnable
    maxPacketDataBits = sessionHeaderLenBits + pktBitsPerPacket;
else
    maxPacketDataBits = sessionHeaderLenBits + totalBits;
end
maxPacketDataSym = n_symbols_for_info_bits_local(p, maxPacketDataBits);
packetStrideBits = maxPacketDataBits;
packetStrideHops = packet_stride_hops_local(p, maxPacketDataSym);

txPackets = repmat(struct(), nPackets, 1);
txBurstChannelParts = cell(nPackets, 1);
txBurstSpectrumParts = cell(nPackets, 1);
modInfoRef = struct();

for pktIdx = 1:nPackets
    startBit = (pktIdx - 1) * pktBitsPerPacket + 1;
    endBit = min(pktIdx * pktBitsPerPacket, totalBits);
    payloadPktPlain = payloadBits(startBit:endBit);
    payloadPkt = payloadPktPlain;
    chaosEncInfoPkt = struct('enabled', false, 'mode', "none");
    if packetChaosEnable
        chaosPktCfg = derive_packet_chaos_cfg(p.chaosEncrypt, pktIdx);
        [payloadPkt, chaosEncInfoPkt] = chaos_encrypt_bits(payloadPktPlain, chaosPktCfg);
    end
    payloadPktBytes = ceil(numel(payloadPkt) / 8);
    if payloadPktBytes > 65535
        error("单包payload过大(%d bytes)，超出uint16可表示范围。", payloadPktBytes);
    end

    offsetsPkt = derive_packet_state_offsets(p, pktIdx);
    hasSessionHeader = offsetsPkt.hasSessionHeader;
    if hasSessionHeader
        packetDataBits = [sessionHeaderBits; payloadPkt];
    else
        packetDataBits = payloadPkt;
    end
    packetDataBitsLen = numel(packetDataBits);
    packetDataBytes = ceil(packetDataBitsLen / 8);
    if packetDataBytes > 65535
        error("单包受保护数据过大(%d bytes)，超出uint16可表示范围。", packetDataBytes);
    end

    phyMeta = struct();
    phyMeta.hasSessionHeader = hasSessionHeader;
    phyMeta.packetIndex = uint16(pktIdx);
    phyMeta.packetDataBytes = uint16(packetDataBytes);
    phyMeta.packetDataCrc16 = crc16_ccitt_bits(packetDataBits);
    [phyHeaderBits, phyHeader] = build_phy_header_bits(phyMeta, p.frame);
    phyHeaderSym = modulate_repeated_bpsk_bits_local(phyHeaderBits, phyRepeat);

    scrambleCfgPkt = derive_packet_scramble_cfg(p.scramble, pktIdx, offsetsPkt.scrambleOffsetBits);
    dataBitsTxScr = scramble_bits(packetDataBits, scrambleCfgPkt);
    codedBits = fec_encode(dataBitsTxScr, p.fec);
    [codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);
    [dataSymTx, modInfo] = modulate_bits(codedBitsInt, p.mod);
    modInfoRef = modInfo;

    if fhEnabled
        fhCfgPkt = derive_packet_fh_cfg(p.fh, pktIdx, offsetsPkt.fhOffsetHops, numel(dataSymTx));
        [dataSymHop, hopInfo] = fh_modulate(dataSymTx, fhCfgPkt);
    else
        dataSymHop = dataSymTx;
        hopInfo = struct('enable', false);
        fhCfgPkt = struct('enable', false);
    end

    [~, syncSymPkt, syncInfoPkt] = make_packet_sync(p.frame, pktIdx);
    txSymPkt = [syncSymPkt; phyHeaderSym; dataSymHop];
    txSymForChannel = pulse_tx_from_symbol_rate(txSymPkt, waveform);

    txPackets(pktIdx).packetIndex = pktIdx;
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
    txPackets(pktIdx).phyHeader = phyHeader;
    txPackets(pktIdx).phyHeaderBits = phyHeaderBits;
    txPackets(pktIdx).phyHeaderSym = phyHeaderSym;
    txPackets(pktIdx).stateOffsets = offsetsPkt;
    txPackets(pktIdx).scrambleCfg = scrambleCfgPkt;
    txPackets(pktIdx).dataSymTx = dataSymTx;
    txPackets(pktIdx).fhCfg = fhCfgPkt;
    txPackets(pktIdx).hopInfo = hopInfo;
    txPackets(pktIdx).intState = intState;
    txPackets(pktIdx).txSymPkt = txSymPkt;
    txPackets(pktIdx).txSymForChannel = txSymForChannel;
    txBurstChannelParts{pktIdx} = txSymForChannel;
    txBurstSpectrumParts{pktIdx} = txSymPkt;
end

plan = struct();
plan.packetEnable = packetEnable;
plan.nPackets = nPackets;
plan.sessionHeaderLenBits = sessionHeaderLenBits;
plan.phyHeaderLenBits = phyHeaderLenBits;
plan.phyHeaderSymLen = phyHeaderSymLen;
plan.firstSyncSymLen = numel(firstSyncSym);
plan.shortSyncSymLen = numel(shortSyncSym);
plan.packetStrideBits = packetStrideBits;
plan.packetStrideHops = packetStrideHops;
plan.fhEnabled = fhEnabled;
plan.packetChaosEnable = packetChaosEnable;
plan.waveform = waveform;
plan.modInfo = modInfoRef;
plan.txBurstForChannel = vertcat(txBurstChannelParts{:});
plan.txBurstForSpectrum = vertcat(txBurstSpectrumParts{:});
end

function nSym = n_symbols_for_info_bits_local(p, nInfoBits)
bitsPerSym = bits_per_symbol_local(p.mod);
codedBitsLen = coded_bits_length_local(nInfoBits, p.fec);
nSym = ceil(codedBitsLen / bitsPerSym);
end

function nHops = packet_stride_hops_local(p, nSym)
if ~isfield(p, "fh") || ~isstruct(p.fh) || ~isfield(p.fh, "enable") || ~p.fh.enable
    nHops = 0;
    return;
end
nHops = ceil(double(nSym) / double(p.fh.symbolsPerHop));
end

function repeat = phy_header_repeat_local(frameCfg)
repeat = 3;
if isfield(frameCfg, "phyHeaderRepeat") && ~isempty(frameCfg.phyHeaderRepeat)
    repeat = max(1, round(double(frameCfg.phyHeaderRepeat)));
end
end

function sym = modulate_repeated_bpsk_bits_local(bits, repeat)
bits = uint8(bits(:) ~= 0);
repeat = max(1, round(double(repeat)));
sym = 1 - 2 * double(repelem(bits, repeat));
sym = sym(:);
end

function nBits = coded_bits_length_local(nInfoBits, fec)
numInputBits = log2(fec.trellis.numInputSymbols);
numOutputBits = log2(fec.trellis.numOutputSymbols);
nBits = round(double(nInfoBits) * numOutputBits / numInputBits);
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
