function fhCfg = derive_packet_fh_cfg(fhBase, pktIdx, offsetHops, currentNSym)
%DERIVE_PACKET_FH_CFG  基于绝对hop偏移派生当前包跳频配置。

if nargin < 3 || isempty(offsetHops)
    if isfield(fhBase, "packetOffsetHops") && ~isempty(fhBase.packetOffsetHops)
        offsetHops = double(fhBase.packetOffsetHops);
    else
        offsetHops = 0;
    end
end

fhCfg = fhBase;
if ~isfield(fhCfg, "enable") || ~fhCfg.enable
    return;
end

offsetHops = max(0, round(double(offsetHops)));
fhCfg.packetIndex = pktIdx;
fhCfg.packetOffsetHops = offsetHops;

seqType = lower(string(fhCfg.sequenceType));
switch seqType
    case "pn"
        if isfield(fhCfg, "pnPolynomial") && isfield(fhCfg, "pnInit") && ~isempty(fhCfg.pnInit)
            bitsPerHop = ceil(log2(max(double(fhCfg.nFreqs), 2)));
            advanceBits = offsetHops * bitsPerHop;
            fhCfg.pnInit = advance_pn_state(fhCfg.pnPolynomial, fhCfg.pnInit, advanceBits);
        end
    case {"chaos", "chaotic"}
        fhCfg.sequenceOffsetHops = offsetHops;
    otherwise
end

if nargin >= 4 && ~isempty(currentNSym)
    fhCfg.currentNSym = currentNSym;
end
end
