function bits = decode_phy_header_symbols(rSym, frameCfg, fec, softCfg)
%DECODE_PHY_HEADER_SYMBOLS  Recover uncoded PHY-header bits from BPSK symbols.
%
% compact_fec uses repeat combining plus terminated Viterbi decoding with a
% slightly finer soft metric than the payload path by default.

rSym = rSym(:);
mode = local_phy_header_mode(frameCfg);
repeat = local_phy_header_repeat(frameCfg, mode);
switch mode
    case "compact_fec"
        pilotSym = phy_header_pilot_symbols(frameCfg);
        pilotLen = numel(pilotSym);
        if numel(rSym) <= pilotLen
            bits = uint8([]);
            return;
        end
        rSymComp = local_compact_pilot_compensate(rSym, pilotSym);
        rBody = rSymComp(pilotLen + 1:end);
        rBody = local_compact_header_dsss_despread(rBody, frameCfg);
        rUse = local_repeat_combine(rBody, repeat);
        bpskMod = struct("type", "BPSK");
        fecHdr = local_compact_fec_cfg(frameCfg, fec);
        soft = demodulate_to_softbits(rUse, bpskMod, fecHdr, softCfg);
        bits = fec_decode(soft, fecHdr);
    case "legacy_repeat"
        if repeat <= 1
            bits = uint8(real(rSym) < 0);
        else
            nGroups = floor(numel(rSym) / repeat);
            if nGroups <= 0
                bits = uint8([]);
                return;
            end
            votes = reshape(real(rSym(1:nGroups * repeat)) < 0, repeat, nGroups);
            bits = uint8(sum(votes, 1) >= ceil(repeat / 2)).';
        end
    otherwise
        error("Unsupported phyHeaderMode: %s", string(mode));
end

bits = fit_bits_length(bits, phy_header_length_bits(frameCfg));
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

function fecHdr = local_compact_fec_cfg(frameCfg, fec)
fecHdr = fec;
fecHdr.kind = "conv";
fecHdr.opmode = 'term';
fecHdr.tracebackDepth = max(double(fec.tracebackDepth), 5 * local_conv_memory_bits(fec.trellis));
fecHdr.softBits = max(double(fec.softBits), local_compact_soft_bits(frameCfg));
end

function nSoft = local_compact_soft_bits(frameCfg)
nSoft = 5;
if isfield(frameCfg, "phyHeaderSoftBits") && ~isempty(frameCfg.phyHeaderSoftBits)
    nSoft = round(double(frameCfg.phyHeaderSoftBits));
end
nSoft = min(max(nSoft, 1), 13);
end

function rBody = local_compact_header_dsss_despread(rBody, frameCfg)
dsssCfg = phy_header_dsss_cfg(frameCfg);
if ~dsssCfg.enable
    rBody = rBody(:);
    return;
end
[rBody, ~] = dsss_despread(rBody(:), dsssCfg);
end

function y = local_repeat_combine(x, repeat)
if repeat <= 1
    y = x(:);
    return;
end
nGroups = floor(numel(x) / repeat);
if nGroups <= 0
    y = complex(zeros(0, 1));
    return;
end
if local_phy_header_repeat_interleaved()
    x = reshape(x(1:nGroups * repeat), nGroups, repeat);
    y = sum(x, 2);
else
    y = sum(x, 1).';
end
end

function tf = local_phy_header_repeat_interleaved()
tf = true;
end

function memoryBits = local_conv_memory_bits(trellis)
memoryBits = max(0, round(log2(trellis.numStates)));
end

function y = local_compact_pilot_compensate(x, pilotSym)
x = x(:);
pilotSym = pilotSym(:);
pilotLen = min(numel(x), numel(pilotSym));
if pilotLen <= 0
    y = x;
    return;
end

nPilot = (1:pilotLen).';
z = x(1:pilotLen) .* conj(pilotSym(1:pilotLen));
good = isfinite(z) & abs(z) > 1e-9;
if nnz(good) >= 2
    coef = polyfit(nPilot(good), unwrap(angle(z(good))), 1);
    wHat = coef(1);
    phiHat = coef(2);
elseif nnz(good) == 1
    wHat = 0;
    phiHat = angle(z(good));
else
    y = x;
    return;
end

nAll = (1:numel(x)).';
y = x .* exp(-1j * (wHat * nAll + phiHat));
hHat = mean(y(1:pilotLen) .* conj(pilotSym(1:pilotLen)));
if abs(hHat) > 1e-12
    y = y / hHat;
end
end
