function [baseSym, reliabilityOut] = dsss_despread(chipSym, dsssCfg, reliabilityIn)
%DSSS_DESPREAD  Despread payload DSSS chip symbols back to modulation symbols.

arguments
    chipSym (:,1)
    dsssCfg (1,1) struct
    reliabilityIn (:,1) double = []
end

chipSym = chipSym(:);
spreadFactor = dsss_effective_spread_factor(dsssCfg);
if spreadFactor == 1
    baseSym = chipSym;
    if isempty(reliabilityIn)
        reliabilityOut = ones(numel(baseSym), 1);
    else
        reliabilityOut = reliabilityIn(:);
    end
    return;
end

if rem(numel(chipSym), spreadFactor) ~= 0
    error("DSSS chip-symbol length %d is not divisible by spreadFactor=%d.", numel(chipSym), spreadFactor);
end

chips = dsss_generate_chips(numel(chipSym), dsssCfg);
nBaseSym = numel(chipSym) / spreadFactor;
chipSymDerot = chipSym .* chips;
chipMat = reshape(chipSymDerot, spreadFactor, nBaseSym);
baseSym = mean(chipMat, 1).';

if isempty(reliabilityIn)
    reliabilityOut = ones(nBaseSym, 1);
    return;
end

reliabilityIn = double(reliabilityIn(:));
if numel(reliabilityIn) ~= numel(chipSym)
    error("DSSS reliability length %d must match chip-symbol length %d.", numel(reliabilityIn), numel(chipSym));
end
relMat = reshape(reliabilityIn, spreadFactor, nBaseSym);
reliabilityOut = mean(relMat, 1).';
end
