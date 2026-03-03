function [headerBits, header] = build_header_bits(meta, magic16)
%BUILD_HEADER_BITS  构建固定长度帧头比特流。
%
% 输入:
%   meta    - 载荷元数据结构体
%             .rows, .cols, .channels
%             .bitsPerPixel, .payloadBytes
%   magic16 - 帧头魔数（uint16）
%
% 输出:
%   headerBits - 帧头比特流（列向量）
%   header     - 帧头结构体
%                .magic, .rows, .cols, .channels
%                .bitsPerPixel, .payloadBytes

header = struct();
header.magic = uint16(magic16);
header.rows = meta.rows;
header.cols = meta.cols;
header.channels = meta.channels;
header.bitsPerPixel = meta.bitsPerPixel;
header.payloadBytes = meta.payloadBytes;

fields = [ ...
    uint_to_bits(header.magic, 'uint16'); ...
    uint_to_bits(header.rows, 'uint16'); ...
    uint_to_bits(header.cols, 'uint16'); ...
    uint_to_bits(header.channels, 'uint8'); ...
    uint_to_bits(header.bitsPerPixel, 'uint8'); ...
    uint_to_bits(header.payloadBytes, 'uint32') ...
    ];
headerBits = uint8(fields);
end

