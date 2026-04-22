function copies = session_header_body_diversity_copies(frameCfg)
%SESSION_HEADER_BODY_DIVERSITY_COPIES  Number of full session-header body copies to transmit.

copies = 1;
if ~(isstruct(frameCfg) && isfield(frameCfg, "sessionHeaderBodyDiversity") ...
        && isstruct(frameCfg.sessionHeaderBodyDiversity))
    return;
end

cfg = frameCfg.sessionHeaderBodyDiversity;
if ~(isfield(cfg, "enable") && logical(cfg.enable))
    return;
end
if ~(isfield(cfg, "copies") && ~isempty(cfg.copies))
    error("frame.sessionHeaderBodyDiversity.copies is required when diversity is enabled.");
end

copies = round(double(cfg.copies));
if ~(isscalar(copies) && isfinite(copies) && copies >= 1)
    error("frame.sessionHeaderBodyDiversity.copies must be a positive integer scalar.");
end
end
