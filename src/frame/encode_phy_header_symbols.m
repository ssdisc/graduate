function sym = encode_phy_header_symbols(bits, frameCfg, fec)
%ENCODE_PHY_HEADER_SYMBOLS  Map PHY-header bits to BPSK symbols.
%
% compact_fec uses a terminated convolutional code dedicated to the PHY
% header, so the short header block is not decoded using payload-style
% truncation semantics.

bits = uint8(bits(:) ~= 0);
mode = local_phy_header_mode(frameCfg);
repeat = local_phy_header_repeat(frameCfg, mode);
switch mode
    case "compact_fec"
        pilotSym = phy_header_pilot_symbols(frameCfg);
        coded = local_compact_fec_encode(bits, fec);
        bodySym = 1 - 2 * double(local_repeat_interleave(coded(:), repeat));
        bodySym = local_compact_header_dsss_spread(bodySym, frameCfg);
        singleSym = [pilotSym(:); bodySym(:)];
        sym = repmat(singleSym(:), phy_header_diversity_copies(frameCfg), 1);
        sym = sym(:);
    case "legacy_repeat"
        sym = 1 - 2 * double(repelem(bits, repeat));
        sym = repmat(sym(:), phy_header_diversity_copies(frameCfg), 1);
        sym = sym(:);
    otherwise
        error("Unsupported phyHeaderMode: %s", string(mode));
end
end

function out = local_repeat_interleave(bits, repeat)
bits = uint8(bits(:) ~= 0);
repeat = max(1, round(double(repeat)));
if repeat <= 1
    out = bits;
    return;
end
out = repmat(bits, repeat, 1);
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

function coded = local_compact_fec_encode(bits, fec)
bits = uint8(bits(:) ~= 0);
tailBits = local_conv_termination_bits(fec.trellis);
bitsTerm = [bits; zeros(tailBits, 1, "uint8")];
coded = convenc(bitsTerm, fec.trellis);
end

function bodySym = local_compact_header_dsss_spread(bodySym, frameCfg)
dsssCfg = phy_header_dsss_cfg(frameCfg);
if ~dsssCfg.enable
    bodySym = bodySym(:);
    return;
end
[bodySym, ~] = dsss_spread(bodySym(:), dsssCfg);
end

function nTail = local_conv_termination_bits(trellis)
numInputBits = max(1, round(log2(trellis.numInputSymbols)));
memoryBits = max(0, round(log2(trellis.numStates)));
tailSymbols = ceil(double(memoryBits) / double(numInputBits));
nTail = tailSymbols * numInputBits;
end
