function x = bits_to_uint8_scalar(bits)
%BITS_TO_UINT8_SCALAR  Convert MSB-first 8-bit vector to uint8 scalar.

bits = uint8(bits(:) ~= 0);
val = uint8(0);
for k = 1:8
    val = bitshift(val, 1);
    val = bitor(val, uint8(bits(k)));
end
x = val;
end

