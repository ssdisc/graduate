function mode = fh_mode(fhCfg)
%FH_MODE  Resolve FH operating mode.

if nargin < 1 || ~isstruct(fhCfg)
    error("fh_mode requires a scalar FH config struct.");
end

mode = "slow";
if isfield(fhCfg, "mode") && strlength(string(fhCfg.mode)) > 0
    mode = lower(string(fhCfg.mode));
elseif isfield(fhCfg, "hopsPerSymbol") && ~isempty(fhCfg.hopsPerSymbol) ...
        && isfinite(double(fhCfg.hopsPerSymbol)) && double(fhCfg.hopsPerSymbol) > 1
    mode = "fast";
end

if ~(isscalar(mode) && any(mode == ["slow" "fast"]))
    error("fh.mode must be 'slow' or 'fast', got %s.", string(mode));
end
end
