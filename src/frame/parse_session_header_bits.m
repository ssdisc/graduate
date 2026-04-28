function [meta, payloadBits, ok] = parse_session_header_bits(rxBits, frameCfg)
%PARSE_SESSION_HEADER_BITS Parse the session metadata header and residual payload bits.

if nargin < 2
    frameCfg = struct();
end

rxBits = uint8(rxBits(:) ~= 0);
fixedBodyBits = 16 + 16 + 16 + 8 + 8 + 32 + 16 + 16 + 16 + 16 + 8 + 16;
if numel(rxBits) < fixedBodyBits + 16
    meta = struct();
    payloadBits = uint8([]);
    ok = false;
    return;
end

idx = 1;
magic = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
rows = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
cols = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
channels = bits_to_uint(rxBits(idx:idx+7), 'uint8'); idx = idx + 8;
bitsPerPixel = bits_to_uint(rxBits(idx:idx+7), 'uint8'); idx = idx + 8;
totalPayloadBytes = bits_to_uint(rxBits(idx:idx+31), 'uint32'); idx = idx + 32;
totalDataPackets = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
totalPackets = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
rsDataPacketsPerBlock = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
rsParityPacketsPerBlock = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;
payloadCodecId = bits_to_uint(rxBits(idx:idx+7), 'uint8'); idx = idx + 8;
payloadManifestBytesLen = bits_to_uint(rxBits(idx:idx+15), 'uint16'); idx = idx + 16;

needBits = fixedBodyBits + double(payloadManifestBytesLen) * 8 + 16;
if numel(rxBits) < needBits
    meta = struct();
    payloadBits = uint8([]);
    ok = false;
    return;
end

payloadManifestBytes = uint8([]);
if double(payloadManifestBytesLen) > 0
    payloadManifestBytes = bits_to_uint( ...
        rxBits(idx:idx + double(payloadManifestBytesLen) * 8 - 1), 'uint8vec');
    payloadManifestBytes = uint8(payloadManifestBytes(:));
end

bodyBits = rxBits(1:needBits-16);
headerCrc16 = bits_to_uint(rxBits(needBits-15:needBits), 'uint16');

ok = true;
ok = ok && magic == local_session_magic(frameCfg);
ok = ok && crc16_ccitt_bits(bodyBits) == headerCrc16;
ok = ok && rows >= 1 && cols >= 1 && rows <= 4096 && cols <= 4096;
ok = ok && (channels == 1 || channels == 3);
ok = ok && bitsPerPixel == 8;
ok = ok && totalPayloadBytes >= 1;
ok = ok && totalDataPackets >= 1;
ok = ok && totalPackets >= 1;
ok = ok && totalPackets >= totalDataPackets;
ok = ok && rsDataPacketsPerBlock >= 1;
ok = ok && rsParityPacketsPerBlock >= 0;

baseMeta = struct( ...
    "rows", rows, ...
    "cols", cols, ...
    "channels", channels, ...
    "bitsPerPixel", bitsPerPixel, ...
    "payloadBytes", totalPayloadBytes, ...
    "totalPayloadBytes", totalPayloadBytes);

codec = "";
codecMeta = struct();
if ok
    try
        [codec, codecMeta] = parse_payload_codec_descriptor_bytes(payloadCodecId, payloadManifestBytes, baseMeta);
    catch
        ok = false;
    end
end

if ~ok
    meta = struct();
    payloadBits = uint8([]);
    return;
end

meta = baseMeta;
meta.totalDataPackets = totalDataPackets;
meta.totalPackets = totalPackets;
meta.rsDataPacketsPerBlock = rsDataPacketsPerBlock;
meta.rsParityPacketsPerBlock = rsParityPacketsPerBlock;
meta.sessionHeaderCrc16 = headerCrc16;
meta.codec = codec;
meta.codecMeta = codecMeta;
payloadBits = rxBits(needBits+1:end);
end

function magic16 = local_session_magic(frameCfg)
magic16 = uint16(hex2dec('C7E1'));
if isfield(frameCfg, "sessionMagic16") && ~isempty(frameCfg.sessionMagic16)
    magic16 = uint16(frameCfg.sessionMagic16);
end
end
