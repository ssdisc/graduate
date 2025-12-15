function x = bits_to_uint16(bits)
%BITS_TO_UINT16  Convert MSB-first 16-bit vector to uint16.

bits = uint8(bits(:) ~= 0);
val = uint16(0);
for k = 1:16
    val = bitshift(val, 1);
    val = bitor(val, uint16(bits(k)));
end
x = val;
end

