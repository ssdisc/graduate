function [header, ok] = parse_phy_header_bits(rxBits, frameCfg)
%PARSE_PHY_HEADER_BITS  解析固定长度PHY小头。
%
% 字段（compact_fec）：
%   magic8 | packetIndex16 | packetDataCrc16 | headerCrc16
%
% 字段（legacy_repeat）：
%   magic16 | flags8 | packetIndex16 | packetDataBytes16 | packetDataCrc16 | headerCrc16

if nargin < 2
    frameCfg = struct();
end

rxBits = uint8(rxBits(:) ~= 0);
mode = local_phy_header_mode(frameCfg);
needBits = phy_header_length_bits(frameCfg);
if numel(rxBits) < needBits
    header = struct();
    ok = false;
    return;
end

bodyBits = rxBits(1:needBits-16);
idx = 1;
magic = uint16(0);
flags = uint8(0);
packetDataBytes = uint16(0);
switch mode
    case "compact_fec"
        magic = uint16(bits_to_uint(bodyBits(idx:idx+7), 'uint8')); idx = idx + 8;
        packetIndex = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
        packetDataCrc16 = bits_to_uint(bodyBits(idx:idx+15), 'uint16');
    case "legacy_repeat"
        magic = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
        flags = bits_to_uint(bodyBits(idx:idx+7), 'uint8'); idx = idx + 8;
        packetIndex = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
        packetDataBytes = bits_to_uint(bodyBits(idx:idx+15), 'uint16'); idx = idx + 16;
        packetDataCrc16 = bits_to_uint(bodyBits(idx:idx+15), 'uint16');
    otherwise
        error("Unsupported phyHeaderMode: %s", string(mode));
end
headerCrc16 = bits_to_uint(rxBits(needBits-15:needBits), 'uint16');

header = struct();
header.magic = magic;
header.flags = flags;
if mode == "compact_fec"
    header.hasSessionHeader = local_has_session_header(frameCfg, double(packetIndex));
else
    header.hasSessionHeader = bitand(flags, uint8(1)) ~= 0;
end
header.packetIndex = packetIndex;
header.packetDataBytes = packetDataBytes;
header.packetDataCrc16 = packetDataCrc16;
header.headerCrc16 = headerCrc16;

ok = true;
ok = ok && packetIndex >= 1;
if mode == "compact_fec"
    ok = ok && uint8(magic) == local_compact_phy_magic(frameCfg);
elseif mode == "legacy_repeat"
    ok = ok && magic == local_phy_magic(frameCfg);
    ok = ok && packetDataBytes >= 1;
end
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

function magic8 = local_compact_phy_magic(frameCfg)
magic8 = uint8(bitand(local_phy_magic(frameCfg), uint16(255)));
end

function tf = local_has_session_header(frameCfg, pktIdx)
if ~session_header_enabled(frameCfg)
    tf = false;
    return;
end
tf = (pktIdx == 1) || (is_long_sync_packet(frameCfg, pktIdx) && local_repeat_session_header_on_resync(frameCfg));
end

function tf = local_repeat_session_header_on_resync(frameCfg)
tf = false;
if isfield(frameCfg, "repeatSessionHeaderOnResync") && ~isempty(frameCfg.repeatSessionHeaderOnResync)
    tf = logical(frameCfg.repeatSessionHeaderOnResync);
end
end

function mode = local_phy_header_mode(frameCfg)
mode = "compact_fec";
if isfield(frameCfg, "phyHeaderMode") && strlength(string(frameCfg.phyHeaderMode)) > 0
    mode = lower(string(frameCfg.phyHeaderMode));
end
end
