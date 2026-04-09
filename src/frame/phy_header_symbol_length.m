function nSym = phy_header_symbol_length(frameCfg, fec)
%PHY_HEADER_SYMBOL_LENGTH  Return the symbol count occupied by the PHY header.

mode = local_phy_header_mode(frameCfg);
switch mode
    case "compact_fec"
        repeat = local_phy_header_repeat(frameCfg, mode);
        spreadFactor = local_phy_header_spread_factor(frameCfg);
        nSym = numel(phy_header_pilot_symbols(frameCfg)) + ...
            local_coded_bits_length( ...
            phy_header_length_bits(frameCfg) + local_conv_termination_bits(fec.trellis), fec) * repeat * spreadFactor;
    case "legacy_repeat"
        repeat = local_phy_header_repeat(frameCfg, mode);
        nSym = phy_header_length_bits(frameCfg) * repeat;
    otherwise
        error("Unsupported phyHeaderMode: %s", string(mode));
end
end

function nBits = local_coded_bits_length(nInfoBits, fec)
numInputBits = log2(fec.trellis.numInputSymbols);
numOutputBits = log2(fec.trellis.numOutputSymbols);
nBits = round(double(nInfoBits) * numOutputBits / numInputBits);
end

function mode = local_phy_header_mode(frameCfg)
mode = "compact_fec";
if isfield(frameCfg, "phyHeaderMode") && strlength(string(frameCfg.phyHeaderMode)) > 0
    mode = lower(string(frameCfg.phyHeaderMode));
end
end

function repeat = local_phy_header_repeat(frameCfg, mode)
if nargin < 2
    mode = local_phy_header_mode(frameCfg);
end
switch mode
    case "compact_fec"
        repeat = 2;
        if isfield(frameCfg, "phyHeaderRepeatCompact") && ~isempty(frameCfg.phyHeaderRepeatCompact)
            repeat = max(1, round(double(frameCfg.phyHeaderRepeatCompact)));
        elseif isfield(frameCfg, "phyHeaderRepeat") && ~isempty(frameCfg.phyHeaderRepeat)
            repeat = max(1, round(double(frameCfg.phyHeaderRepeat)));
        end
    otherwise
        repeat = 3;
        if isfield(frameCfg, "phyHeaderRepeat") && ~isempty(frameCfg.phyHeaderRepeat)
            repeat = max(1, round(double(frameCfg.phyHeaderRepeat)));
        end
end
end

function spreadFactor = local_phy_header_spread_factor(frameCfg)
dsssCfg = phy_header_dsss_cfg(frameCfg);
spreadFactor = dsss_effective_spread_factor(dsssCfg);
end

function nTail = local_conv_termination_bits(trellis)
numInputBits = max(1, round(log2(trellis.numInputSymbols)));
memoryBits = max(0, round(log2(trellis.numStates)));
tailSymbols = ceil(double(memoryBits) / double(numInputBits));
nTail = tailSymbols * numInputBits;
end
