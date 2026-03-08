function [headerBits, header] = build_phy_header_bits(phy, frameCfg)
%BUILD_PHY_HEADER_BITS  构建固定长度PHY小头。
%
% 字段：
%   magic16 | flags8 | packetIndex16 | packetDataBytes16 | packetDataCrc16 | headerCrc16

if nargin < 2
    frameCfg = struct();
end

magic16 = local_phy_magic(frameCfg);

header = struct();
header.magic = uint16(magic16);

flags = uint8(0);
if isfield(phy, "hasSessionHeader") && logical(phy.hasSessionHeader)
    flags = bitor(flags, uint8(1));
end
header.flags = flags;

header.packetIndex = uint16(phy.packetIndex);
header.packetDataBytes = uint16(phy.packetDataBytes);
header.packetDataCrc16 = uint16(phy.packetDataCrc16);

bodyBits = [ ...
    uint_to_bits(header.magic, 'uint16'); ...
    uint_to_bits(header.flags, 'uint8'); ...
    uint_to_bits(header.packetIndex, 'uint16'); ...
    uint_to_bits(header.packetDataBytes, 'uint16'); ...
    uint_to_bits(header.packetDataCrc16, 'uint16') ...
    ];
header.headerCrc16 = crc16_ccitt_bits(bodyBits);

headerBits = [bodyBits; uint_to_bits(header.headerCrc16, 'uint16')];
end

function magic16 = local_phy_magic(frameCfg)
magic16 = hex2dec('3AC5');
if isfield(frameCfg, "phyMagic16") && ~isempty(frameCfg.phyMagic16)
    magic16 = uint16(frameCfg.phyMagic16);
end
end
