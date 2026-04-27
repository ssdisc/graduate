function [perm, mode] = dsss_chip_interleave_permutation(nChipSym, dsssCfg)
%DSSS_CHIP_INTERLEAVE_PERMUTATION  Deterministic chip-order permutation for payload DSSS.

arguments
    nChipSym (1,1) double {mustBeNonnegative, mustBeInteger}
    dsssCfg (1,1) struct
end

nChipSym = round(double(nChipSym));
spreadFactor = dsss_effective_spread_factor(dsssCfg);
mode = local_chip_interleave_mode_local(dsssCfg);
perm = (1:nChipSym).';

if nChipSym == 0 || spreadFactor <= 1 || mode == "none"
    mode = "none";
    return;
end
if rem(nChipSym, spreadFactor) ~= 0
    error("DSSS chip-interleaver requires nChipSym=%d divisible by spreadFactor=%d.", ...
        nChipSym, spreadFactor);
end

nBaseSym = nChipSym / spreadFactor;
switch mode
    case "chip_round_robin"
        idx = reshape(1:nChipSym, spreadFactor, nBaseSym);
        perm = reshape(idx.', [], 1);
    otherwise
        error("Unsupported dsss.chipInterleaveMode: %s", char(mode));
end
end

function mode = local_chip_interleave_mode_local(dsssCfg)
mode = "none";
if ~(isstruct(dsssCfg) && isfield(dsssCfg, "chipInterleaveMode") && ~isempty(dsssCfg.chipInterleaveMode))
    return;
end
mode = lower(string(dsssCfg.chipInterleaveMode));
if ~isscalar(mode) || strlength(mode) == 0
    error("dsss.chipInterleaveMode must be a non-empty scalar string.");
end
if any(mode == ["none" "chip_round_robin"])
    return;
end
error("Unsupported dsss.chipInterleaveMode: %s", char(mode));
end
