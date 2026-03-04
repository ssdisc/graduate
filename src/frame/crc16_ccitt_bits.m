function crc = crc16_ccitt_bits(bits)
%CRC16_CCITT_BITS  对比特流计算CRC-16/CCITT-FALSE。
%
% 参数:
%   bits - 列向量比特(0/1)
%
% 返回:
%   crc  - uint16校验值
%
% 约定:
%   poly=0x1021, init=0xFFFF, refin=false, refout=false, xorout=0x0000

bits = uint8(bits(:) ~= 0);
crc = uint16(hex2dec('FFFF'));
poly = uint16(hex2dec('1021'));

for i = 1:numel(bits)
    inBit = uint16(bits(i));
    msb = bitshift(crc, -15); % 取最高位(0/1)
    mix = bitxor(msb, inBit);
    crc = bitand(bitshift(crc, 1), uint16(65535));
    if mix ~= 0
        crc = bitxor(crc, poly);
    end
end
end
