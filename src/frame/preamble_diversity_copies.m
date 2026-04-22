function copies = preamble_diversity_copies(frameCfg)
%PREAMBLE_DIVERSITY_COPIES  Number of long-preamble copies to transmit.

copies = 1;
if ~(isstruct(frameCfg) && isfield(frameCfg, "preambleDiversity") ...
        && isstruct(frameCfg.preambleDiversity))
    return;
end

cfg = frameCfg.preambleDiversity;
if ~(isfield(cfg, "enable") && logical(cfg.enable))
    return;
end
if ~(isfield(cfg, "copies") && ~isempty(cfg.copies))
    error("frame.preambleDiversity.copies is required when diversity is enabled.");
end
copies = round(double(cfg.copies));
if ~(isscalar(copies) && isfinite(copies) && copies >= 1)
    error("frame.preambleDiversity.copies must be a positive integer scalar.");
end
end
