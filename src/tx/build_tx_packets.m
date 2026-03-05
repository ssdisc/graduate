function [txPackets, plan] = build_tx_packets(payloadBits, meta, p, preambleSym, packetIndependentBitChaos, waveform)
% 按配置将整图载荷切分为多个分包并构建发送符号。
payloadBits = uint8(payloadBits(:) ~= 0);
totalBits = numel(payloadBits);
if nargin < 5
    packetIndependentBitChaos = false;
end
if nargin < 6
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

fhEnabled = isfield(p, 'fh') && isfield(p.fh, 'enable') && p.fh.enable;
packetChaosEnable = packetIndependentBitChaos && isfield(p, "chaosEncrypt") ...
    && isfield(p.chaosEncrypt, "enable") && p.chaosEncrypt.enable;
txPackets = repmat(struct(), nPackets, 1);
txBurstChannelParts = cell(nPackets, 1);
txBurstSpectrumParts = cell(nPackets, 1);
modInfoRef = struct();
headerLenBits = 0;

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

    metaPkt = meta;
    metaPkt.totalPayloadBytes = uint32(meta.payloadBytes);
    metaPkt.packetIndex = uint16(pktIdx);
    metaPkt.totalPackets = uint16(nPackets);
    metaPkt.packetPayloadBytes = uint16(payloadPktBytes);
    metaPkt.packetCrc16 = crc16_ccitt_bits(payloadPkt);
    [headerBits, ~] = build_header_bits(metaPkt, p.frame.magic16);
    headerLenBits = numel(headerBits);

    dataBitsTx = [headerBits; payloadPkt];
    dataBitsTxScr = scramble_bits(dataBitsTx, p.scramble);
    codedBits = fec_encode(dataBitsTxScr, p.fec);
    [codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);
    [dataSymTx, modInfo] = modulate_bits(codedBitsInt, p.mod);
    modInfoRef = modInfo;

    if fhEnabled
        [dataSymHop, hopInfo] = fh_modulate(dataSymTx, p.fh);
    else
        dataSymHop = dataSymTx;
        hopInfo = struct('enable', false);
    end

    txSymPkt = [preambleSym; dataSymHop];
    txSymForChannel = pulse_tx_from_symbol_rate(txSymPkt, waveform);

    txPackets(pktIdx).startBit = startBit;
    txPackets(pktIdx).endBit = endBit;
    txPackets(pktIdx).payloadBitsPlain = payloadPktPlain;
    txPackets(pktIdx).payloadBits = payloadPkt;
    txPackets(pktIdx).payloadBytes = payloadPktBytes;
    txPackets(pktIdx).chaosEncInfo = chaosEncInfoPkt;
    txPackets(pktIdx).dataSymTx = dataSymTx;
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
plan.headerLenBits = headerLenBits;
plan.fhEnabled = fhEnabled;
plan.packetChaosEnable = packetChaosEnable;
plan.waveform = waveform;
plan.modInfo = modInfoRef;
plan.txBurstForChannel = vertcat(txBurstChannelParts{:});
plan.txBurstForSpectrum = vertcat(txBurstSpectrumParts{:});
end

