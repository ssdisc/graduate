function [payloadBits, meta, ok] = parse_frame_bits(rxBits, magic16)
%PARSE_FRAME_BITS  Parse header and return payload bits and metadata.

rxBits = uint8(rxBits(:) ~= 0);

needHeaderBits = 16 + 16 + 16 + 8 + 8 + 32;
if numel(rxBits) < needHeaderBits
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end

idx = 1;
magic = bits_to_uint16(rxBits(idx:idx+15)); idx = idx + 16;
if magic ~= uint16(magic16)
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end

rows = bits_to_uint16(rxBits(idx:idx+15)); idx = idx + 16;
cols = bits_to_uint16(rxBits(idx:idx+15)); idx = idx + 16;
channels = bits_to_uint8_scalar(rxBits(idx:idx+7)); idx = idx + 8;
bpp = bits_to_uint8_scalar(rxBits(idx:idx+7)); idx = idx + 8;
payloadBytes = bits_to_uint32(rxBits(idx:idx+31)); idx = idx + 32;

% Basic sanity checks to avoid catastrophic reshape on corrupted headers
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

