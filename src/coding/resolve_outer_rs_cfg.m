function cfg = resolve_outer_rs_cfg(pOrCfg)
%RESOLVE_OUTER_RS_CFG  Validate cross-packet Reed-Solomon configuration.

if isstruct(pOrCfg) && isfield(pOrCfg, "outerRs")
    cfgIn = pOrCfg.outerRs;
else
    cfgIn = pOrCfg;
end

if ~isstruct(cfgIn) || ~isscalar(cfgIn)
    error("outerRs 配置必须是标量struct。");
end

cfg = struct();
cfg.enable = local_get_logical_local(cfgIn, "enable", false);
cfg.dataPacketsPerBlock = local_get_integer_local(cfgIn, "dataPacketsPerBlock", 12);
cfg.parityPacketsPerBlock = local_get_integer_local(cfgIn, "parityPacketsPerBlock", 4);
cfg.symbolBits = 8;

if cfg.dataPacketsPerBlock < 1
    error("outerRs.dataPacketsPerBlock 必须 >= 1。");
end
if cfg.parityPacketsPerBlock < 0
    error("outerRs.parityPacketsPerBlock 必须 >= 0。");
end

if cfg.enable
    if cfg.parityPacketsPerBlock < 2
        error("outerRs.enable=true 时，outerRs.parityPacketsPerBlock 必须 >= 2。");
    end
    if cfg.dataPacketsPerBlock + cfg.parityPacketsPerBlock > 255
        error("outerRs 每个RS块的总码长不能超过255：K=%d, P=%d。", ...
            cfg.dataPacketsPerBlock, cfg.parityPacketsPerBlock);
    end
end
end

function value = local_get_logical_local(s, fieldName, defaultValue)
if isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = logical(s.(fieldName));
else
    value = logical(defaultValue);
end
end

function value = local_get_integer_local(s, fieldName, defaultValue)
if isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = double(s.(fieldName));
else
    value = double(defaultValue);
end
value = round(value);
if ~isfinite(value)
    error("outerRs.%s 必须是有限整数。", fieldName);
end
end
