function x = bits_to_uint32(bits)
%BITS_TO_UINT32  Convert MSB-first 32-bit vector to uint32.

bits = uint8(bits(:) ~= 0);
val = uint32(0);
for k = 1:32
    val = bitshift(val, 1);
    val = bitor(val, uint32(bits(k)));
end
x = val;
end

