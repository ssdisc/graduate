function copies = phy_header_diversity_copies(frameCfg)
%PHY_HEADER_DIVERSITY_COPIES  Number of full PHY-header copies to transmit.

copies = 1;
if ~(isstruct(frameCfg) && isfield(frameCfg, "phyHeaderDiversity") ...
        && isstruct(frameCfg.phyHeaderDiversity))
    return;
end

cfg = frameCfg.phyHeaderDiversity;
if ~(isfield(cfg, "enable") && logical(cfg.enable))
    return;
end
if ~(isfield(cfg, "copies") && ~isempty(cfg.copies))
    error("frame.phyHeaderDiversity.copies is required when diversity is enabled.");
end
copies = round(double(cfg.copies));
if ~(isscalar(copies) && isfinite(copies) && copies >= 1)
    error("frame.phyHeaderDiversity.copies must be a positive integer scalar.");
end
end
