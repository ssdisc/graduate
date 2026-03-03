function bits = uint_to_bits(x, type)
%UINT_TO_BITS  将无符号整数转换为MSB在前的比特向量。
%
% 用法:
%   bits = uint_to_bits(x, 'uint8')     - 8位标量
%   bits = uint_to_bits(x, 'uint16')    - 16位标量
%   bits = uint_to_bits(x, 'uint32')    - 32位标量
%   bits = uint_to_bits(bytes, 'uint8vec') - uint8向量转比特向量

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
        error('未知类型: %s。请使用uint8, uint16, uint32或uint8vec。', type);
end
end
