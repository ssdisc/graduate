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

if exist("int2bit", "file") ~= 2
    error("uint_to_bits requires Communications Toolbox function int2bit.");
end

switch lower(type)
    case {'uint8', 'uint8_scalar'}
        bits = uint8(int2bit(uint8(x), 8));

    case 'uint16'
        bits = uint8(int2bit(uint16(x), 16));

    case 'uint32'
        bits = uint8(int2bit(uint32(x), 32));

    case {'uint8vec', 'uint8_vec'}
        if isempty(x)
            bits = zeros(0, 1, "uint8");
            return;
        end
        bits = uint8(int2bit(uint8(x(:)), 8));

    otherwise
        error('未知类型: %s。请使用uint8, uint16, uint32或uint8vec。', type);
end
end
