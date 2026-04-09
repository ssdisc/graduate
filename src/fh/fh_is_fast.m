function tf = fh_is_fast(fhCfg)
%FH_IS_FAST  True when FH config requests true fast frequency hopping.

if nargin < 1 || ~isstruct(fhCfg)
    error("fh_is_fast requires a scalar FH config struct.");
end

tf = fh_mode(fhCfg) == "fast";
end
