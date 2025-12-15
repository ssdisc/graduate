function img = payload_bits_to_image(bits, meta)
%PAYLOAD_BITS_TO_IMAGE  Convert payload bitstream back to image.

bytes = bits_to_uint8vec(bits);
needBytes = double(meta.rows) * double(meta.cols) * double(meta.channels);
if numel(bytes) < needBytes
    bytes(end+1:needBytes, 1) = 0; %#ok<AGROW>
else
    bytes = bytes(1:needBytes);
end
img = reshape(uint8(bytes), double(meta.rows), double(meta.cols), double(meta.channels));
end

