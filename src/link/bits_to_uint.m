function x = bits_to_uint(bits, type)
%BITS_TO_UINT  Convert MSB-first bit vector to unsigned integer.
%
% Usage:
%   x = bits_to_uint(bits, 'uint8')     - 8 bits to uint8 scalar
%   x = bits_to_uint(bits, 'uint16')    - 16 bits to uint16 scalar
%   x = bits_to_uint(bits, 'uint32')    - 32 bits to uint32 scalar
%   x = bits_to_uint(bits, 'uint8vec')  - bit vector to uint8 vector

if nargin < 2
    type = 'uint8';
end

bits = uint8(bits(:) ~= 0);

switch lower(type)
    case {'uint8', 'uint8_scalar'}
        val = uint8(0);
        for k = 1:8
            val = bitshift(val, 1);
            val = bitor(val, uint8(bits(k)));
        end
        x = val;

    case 'uint16'
        val = uint16(0);
        for k = 1:16
            val = bitshift(val, 1);
            val = bitor(val, uint16(bits(k)));
        end
        x = val;

    case 'uint32'
        val = uint32(0);
        for k = 1:32
            val = bitshift(val, 1);
            val = bitor(val, uint32(bits(k)));
        end
        x = val;

    case {'uint8vec', 'uint8_vec'}
        nBits = numel(bits);
        nBytes = floor(nBits / 8);
        bits = bits(1:8*nBytes);
        bits = reshape(bits, 8, nBytes).';
        x = zeros(nBytes, 1, 'uint8');
        for k = 1:8
            x = bitset(x, 9-k, bits(:, k));
        end

    otherwise
        error('Unknown type: %s. Use uint8, uint16, uint32, or uint8vec.', type);
end
end
