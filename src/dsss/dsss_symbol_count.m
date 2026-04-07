function nChipSym = dsss_symbol_count(nBaseSym, dsssCfg)
%DSSS_SYMBOL_COUNT  Convert payload modulation symbol count to DSSS chip-symbol count.

nBaseSym = double(nBaseSym);
if ~isscalar(nBaseSym) || ~isfinite(nBaseSym) || nBaseSym < 0 || abs(nBaseSym - round(nBaseSym)) > 0
    error("nBaseSym must be a nonnegative integer scalar.");
end

spreadFactor = dsss_effective_spread_factor(dsssCfg);
nChipSym = round(nBaseSym) * spreadFactor;
end
