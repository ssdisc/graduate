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
if exist("bit2int", "file") ~= 2
    error("bits_to_uint requires Communications Toolbox function bit2int.");
end

switch lower(type)
    case {'uint8', 'uint8_scalar'}
        x = uint8(bit2int(bits(1:8), 8));

    case 'uint16'
        x = uint16(bit2int(bits(1:16), 16));

    case 'uint32'
        x = uint32(bit2int(bits(1:32), 32));

    case {'uint8vec', 'uint8_vec'}
        nBits = numel(bits);
        nBytes = floor(nBits / 8);
        bits = bits(1:8*nBytes);
        bits = reshape(bits, 8, nBytes);
        x = uint8(bit2int(bits, 8).');

    otherwise
        error('未知类型: %s。请使用uint8, uint16, uint32或uint8vec。', type);
end
end
