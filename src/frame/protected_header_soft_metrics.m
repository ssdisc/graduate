function [soft, info] = protected_header_soft_metrics(rSym, reliability, frameCfg, fec, softCfg)
%PROTECTED_HEADER_SOFT_METRICS Build soft metrics for one protected-header observation.

rSym = rSym(:);
if ~isempty(reliability)
    reliability = double(reliability(:));
end

mode = local_phy_header_mode(frameCfg);
info = struct( ...
    "mode", mode, ...
    "fecCfg", struct(), ...
    "softBits", NaN, ...
    "metricMax", NaN, ...
    "metricMid", NaN, ...
    "pilotMse", NaN, ...
    "pilotReliability", 1, ...
    "symbolReliability", ones(0, 1));
soft = uint8([]);

switch mode
    case "compact_fec"
        pilotSym = phy_header_pilot_symbols(frameCfg);
        pilotLen = numel(pilotSym);
        info.fecCfg = local_compact_fec_cfg(frameCfg, fec);
        info.softBits = double(info.fecCfg.softBits);
        info.metricMax = 2 ^ double(info.softBits) - 1;
        info.metricMid = double(info.metricMax) / 2;
        if numel(rSym) <= pilotLen
            return;
        end

        rSymComp = local_compact_pilot_compensate(rSym, pilotSym);
        [info.pilotMse, info.pilotReliability] = local_pilot_quality_local(rSymComp, pilotSym);

        bodyRel = local_body_reliability_local(reliability, pilotLen, numel(rSymComp));
        rBody = rSymComp(pilotLen + 1:end);
        dsssCfg = phy_header_dsss_cfg(frameCfg);
        if isempty(bodyRel)
            [rBody, relBody] = dsss_despread(rBody, dsssCfg);
        else
            [rBody, relBody] = dsss_despread(rBody, dsssCfg, bodyRel);
        end

        repeat = local_phy_header_repeat(frameCfg, mode);
        rUse = local_repeat_combine_local(rBody, repeat);
        relUse = local_repeat_combine_reliability_local(relBody, repeat);
        info.symbolReliability = relUse;

        bpskMod = struct("type", "BPSK");
        soft = demodulate_to_softbits(rUse, bpskMod, info.fecCfg, softCfg, relUse);

    case "legacy_repeat"
        repeat = local_phy_header_repeat(frameCfg, mode);
        rUse = local_repeat_combine_local(rSym, repeat);
        relUse = local_repeat_combine_reliability_local(reliability, repeat);
        fecSoft = fec;
        fecSoft.decisionType = "soft";
        fecSoft.softBits = min(max(round(double(fec_payload_soft_bits(fecSoft))), 1), 13);
        info.fecCfg = fecSoft;
        info.softBits = double(fecSoft.softBits);
        info.metricMax = 2 ^ double(info.softBits) - 1;
        info.metricMid = double(info.metricMax) / 2;
        info.symbolReliability = relUse;

        bpskMod = struct("type", "BPSK");
        soft = demodulate_to_softbits(rUse, bpskMod, fecSoft, softCfg, relUse);

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
fecHdr.decisionType = "soft";
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

function bodyRel = local_body_reliability_local(reliability, pilotLen, totalLen)
bodyRel = [];
if isempty(reliability)
    return;
end
reliability = double(reliability(:));
if numel(reliability) ~= totalLen
    error("Protected-header reliability length %d must match observation length %d.", numel(reliability), totalLen);
end
if numel(reliability) <= pilotLen
    bodyRel = zeros(0, 1);
    return;
end
bodyRel = reliability(pilotLen + 1:end);
end

function y = local_repeat_combine_local(x, repeat)
if repeat <= 1
    y = x(:);
    return;
end
groupCount = floor(numel(x) / repeat);
if groupCount <= 0
    y = complex(zeros(0, 1));
    return;
end
x = reshape(x(1:groupCount * repeat), repeat, groupCount);
y = sum(x, 1).';
end

function y = local_repeat_combine_reliability_local(x, repeat)
if isempty(x)
    y = [];
    return;
end
if repeat <= 1
    y = double(x(:));
    return;
end
groupCount = floor(numel(x) / repeat);
if groupCount <= 0
    y = zeros(0, 1);
    return;
end
x = reshape(double(x(1:groupCount * repeat)), repeat, groupCount);
y = mean(x, 1).';
end

function [pilotMse, pilotReliability] = local_pilot_quality_local(rSymComp, pilotSym)
pilotLen = min(numel(rSymComp), numel(pilotSym));
if pilotLen <= 0
    pilotMse = NaN;
    pilotReliability = 1;
    return;
end
pilotErr = rSymComp(1:pilotLen) - pilotSym(1:pilotLen);
pilotMse = mean(abs(pilotErr) .^ 2);
if ~(isfinite(pilotMse) && pilotMse >= 0)
    pilotMse = NaN;
    pilotReliability = 1;
    return;
end
pilotReliability = 1 / (1 + pilotMse);
pilotReliability = max(min(double(pilotReliability), 1), 0);
end
