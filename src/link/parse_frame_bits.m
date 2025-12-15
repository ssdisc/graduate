function [payloadBits, meta, ok] = parse_frame_bits(rxBits, magic16)
%PARSE_FRAME_BITS  解析帧头并返回载荷比特和元数据。

rxBits = uint8(rxBits(:) ~= 0);

needHeaderBits = 16 + 16 + 16 + 8 + 8 + 32;
if numel(rxBits) < needHeaderBits
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end

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
payloadBytes = bits_to_uint(rxBits(idx:idx+31), 'uint32'); idx = idx + 32;

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
expectedBytes = uint32(rows) * uint32(cols) * uint32(channels);
if payloadBytes ~= expectedBytes
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
meta.payloadBytes = payloadBytes;

payloadBits = rxBits(idx:end);
ok = true;
end

