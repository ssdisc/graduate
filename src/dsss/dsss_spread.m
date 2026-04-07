function [chipSym, info] = dsss_spread(baseSym, dsssCfg)
%DSSS_SPREAD  Spread payload modulation symbols into DSSS chip symbols.

arguments
    baseSym (:,1)
    dsssCfg (1,1) struct
end

baseSym = baseSym(:);
spreadFactor = dsss_effective_spread_factor(dsssCfg);
info = struct( ...
    "enable", spreadFactor > 1, ...
    "spreadFactor", spreadFactor, ...
    "nBaseSym", numel(baseSym), ...
    "nChipSym", numel(baseSym) * spreadFactor);

if spreadFactor == 1
    chipSym = baseSym;
    return;
end

nChipSym = numel(baseSym) * spreadFactor;
chips = dsss_generate_chips(nChipSym, dsssCfg);
chipSym = repelem(baseSym, spreadFactor) .* chips;
end
