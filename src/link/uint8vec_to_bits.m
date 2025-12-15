function bits = uint8vec_to_bits(bytes)
%UINT8VEC_TO_BITS  Pack uint8 vector into MSB-first bit vector.

bytes = uint8(bytes(:));
n = numel(bytes);
bits = false(8*n, 1);
for k = 1:8
    bits(k:8:end) = bitget(bytes, 9-k) ~= 0;
end
bits = uint8(bits);
end

