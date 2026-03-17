function nBits = phy_header_length_bits(frameCfg)
%PHY_HEADER_LENGTH_BITS  Return the uncoded PHY-header information length.

mode = local_phy_header_mode(frameCfg);
switch mode
    case "compact_fec"
        % magic8 | packetIndex16 | packetDataCrc16 | headerCrc16
        nBits = 8 + 16 + 16 + 16;
    case "legacy_repeat"
        % magic16 | flags8 | packetIndex16 | packetDataBytes16 | packetDataCrc16 | headerCrc16
        nBits = 16 + 8 + 16 + 16 + 16 + 16;
    otherwise
        error("Unsupported phyHeaderMode: %s", string(mode));
end
end

function mode = local_phy_header_mode(frameCfg)
mode = "compact_fec";
if isfield(frameCfg, "phyHeaderMode") && strlength(string(frameCfg.phyHeaderMode)) > 0
    mode = lower(string(frameCfg.phyHeaderMode));
end
end
