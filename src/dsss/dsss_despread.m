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

[perm, ~] = dsss_chip_interleave_permutation(numel(chipSym), dsssCfg);
if numel(perm) ~= numel(chipSym)
    error("DSSS chip interleaver permutation length mismatch.");
end
invPerm = zeros(numel(perm), 1);
invPerm(perm) = 1:numel(perm);
chipSym = chipSym(invPerm);

chips = dsss_generate_chips(numel(chipSym), dsssCfg);
nBaseSym = numel(chipSym) / spreadFactor;
chipSymDerot = chipSym .* chips;
chipMat = reshape(chipSymDerot, spreadFactor, nBaseSym);

if isempty(reliabilityIn)
    baseSym = mean(chipMat, 1).';
    reliabilityOut = ones(nBaseSym, 1);
    return;
end

reliabilityIn = double(reliabilityIn(:));
if numel(reliabilityIn) ~= numel(chipSym)
    error("DSSS reliability length %d must match chip-symbol length %d.", numel(reliabilityIn), numel(chipSym));
end
reliabilityIn = reliabilityIn(invPerm);
relMat = reshape(reliabilityIn, spreadFactor, nBaseSym);
relMat = max(min(relMat, 1), 0);

% Reliability is a chip-level soft-erasure mask.  Use it during despreading
% instead of only after despreading; otherwise bad FH chips still pollute the
% DSSS average before the demodulator sees the erasure reliability.
weightSum = sum(relMat, 1);
baseSymRow = complex(zeros(1, nBaseSym));
valid = weightSum > eps;
if any(valid)
    baseSymRow(valid) = sum(chipMat(:, valid) .* relMat(:, valid), 1) ./ weightSum(valid);
end
baseSym = baseSymRow.';
reliabilityOut = (weightSum(:) ./ double(spreadFactor));
end
