function plan = sc_fde_payload_plan(nInputSymbols, cfg)
%SC_FDE_PAYLOAD_PLAN  Symbol counts for CP/pilot SC-FDE payload framing.

if ~(isstruct(cfg) && isfield(cfg, "enable") && logical(cfg.enable))
    plan = struct( ...
        "enable", false, ...
        "nInputSymbols", max(0, round(double(nInputSymbols))), ...
        "nHops", 0, ...
        "nTxSymbols", max(0, round(double(nInputSymbols))));
    return;
end

nInputSymbols = round(double(nInputSymbols));
if ~(isscalar(nInputSymbols) && isfinite(nInputSymbols) && nInputSymbols >= 0)
    error("SC-FDE input symbol count must be a finite nonnegative scalar.");
end
dataSymbolsPerHop = local_required_positive_integer(cfg, "dataSymbolsPerHop");
hopLen = local_required_positive_integer(cfg, "hopLen");
cpLen = local_required_nonnegative_integer(cfg, "cpLen");
pilotLength = local_required_positive_integer(cfg, "pilotLength");
coreLen = local_required_positive_integer(cfg, "coreLen");
if coreLen ~= hopLen - cpLen || dataSymbolsPerHop ~= coreLen - pilotLength
    error("SC-FDE payload config has inconsistent hop/core/pilot lengths.");
end

nHops = 0;
if nInputSymbols > 0
    nHops = ceil(double(nInputSymbols) / double(dataSymbolsPerHop));
end

plan = struct();
plan.enable = true;
plan.nInputSymbols = nInputSymbols;
plan.nHops = nHops;
plan.nTxSymbols = nHops * hopLen;
plan.hopLen = hopLen;
plan.cpLen = cpLen;
plan.coreLen = coreLen;
plan.pilotLength = pilotLength;
plan.dataSymbolsPerHop = dataSymbolsPerHop;
end

function value = local_required_positive_integer(cfg, fieldName)
if ~(isfield(cfg, fieldName) && ~isempty(cfg.(fieldName)))
    error("SC-FDE cfg.%s is required.", fieldName);
end
value = double(cfg.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 1)
    error("SC-FDE cfg.%s must be a positive integer scalar.", fieldName);
end
value = round(value);
end

function value = local_required_nonnegative_integer(cfg, fieldName)
if ~(isfield(cfg, fieldName) && ~isempty(cfg.(fieldName)))
    error("SC-FDE cfg.%s is required.", fieldName);
end
value = double(cfg.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 0)
    error("SC-FDE cfg.%s must be a nonnegative integer scalar.", fieldName);
end
value = round(value);
end
