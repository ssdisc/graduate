function encPkt = derive_packet_chaos_cfg(encBase, pktIdx)
% 从主混沌密钥派生每包独立参数，避免包间复用同一初值。
encPkt = encBase;
if ~isfield(encPkt, "enable")
    encPkt.enable = true;
end
if ~isfield(encPkt, "chaosMethod") || strlength(string(encPkt.chaosMethod)) == 0
    encPkt.chaosMethod = "logistic";
end
if ~isfield(encPkt, "chaosParams") || ~isstruct(encPkt.chaosParams)
    encPkt.chaosParams = struct();
end

delta = 1e-10 * (double(pktIdx) + 1);
if ~isfield(encPkt.chaosParams, "x0") || isempty(encPkt.chaosParams.x0)
    encPkt.chaosParams.x0 = 0.1234567890123456;
end
encPkt.chaosParams.x0 = wrap_unit_interval(double(encPkt.chaosParams.x0) + delta);
if isfield(encPkt.chaosParams, "y0") && ~isempty(encPkt.chaosParams.y0)
    encPkt.chaosParams.y0 = wrap_unit_interval(double(encPkt.chaosParams.y0) + 2 * delta);
end
end

