function [headerBits, header] = build_session_header_bits(meta, frameCfg)
%BUILD_SESSION_HEADER_BITS  构建首包中的会话头。
%
% 字段：
%   magic16 | rows16 | cols16 | channels8 | bitsPerPixel8 |
%   totalPayloadBytes32 | totalPackets16 | headerCrc16

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
if isfield(meta, "totalPackets")
    header.totalPackets = uint16(meta.totalPackets);
else
    header.totalPackets = uint16(1);
end
header.payloadBytes = header.totalPayloadBytes;

bodyBits = [ ...
    uint_to_bits(header.magic, 'uint16'); ...
    uint_to_bits(header.rows, 'uint16'); ...
    uint_to_bits(header.cols, 'uint16'); ...
    uint_to_bits(header.channels, 'uint8'); ...
    uint_to_bits(header.bitsPerPixel, 'uint8'); ...
    uint_to_bits(header.totalPayloadBytes, 'uint32'); ...
    uint_to_bits(header.totalPackets, 'uint16') ...
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
