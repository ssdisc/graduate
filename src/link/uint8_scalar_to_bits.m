function bits = uint8_scalar_to_bits(x)
%UINT8_SCALAR_TO_BITS  Convert uint8 scalar to MSB-first bit vector.

bits = false(8, 1);
for k = 1:8
    bits(k) = bitget(uint8(x), 9-k) ~= 0;
end
bits = uint8(bits);
end

