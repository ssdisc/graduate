function [headerBits, header] = build_session_header_bits(meta, frameCfg)
%BUILD_SESSION_HEADER_BITS Build the session metadata header.
%
% 字段：
%   magic16 | rows16 | cols16 | channels8 | bitsPerPixel8 |
%   totalPayloadBytes32 | totalDataPackets16 | totalTxPackets16 |
%   rsDataPacketsPerBlock16 | rsParityPacketsPerBlock16 |
%   payloadCodecId8 | payloadManifestBytes16 | payloadManifestBytes |
%   headerCrc16

if nargin < 2
    frameCfg = struct();
end

header = struct();
header.magic = local_session_magic(frameCfg);
header.rows = uint16(meta.rows);
header.cols = uint16(meta.cols);
header.channels = uint8(meta.channels);
header.bitsPerPixel = uint8(meta.bitsPerPixel);
if isfield(meta, "totalPayloadBytes")
    header.totalPayloadBytes = uint32(meta.totalPayloadBytes);
else
    header.totalPayloadBytes = uint32(meta.payloadBytes);
end
if isfield(meta, "totalDataPackets")
    header.totalDataPackets = uint16(meta.totalDataPackets);
else
    header.totalDataPackets = uint16(1);
end
if isfield(meta, "totalPackets")
    header.totalPackets = uint16(meta.totalPackets);
else
    header.totalPackets = header.totalDataPackets;
end
if isfield(meta, "rsDataPacketsPerBlock")
    header.rsDataPacketsPerBlock = uint16(meta.rsDataPacketsPerBlock);
else
    header.rsDataPacketsPerBlock = header.totalDataPackets;
end
if isfield(meta, "rsParityPacketsPerBlock")
    header.rsParityPacketsPerBlock = uint16(meta.rsParityPacketsPerBlock);
else
    header.rsParityPacketsPerBlock = uint16(0);
end
header.payloadBytes = header.totalPayloadBytes;

[payloadCodecId, payloadManifestBytes, payloadCodecInfo] = build_payload_codec_descriptor_bytes(meta);
header.payloadCodecId = uint8(payloadCodecId);
header.payloadCodec = string(payloadCodecInfo.codec);
header.payloadManifestBytes = uint8(payloadManifestBytes(:));
header.payloadManifestBytesLen = uint16(numel(payloadManifestBytes));

bodyBits = [ ...
    uint_to_bits(header.magic, 'uint16'); ...
    uint_to_bits(header.rows, 'uint16'); ...
    uint_to_bits(header.cols, 'uint16'); ...
    uint_to_bits(header.channels, 'uint8'); ...
    uint_to_bits(header.bitsPerPixel, 'uint8'); ...
    uint_to_bits(header.totalPayloadBytes, 'uint32'); ...
    uint_to_bits(header.totalDataPackets, 'uint16'); ...
    uint_to_bits(header.totalPackets, 'uint16'); ...
    uint_to_bits(header.rsDataPacketsPerBlock, 'uint16'); ...
    uint_to_bits(header.rsParityPacketsPerBlock, 'uint16'); ...
    uint_to_bits(header.payloadCodecId, 'uint8'); ...
    uint_to_bits(header.payloadManifestBytesLen, 'uint16'); ...
    uint_to_bits(header.payloadManifestBytes, 'uint8vec') ...
    ];
header.headerCrc16 = crc16_ccitt_bits(bodyBits);
headerBits = [bodyBits; uint_to_bits(header.headerCrc16, 'uint16')];
end

function magic16 = local_session_magic(frameCfg)
magic16 = uint16(hex2dec('C7E1'));
if isfield(frameCfg, "sessionMagic16") && ~isempty(frameCfg.sessionMagic16)
    magic16 = uint16(frameCfg.sessionMagic16);
end
end
