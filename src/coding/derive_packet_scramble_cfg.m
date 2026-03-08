function scrambleCfg = derive_packet_scramble_cfg(scrambleBase, pktIdx, strideBits)
%DERIVE_PACKET_SCRAMBLE_CFG  基于包序号直接派生每包扰码配置。

if nargin < 3 || isempty(strideBits)
    if isfield(scrambleBase, "packetStrideBits") && ~isempty(scrambleBase.packetStrideBits)
        strideBits = double(scrambleBase.packetStrideBits);
    else
        strideBits = 0;
    end
end

scrambleCfg = scrambleBase;
if ~isfield(scrambleCfg, "enable") || ~scrambleCfg.enable
    return;
end
if ~isfield(scrambleCfg, "pnPolynomial") || ~isfield(scrambleCfg, "pnInit") || isempty(scrambleCfg.pnInit)
    return;
end

advanceBits = max(0, round(double(pktIdx - 1) * double(strideBits)));
scrambleCfg.pnInit = advance_pn_state(scrambleCfg.pnPolynomial, scrambleCfg.pnInit, advanceBits);
end
