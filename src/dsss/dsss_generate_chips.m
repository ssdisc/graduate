function chips = dsss_generate_chips(nChipSym, dsssCfg)
%DSSS_GENERATE_CHIPS  Generate DSSS chip sequence for payload symbols.

arguments
    nChipSym (1,1) double {mustBeNonnegative, mustBeInteger}
    dsssCfg (1,1) struct
end

spreadFactor = dsss_effective_spread_factor(dsssCfg);
if spreadFactor == 1 || nChipSym == 0
    chips = ones(round(double(nChipSym)), 1);
    return;
end

if ~isfield(dsssCfg, "sequenceType")
    error("dsss.sequenceType is required when DSSS is enabled.");
end

sequenceType = lower(string(dsssCfg.sequenceType));
switch sequenceType
    case "pn"
        if ~isfield(dsssCfg, "pnPolynomial") || ~isfield(dsssCfg, "pnInit")
            error("dsss.sequenceType='pn' requires dsss.pnPolynomial and dsss.pnInit.");
        end
        [chipBits, ~] = pn_generate_bits(dsssCfg.pnPolynomial, dsssCfg.pnInit, round(double(nChipSym)));
        chips = 1 - 2 * double(chipBits(:));
    otherwise
        error("Unsupported dsss.sequenceType: %s", string(dsssCfg.sequenceType));
end
end
