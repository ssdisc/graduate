function cfg = sc_fde_payload_config(p)
%SC_FDE_PAYLOAD_CONFIG  Resolve payload SC-FDE block configuration.

if ~(isfield(p, "scFde") && isstruct(p.scFde))
    error("p.scFde is required.");
end
raw = p.scFde;
if ~(isfield(raw, "enable") && ~isempty(raw.enable))
    error("p.scFde.enable is required.");
end

cfg = struct();
cfg.enable = logical(raw.enable);
if ~isscalar(cfg.enable)
    error("p.scFde.enable must be a logical scalar.");
end
if ~cfg.enable
    return;
end

if ~(isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "enable") && logical(p.fh.enable))
    error("SC-FDE payload framing requires enabled slow FH.");
end
if fh_is_fast(p.fh)
    error("SC-FDE payload framing currently requires slow FH, not fast FH.");
end
if ~(isfield(p.fh, "symbolsPerHop") && ~isempty(p.fh.symbolsPerHop))
    error("SC-FDE payload framing requires p.fh.symbolsPerHop.");
end

cfg.hopLen = local_positive_integer(p.fh.symbolsPerHop, "p.fh.symbolsPerHop");
cfg.cpLen = local_nonnegative_integer_field(raw, "cpLenSymbols", "p.scFde.cpLenSymbols");
cfg.pilotLength = local_positive_integer_field(raw, "pilotLength", "p.scFde.pilotLength");
cfg.lambdaFactor = local_nonnegative_scalar_field(raw, "lambdaFactor", "p.scFde.lambdaFactor");
cfg.pilotMinAbsGain = local_positive_scalar_field(raw, "pilotMinAbsGain", "p.scFde.pilotMinAbsGain");
cfg.pilotMseReference = local_positive_scalar_field(raw, "pilotMseReference", "p.scFde.pilotMseReference");
cfg.fdePilotMseThreshold = local_positive_scalar_field(raw, "fdePilotMseThreshold", "p.scFde.fdePilotMseThreshold");
cfg.fdePilotMseMargin = local_positive_scalar_field(raw, "fdePilotMseMargin", "p.scFde.fdePilotMseMargin");
cfg.minReliability = local_bounded_scalar_field(raw, "minReliability", "p.scFde.minReliability", 0, 1);
cfg.pilotPolynomial = local_required_vector_field(raw, "pilotPolynomial", "p.scFde.pilotPolynomial");
cfg.pilotInit = local_required_vector_field(raw, "pilotInit", "p.scFde.pilotInit");

if cfg.cpLen >= cfg.hopLen
    error("p.scFde.cpLenSymbols=%d must be smaller than p.fh.symbolsPerHop=%d.", cfg.cpLen, cfg.hopLen);
end
cfg.coreLen = cfg.hopLen - cfg.cpLen;
if cfg.pilotLength >= cfg.coreLen
    error("p.scFde.pilotLength=%d must be smaller than SC-FDE core length %d.", cfg.pilotLength, cfg.coreLen);
end
cfg.dataSymbolsPerHop = cfg.coreLen - cfg.pilotLength;
if cfg.dataSymbolsPerHop < 1
    error("SC-FDE dataSymbolsPerHop must be positive.");
end

pn_generate_bits(cfg.pilotPolynomial, cfg.pilotInit, 1);
end

function value = local_positive_integer_field(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s is required.", ownerName);
end
value = local_positive_integer(s.(fieldName), ownerName);
end

function value = local_positive_integer(raw, ownerName)
value = double(raw);
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 1)
    error("%s must be a positive integer scalar.", ownerName);
end
value = round(value);
end

function value = local_nonnegative_integer_field(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s is required.", ownerName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 0)
    error("%s must be a nonnegative integer scalar.", ownerName);
end
value = round(value);
end

function value = local_nonnegative_scalar_field(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s is required.", ownerName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("%s must be a finite nonnegative scalar.", ownerName);
end
end

function value = local_positive_scalar_field(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s is required.", ownerName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && value > 0)
    error("%s must be a finite positive scalar.", ownerName);
end
end

function value = local_bounded_scalar_field(s, fieldName, ownerName, lo, hi)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s is required.", ownerName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= lo && value <= hi)
    error("%s must be a finite scalar in [%g, %g].", ownerName, lo, hi);
end
end

function value = local_required_vector_field(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s is required.", ownerName);
end
value = uint8(s.(fieldName)(:) ~= 0).';
if isempty(value)
    error("%s must be a non-empty binary vector.", ownerName);
end
end
