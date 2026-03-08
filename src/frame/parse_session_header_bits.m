function [meta, payloadBits, ok] = parse_session_header_bits(rxBits, frameCfg)
%PARSE_SESSION_HEADER_BITS  解析首包中的会话头并返回剩余载荷比特。

if nargin < 2
    frameCfg = struct();
end

rxBits = uint8(rxBits(:) ~= 0);
needBits = 16 + 16 + 16 + 8 + 8 + 32 + 16 + 16;
if numel(rxBits) < needBits
    meta = struct();
    payloadBits = uint8([]);
    ok = false;
    return;
end

bodyBits = rxBits(1:needBits-16);
idx = 1;
magic = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
rows = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
cols = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
channels = bits_to_uint(bodyBits(idx:idx+7), 'uint8'); idx = idx + 8;
bitsPerPixel = bits_to_uint(bodyBits(idx:idx+7), 'uint8'); idx = idx + 8;
totalPayloadBytes = bits_to_uint(bodyBits(idx:idx+31), 'uint32'); idx = idx + 32;
totalPackets = bits_to_uint(bodyBits(idx:idx+15), 'uint16');
headerCrc16 = bits_to_uint(rxBits(needBits-15:needBits), 'uint16');

ok = true;
ok = ok && magic == local_session_magic(frameCfg);
ok = ok && crc16_ccitt_bits(bodyBits) == headerCrc16;
ok = ok && rows >= 1 && cols >= 1 && rows <= 4096 && cols <= 4096;
ok = ok && (channels == 1 || channels == 3);
ok = ok && bitsPerPixel == 8;
ok = ok && totalPayloadBytes >= 1;
ok = ok && totalPackets >= 1;

if ~ok
    meta = struct();
    payloadBits = uint8([]);
    return;
end

meta = struct();
meta.rows = rows;
meta.cols = cols;
meta.channels = channels;
meta.bitsPerPixel = bitsPerPixel;
meta.payloadBytes = totalPayloadBytes;
meta.totalPayloadBytes = totalPayloadBytes;
meta.totalPackets = totalPackets;
meta.sessionHeaderCrc16 = headerCrc16;
payloadBits = rxBits(needBits+1:end);
end

function magic16 = local_session_magic(frameCfg)
magic16 = uint16(hex2dec('C7E1'));
if isfield(frameCfg, "sessionMagic16") && ~isempty(frameCfg.sessionMagic16)
    magic16 = uint16(frameCfg.sessionMagic16);
end
end
