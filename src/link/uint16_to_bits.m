function bits = uint16_to_bits(x)
%UINT16_TO_BITS  Convert uint16 to MSB-first bit vector.

bits = false(16, 1);
for k = 1:16
    bits(k) = bitget(uint16(x), 17-k) ~= 0;
end
bits = uint8(bits);
end

