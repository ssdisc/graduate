function img = payload_bits_to_image(bits, meta)
%PAYLOAD_BITS_TO_IMAGE  将载荷比特流转换回图像。
%
% 输入:
%   bits - 载荷比特流
%   meta - 图像元数据结构体
%          .rows, .cols, .channels
%
% 输出:
%   img - 恢复后的uint8图像

bytes = bits_to_uint(bits, 'uint8vec');
needBytes = double(meta.rows) * double(meta.cols) * double(meta.channels);
if numel(bytes) < needBytes
    bytes(end+1:needBytes, 1) = 0; %#ok<AGROW>
else
    bytes = bytes(1:needBytes);
end
img = reshape(uint8(bytes), double(meta.rows), double(meta.cols), double(meta.channels));
end

