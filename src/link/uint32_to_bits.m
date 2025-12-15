function bits = uint32_to_bits(x)
%UINT32_TO_BITS  Convert uint32 to MSB-first bit vector.

bits = false(32, 1);
for k = 1:32
    bits(k) = bitget(uint32(x), 33-k) ~= 0;
end
bits = uint8(bits);
end

