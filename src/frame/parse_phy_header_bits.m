function [header, ok] = parse_phy_header_bits(rxBits, frameCfg)
%PARSE_PHY_HEADER_BITS  解析固定长度PHY小头。
%
% 字段：
%   magic16 | flags8 | packetIndex16 | packetDataBytes16 | packetDataCrc16 | headerCrc16

if nargin < 2
    frameCfg = struct();
end

rxBits = uint8(rxBits(:) ~= 0);
needBits = 16 + 8 + 16 + 16 + 16 + 16;
if numel(rxBits) < needBits
    header = struct();
    ok = false;
    return;
end

bodyBits = rxBits(1:needBits-16);
idx = 1;
magic = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
flags = bits_to_uint(bodyBits(idx:idx+7), 'uint8'); idx = idx + 8;
packetIndex = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
packetDataBytes = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
packetDataCrc16 = bits_to_uint(bodyBits(idx:idx+15), 'uint16');
headerCrc16 = bits_to_uint(rxBits(needBits-15:needBits), 'uint16');

header = struct();
header.magic = magic;
header.flags = flags;
header.hasSessionHeader = bitand(flags, uint8(1)) ~= 0;
header.packetIndex = packetIndex;
header.packetDataBytes = packetDataBytes;
header.packetDataCrc16 = packetDataCrc16;
header.headerCrc16 = headerCrc16;

ok = true;
ok = ok && magic == local_phy_magic(frameCfg);
ok = ok && packetIndex >= 1;
ok = ok && packetDataBytes >= 1;
ok = ok && crc16_ccitt_bits(bodyBits) == headerCrc16;

if ~ok
    header = struct();
end
end

function magic16 = local_phy_magic(frameCfg)
magic16 = uint16(hex2dec('3AC5'));
if isfield(frameCfg, "phyMagic16") && ~isempty(frameCfg.phyMagic16)
    magic16 = uint16(frameCfg.phyMagic16);
end
end
