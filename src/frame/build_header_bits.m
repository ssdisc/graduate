function [headerBits, header] = build_header_bits(meta, magic16)
%BUILD_HEADER_BITS  构建固定长度帧头比特流。
%
% 输入:
%   meta    - 载荷元数据结构体
%             .rows, .cols, .channels, .bitsPerPixel
%             .payloadBytes / .totalPayloadBytes
%             .packetIndex, .totalPackets（可选）
%             .packetPayloadBytes（可选）
%             .packetCrc16（可选）
%   magic16 - 帧头魔数（uint16）
%
% 输出:
%   headerBits - 帧头比特流（列向量）
%   header     - 帧头结构体
%                .magic, .rows, .cols, .channels, .bitsPerPixel
%                .totalPayloadBytes, .packetIndex, .totalPackets
%                .packetPayloadBytes, .packetCrc16

header = struct();
header.magic = uint16(magic16);
header.rows = uint16(meta.rows);
header.cols = uint16(meta.cols);
header.channels = uint8(meta.channels);
header.bitsPerPixel = uint8(meta.bitsPerPixel);

if isfield(meta, "totalPayloadBytes")
    header.totalPayloadBytes = uint32(meta.totalPayloadBytes);
else
    header.totalPayloadBytes = uint32(meta.payloadBytes);
end

if isfield(meta, "packetIndex")
    header.packetIndex = uint16(meta.packetIndex);
else
    header.packetIndex = uint16(1);
end
if isfield(meta, "totalPackets")
    header.totalPackets = uint16(meta.totalPackets);
else
    header.totalPackets = uint16(1);
end
if isfield(meta, "packetPayloadBytes")
    header.packetPayloadBytes = uint16(meta.packetPayloadBytes);
else
    header.packetPayloadBytes = uint16(min(double(header.totalPayloadBytes), 65535));
end
if isfield(meta, "packetCrc16")
    header.packetCrc16 = uint16(meta.packetCrc16);
else
    header.packetCrc16 = uint16(0);
end

% 兼容旧字段命名
header.payloadBytes = header.totalPayloadBytes;

fields = [ ...
    uint_to_bits(header.magic, 'uint16'); ...
    uint_to_bits(header.rows, 'uint16'); ...
    uint_to_bits(header.cols, 'uint16'); ...
    uint_to_bits(header.channels, 'uint8'); ...
    uint_to_bits(header.bitsPerPixel, 'uint8'); ...
    uint_to_bits(header.totalPayloadBytes, 'uint32'); ...
    uint_to_bits(header.packetIndex, 'uint16'); ...
    uint_to_bits(header.totalPackets, 'uint16'); ...
    uint_to_bits(header.packetPayloadBytes, 'uint16'); ...
    uint_to_bits(header.packetCrc16, 'uint16') ...
    ];
headerBits = uint8(fields);
end

