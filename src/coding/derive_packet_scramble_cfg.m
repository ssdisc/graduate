function scrambleCfg = derive_packet_scramble_cfg(scrambleBase, pktIdx, offsetBits)
%DERIVE_PACKET_SCRAMBLE_CFG  基于绝对比特偏移派生当前包扰码配置。

if nargin < 3 || isempty(offsetBits)
    if isfield(scrambleBase, "packetOffsetBits") && ~isempty(scrambleBase.packetOffsetBits)
        offsetBits = double(scrambleBase.packetOffsetBits);
    else
        offsetBits = 0;
    end
end

scrambleCfg = scrambleBase;
if ~isfield(scrambleCfg, "enable") || ~scrambleCfg.enable
    return;
end
if ~isfield(scrambleCfg, "pnPolynomial") || ~isfield(scrambleCfg, "pnInit") || isempty(scrambleCfg.pnInit)
    return;
end

scrambleCfg.packetIndex = pktIdx;
scrambleCfg.packetOffsetBits = max(0, round(double(offsetBits)));
scrambleCfg.pnInit = advance_pn_state(scrambleCfg.pnPolynomial, scrambleCfg.pnInit, scrambleCfg.packetOffsetBits);
end
