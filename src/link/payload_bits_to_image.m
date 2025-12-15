function img = payload_bits_to_image(bits, meta)
%PAYLOAD_BITS_TO_IMAGE  将载荷比特流转换回图像。

bytes = bits_to_uint(bits, 'uint8vec');
needBytes = double(meta.rows) * double(meta.cols) * double(meta.channels);
if numel(bytes) < needBytes
    bytes(end+1:needBytes, 1) = 0; %#ok<AGROW>
else
    bytes = bytes(1:needBytes);
end
img = reshape(uint8(bytes), double(meta.rows), double(meta.cols), double(meta.channels));
end

