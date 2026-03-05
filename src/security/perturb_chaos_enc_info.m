function infoOut = perturb_chaos_enc_info(infoIn, pktIdx)
% Eve错钥场景：对每包混沌初值施加轻微扰动。
infoOut = infoIn;
if ~isfield(infoOut, "chaosParams") || ~isstruct(infoOut.chaosParams)
    infoOut.chaosParams = struct();
end
delta = 7e-10 * (double(pktIdx) + 1);
if isfield(infoOut.chaosParams, "x0") && ~isempty(infoOut.chaosParams.x0)
    infoOut.chaosParams.x0 = wrap_unit_interval(double(infoOut.chaosParams.x0) + delta);
end
if isfield(infoOut.chaosParams, "y0") && ~isempty(infoOut.chaosParams.y0)
    infoOut.chaosParams.y0 = wrap_unit_interval(double(infoOut.chaosParams.y0) + 2 * delta);
end
end

