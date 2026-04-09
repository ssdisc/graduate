function hops = fh_hops_per_symbol(fhCfg)
%FH_HOPS_PER_SYMBOL  Return fast-FH hops per symbol.

if nargin < 1 || ~isstruct(fhCfg)
    error("fh_hops_per_symbol requires a scalar FH config struct.");
end
if fh_mode(fhCfg) ~= "fast"
    error("fh_hops_per_symbol only applies to fast FH configs.");
end
if ~(isfield(fhCfg, "hopsPerSymbol") && ~isempty(fhCfg.hopsPerSymbol))
    error("fast FH requires fh.hopsPerSymbol.");
end

hops = double(fhCfg.hopsPerSymbol);
if ~(isscalar(hops) && isfinite(hops) && abs(hops - round(hops)) < 1e-12 && hops >= 2)
    error("fh.hopsPerSymbol must be an integer scalar >= 2, got %g.", hops);
end
hops = round(hops);
end
