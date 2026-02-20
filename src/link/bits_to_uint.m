function x = bits_to_uint(bits, type)
%BITS_TO_UINT  将MSB在前的比特向量转换为无符号整数。
%
% 用法:
%   x = bits_to_uint(bits, 'uint8')     - 8比特转uint8标量
%   x = bits_to_uint(bits, 'uint16')    - 16比特转uint16标量
%   x = bits_to_uint(bits, 'uint32')    - 32比特转uint32标量
%   x = bits_to_uint(bits, 'uint8vec')  - 比特向量转uint8向量

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
        bits = reshape(bits, 8, nBytes).';%每行8比特对应一个字节
        x = zeros(nBytes, 1, 'uint8');
        for k = 1:8
            x = bitset(x, 9-k, bits(:, k));%第k列的比特对应字节中的第(9-k)位（MSB在前）
        end

    otherwise
        error('未知类型: %s。请使用uint8, uint16, uint32或uint8vec。', type);
end
end
