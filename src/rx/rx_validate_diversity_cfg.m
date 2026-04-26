function cfg = rx_validate_diversity_cfg(cfgIn, ownerName)
%RX_VALIDATE_DIVERSITY_CFG Validate the standardized RX diversity contract.

if nargin < 2 || strlength(string(ownerName)) == 0
    ownerName = "rxDiversity";
end
if ~(isstruct(cfgIn) && isscalar(cfgIn))
    error("%s must be a scalar struct.", char(ownerName));
end

requiredFields = ["enable" "nRx" "combineMethod"];
for idx = 1:numel(requiredFields)
    fieldName = requiredFields(idx);
    if ~isfield(cfgIn, char(fieldName))
        error("%s.%s is required.", ownerName, fieldName);
    end
end

cfg = struct();
cfg.enable = logical(cfgIn.enable);
if ~isscalar(cfg.enable)
    error("%s.enable must be a logical scalar.", char(ownerName));
end

cfg.nRx = double(cfgIn.nRx);
if ~(isscalar(cfg.nRx) && isfinite(cfg.nRx) && cfg.nRx >= 1 && abs(cfg.nRx - round(cfg.nRx)) <= 1e-12)
    error("%s.nRx must be a positive integer scalar.", char(ownerName));
end
cfg.nRx = round(cfg.nRx);

cfg.combineMethod = lower(string(cfgIn.combineMethod));
if strlength(cfg.combineMethod) == 0
    error("%s.combineMethod must not be empty.", char(ownerName));
end
if cfg.enable
    if cfg.nRx ~= 2
        error("%s.enable=true currently requires nRx=2.", char(ownerName));
    end
else
    if cfg.nRx ~= 1
        error("%s.enable=false requires nRx=1.", char(ownerName));
    end
end
if cfg.combineMethod ~= "mrc"
    error("%s.combineMethod currently only supports ""mrc"".", char(ownerName));
end
end
