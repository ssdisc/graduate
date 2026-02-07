function [bits, meta] = image_to_payload_bits(img, payload)
%IMAGE_TO_PAYLOAD_BITS  将uint8图像转换为载荷比特流。
%
% 输入:
%   img     - 输入图像（uint8）
%   payload - 载荷配置结构体
%             .bitsPerPixel - 每像素比特数（当前链路按8处理）
%
% 输出:
%   bits - 图像字节对应的比特流
%   meta - 图像元数据结构体
%          .rows, .cols, .channels
%          .bitsPerPixel, .payloadBytes

rows = size(img, 1);
cols = size(img, 2);
ch = size(img, 3);

bytes = reshape(uint8(img), [], 1);
bits = uint_to_bits(bytes, 'uint8vec');

meta = struct();
meta.rows = uint16(rows);
meta.cols = uint16(cols);
meta.channels = uint8(ch);
meta.bitsPerPixel = uint8(payload.bitsPerPixel);
meta.payloadBytes = uint32(numel(bytes));
end

