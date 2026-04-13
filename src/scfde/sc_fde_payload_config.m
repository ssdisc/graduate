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
cfg.pilotPeriod = local_pn_period(cfg.pilotPolynomial, cfg.pilotInit);
cfg.pilotCycleBits = pn_generate_bits(cfg.pilotPolynomial, cfg.pilotInit, cfg.pilotPeriod);

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

function period = local_pn_period(polynomial, initState)
state0 = uint8(initState(:).' ~= 0);
if ~any(state0)
    error("p.scFde.pilotInit must not be the all-zero PN state.");
end

state = state0;
maxPeriod = 2^numel(state0) - 1;
for period = 1:maxPeriod
    state = local_pn_step(polynomial, state);
    if isequal(state, state0)
        return;
    end
end

error("SC-FDE pilot PN state did not repeat within the maximal LFSR period.");
end

function nextState = local_pn_step(polynomial, state)
coeff = uint8(polynomial(:).' ~= 0);
state = uint8(state(:).' ~= 0);
m = numel(state);
if numel(coeff) ~= m + 1
    error("PN多项式长度应为寄存器长度+1，当前为%d和%d。", numel(coeff), m);
end
if coeff(1) ~= 1 || coeff(end) ~= 1
    error("PN多项式首项和常数项必须为1。");
end

tapIdx = find(coeff(2:end-1) ~= 0);
feedback = state(end);
for t = tapIdx
    feedback = bitxor(feedback, state(t));
end
nextState = [feedback, state(1:end-1)];
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
