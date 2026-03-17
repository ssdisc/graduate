function [headerBits, header] = build_phy_header_bits(phy, frameCfg)
%BUILD_PHY_HEADER_BITS  构建固定长度PHY小头。
%
% 字段（compact_fec）：
%   magic8 | packetIndex16 | packetDataCrc16 | headerCrc16
%
% 字段（legacy_repeat）：
%   magic16 | flags8 | packetIndex16 | packetDataBytes16 | packetDataCrc16 | headerCrc16

if nargin < 2
    frameCfg = struct();
end

mode = local_phy_header_mode(frameCfg);

header = struct();
header.magic = uint16(0);
header.flags = uint8(0);
header.hasSessionHeader = logical(isfield(phy, "hasSessionHeader") && phy.hasSessionHeader);
if header.hasSessionHeader
    header.flags = bitor(header.flags, uint8(1));
end
header.packetIndex = uint16(phy.packetIndex);
if isfield(phy, "packetDataBytes")
    header.packetDataBytes = uint16(phy.packetDataBytes);
else
    header.packetDataBytes = uint16(0);
end
header.packetDataCrc16 = uint16(phy.packetDataCrc16);

switch mode
    case "compact_fec"
        header.magic = uint16(local_compact_phy_magic(frameCfg));
        header.flags = uint8(0);
        header.packetDataBytes = uint16(0);
        bodyBits = [ ...
            uint_to_bits(uint8(header.magic), 'uint8'); ...
            uint_to_bits(header.packetIndex, 'uint16'); ...
            uint_to_bits(header.packetDataCrc16, 'uint16') ...
            ];
    case "legacy_repeat"
        header.magic = local_phy_magic(frameCfg);
        bodyBits = [ ...
            uint_to_bits(header.magic, 'uint16'); ...
            uint_to_bits(header.flags, 'uint8'); ...
            uint_to_bits(header.packetIndex, 'uint16'); ...
            uint_to_bits(header.packetDataBytes, 'uint16'); ...
            uint_to_bits(header.packetDataCrc16, 'uint16') ...
            ];
    otherwise
        error("Unsupported phyHeaderMode: %s", string(mode));
end

header.headerCrc16 = crc16_ccitt_bits(bodyBits);
headerBits = [bodyBits; uint_to_bits(header.headerCrc16, 'uint16')];
end

function mode = local_phy_header_mode(frameCfg)
mode = "compact_fec";
if isfield(frameCfg, "phyHeaderMode") && strlength(string(frameCfg.phyHeaderMode)) > 0
    mode = lower(string(frameCfg.phyHeaderMode));
end
end

function magic16 = local_phy_magic(frameCfg)
magic16 = uint16(hex2dec('3AC5'));
if isfield(frameCfg, "phyMagic16") && ~isempty(frameCfg.phyMagic16)
    magic16 = uint16(frameCfg.phyMagic16);
end
end

function magic8 = local_compact_phy_magic(frameCfg)
magic8 = uint8(bitand(local_phy_magic(frameCfg), uint16(255)));
end
