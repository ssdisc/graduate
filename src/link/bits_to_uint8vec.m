function bytes = bits_to_uint8vec(bits)
%BITS_TO_UINT8VEC  Unpack MSB-first bit vector into uint8 vector.

bits = uint8(bits(:) ~= 0);
nBits = numel(bits);
nBytes = floor(nBits / 8);
bits = bits(1:8*nBytes);
bits = reshape(bits, 8, nBytes).';
bytes = zeros(nBytes, 1, "uint8");
for k = 1:8
    bytes = bitset(bytes, 9-k, bits(:, k));
end
end

