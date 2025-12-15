function bits = uint_to_bits(x, type)
%UINT_TO_BITS  Convert unsigned integer to MSB-first bit vector.
%
% Usage:
%   bits = uint_to_bits(x, 'uint8')     - 8-bit scalar
%   bits = uint_to_bits(x, 'uint16')    - 16-bit scalar
%   bits = uint_to_bits(x, 'uint32')    - 32-bit scalar
%   bits = uint_to_bits(bytes, 'uint8vec') - uint8 vector to bit vector

if nargin < 2
    type = 'uint8';
end

switch lower(type)
    case {'uint8', 'uint8_scalar'}
        bits = false(8, 1);
        for k = 1:8
            bits(k) = bitget(uint8(x), 9-k) ~= 0;
        end
        bits = uint8(bits);

    case 'uint16'
        bits = false(16, 1);
        for k = 1:16
            bits(k) = bitget(uint16(x), 17-k) ~= 0;
        end
        bits = uint8(bits);

    case 'uint32'
        bits = false(32, 1);
        for k = 1:32
            bits(k) = bitget(uint32(x), 33-k) ~= 0;
        end
        bits = uint8(bits);

    case {'uint8vec', 'uint8_vec'}
        bytes = uint8(x(:));
        n = numel(bytes);
        bits = false(8*n, 1);
        for k = 1:8
            bits(k:8:end) = bitget(bytes, 9-k) ~= 0;
        end
        bits = uint8(bits);

    otherwise
        error('Unknown type: %s. Use uint8, uint16, uint32, or uint8vec.', type);
end
end
