function fhCfg = derive_packet_fh_cfg(fhBase, pktIdx, strideHops, currentNSym)
%DERIVE_PACKET_FH_CFG  基于包序号直接派生每包跳频配置。

if nargin < 3 || isempty(strideHops)
    if isfield(fhBase, "packetStrideHops") && ~isempty(fhBase.packetStrideHops)
        strideHops = double(fhBase.packetStrideHops);
    else
        strideHops = 0;
    end
end

fhCfg = fhBase;
if ~isfield(fhCfg, "enable") || ~fhCfg.enable
    return;
end

seqType = lower(string(fhCfg.sequenceType));
switch seqType
    case "pn"
        if isfield(fhCfg, "pnPolynomial") && isfield(fhCfg, "pnInit") && ~isempty(fhCfg.pnInit)
            bitsPerHop = ceil(log2(max(double(fhCfg.nFreqs), 2)));
            advanceBits = max(0, round(double(pktIdx - 1) * double(strideHops) * bitsPerHop));
            fhCfg.pnInit = advance_pn_state(fhCfg.pnPolynomial, fhCfg.pnInit, advanceBits);
        end
    case {"chaos", "chaotic"}
        fhCfg = perturb_chaos_fh_cfg_local(fhCfg, pktIdx);
    otherwise
end

if nargin >= 4 && ~isempty(currentNSym)
    fhCfg.currentNSym = currentNSym;
end
end

function fhCfg = perturb_chaos_fh_cfg_local(fhCfg, pktIdx)
if ~isfield(fhCfg, "chaosParams") || ~isstruct(fhCfg.chaosParams)
    fhCfg.chaosParams = struct();
end
if ~isfield(fhCfg, "chaosMethod") || strlength(string(fhCfg.chaosMethod)) == 0
    fhCfg.chaosMethod = "logistic";
end

delta = 1e-10 * (double(pktIdx) + 1);
if ~isfield(fhCfg.chaosParams, "x0") || isempty(fhCfg.chaosParams.x0)
    fhCfg.chaosParams.x0 = 0.1234567890123456;
end
fhCfg.chaosParams.x0 = wrap_unit_interval_local(double(fhCfg.chaosParams.x0) + delta);
if isfield(fhCfg.chaosParams, "y0") && ~isempty(fhCfg.chaosParams.y0)
    fhCfg.chaosParams.y0 = wrap_unit_interval_local(double(fhCfg.chaosParams.y0) + 2 * delta);
end
end

function x = wrap_unit_interval_local(x)
x = mod(x, 1.0);
if x <= 0
    x = x + eps;
elseif x >= 1
    x = 1 - eps;
end
end
