function [bits, meta] = image_to_payload_bits(img, payload)
%IMAGE_TO_PAYLOAD_BITS  Convert uint8 image to payload bitstream.

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

