function ok = packet_crc_valid(payloadBitsRx, metaRx)
% 校验分包CRC16。
if ~isfield(metaRx, "packetCrc16") || ~isfield(metaRx, "packetPayloadBytes")
    ok = true; % 兼容旧头
    return;
end
needBits = double(metaRx.packetPayloadBytes) * 8;
if numel(payloadBitsRx) < needBits
    ok = false;
    return;
end
payloadUse = payloadBitsRx(1:needBits);
crcNow = crc16_ccitt_bits(payloadUse);
ok = uint16(metaRx.packetCrc16) == uint16(crcNow);
end

