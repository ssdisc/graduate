function spreadFactor = dsss_effective_spread_factor(dsssCfg)
%DSSS_EFFECTIVE_SPREAD_FACTOR  Resolve the active DSSS spread factor.

arguments
    dsssCfg (1,1) struct
end

if ~isfield(dsssCfg, "enable")
    error("dsssCfg.enable is required.");
end
if ~isfield(dsssCfg, "spreadFactor")
    error("dsssCfg.spreadFactor is required.");
end

spreadFactor = double(dsssCfg.spreadFactor);
if ~isscalar(spreadFactor) || ~isfinite(spreadFactor) || spreadFactor < 1 || abs(spreadFactor - round(spreadFactor)) > 0
    error("dsss.spreadFactor must be a positive integer scalar.");
end
spreadFactor = round(spreadFactor);

if ~logical(dsssCfg.enable)
    spreadFactor = 1;
end
end
