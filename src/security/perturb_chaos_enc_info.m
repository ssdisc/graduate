function infoOut = perturb_chaos_enc_info(infoIn, delta)
% 对混沌初值施加扰动：可用于Eve错钥/近似初值场景。
infoOut = infoIn;
if ~isfield(infoOut, "chaosParams") || ~isstruct(infoOut.chaosParams)
    infoOut.chaosParams = struct();
end
delta = double(delta);
if isfield(infoOut.chaosParams, "x0") && ~isempty(infoOut.chaosParams.x0)
    infoOut.chaosParams.x0 = wrap_unit_interval(double(infoOut.chaosParams.x0) + delta);
end
if isfield(infoOut.chaosParams, "y0") && ~isempty(infoOut.chaosParams.y0)
    infoOut.chaosParams.y0 = wrap_unit_interval(double(infoOut.chaosParams.y0) + 2 * delta);
end
end

