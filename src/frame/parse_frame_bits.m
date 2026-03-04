function [payloadBits, meta, ok] = parse_frame_bits(rxBits, magic16)
%PARSE_FRAME_BITS  解析帧头并返回载荷比特和元数据。

rxBits = uint8(rxBits(:) ~= 0);

legacyHeaderBits = 16 + 16 + 16 + 8 + 8 + 32;
packetHeaderBits = legacyHeaderBits + 16 + 16 + 16 + 16;
if numel(rxBits) < legacyHeaderBits
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end

% 优先尝试“分包头”；不足时回退到“旧头”
usePacketHeader = numel(rxBits) >= packetHeaderBits;
idx = 1;
magic = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
if magic ~= uint16(magic16)
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end
rows = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
cols = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
channels = bits_to_uint(rxBits(idx:idx+7), 'uint8'); idx = idx + 8;
bpp = bits_to_uint(rxBits(idx:idx+7), 'uint8'); idx = idx + 8;
totalPayloadBytes = bits_to_uint(rxBits(idx:idx+31), 'uint32'); idx = idx + 32;

if usePacketHeader
    packetIndex = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
    totalPackets = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
    packetPayloadBytes = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
    packetCrc16 = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
else
    packetIndex = uint16(1);
    totalPackets = uint16(1);
    packetPayloadBytes = uint16(min(double(totalPayloadBytes), 65535));
    packetCrc16 = uint16(0);
end

% 基本合理性检查以避免损坏帧头时的灾难性reshape
if rows == 0 || cols == 0 || rows > 2048 || cols > 2048
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end
if ~(channels == 1 || channels == 3)
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end
if bpp ~= 8
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end
if totalPayloadBytes == 0 || packetPayloadBytes == 0
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end
if totalPackets == 0 || packetIndex == 0 || packetIndex > totalPackets
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end
needPayloadBits = double(packetPayloadBytes) * 8;
if numel(rxBits) < (idx - 1) + needPayloadBits
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end

meta = struct();
meta.rows = rows;
meta.cols = cols;
meta.channels = channels;
meta.bitsPerPixel = bpp;
meta.payloadBytes = totalPayloadBytes;           % 兼容旧字段
meta.totalPayloadBytes = totalPayloadBytes;
meta.packetIndex = packetIndex;
meta.totalPackets = totalPackets;
meta.packetPayloadBytes = packetPayloadBytes;
meta.packetCrc16 = packetCrc16;

payloadBits = rxBits(idx:idx + needPayloadBits - 1);
ok = true;
end

