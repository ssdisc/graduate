function dsssCfg = derive_packet_dsss_cfg(dsssBase, pktIdx, offsetChips, currentNBaseSym)
%DERIVE_PACKET_DSSS_CFG  Derive a per-packet DSSS configuration with absolute chip offset.

arguments
    dsssBase (1,1) struct
    pktIdx (1,1) double {mustBePositive, mustBeInteger}
    offsetChips (1,1) double {mustBeNonnegative, mustBeInteger} = 0
    currentNBaseSym (1,1) double {mustBeNonnegative, mustBeInteger} = 0
end

dsssCfg = dsssBase;
if ~isfield(dsssCfg, "enable")
    error("dsss.enable is required.");
end

spreadFactor = dsss_effective_spread_factor(dsssCfg);
dsssCfg.spreadFactor = spreadFactor;
dsssCfg.packetIndex = round(double(pktIdx));
dsssCfg.packetOffsetChips = round(double(offsetChips));
dsssCfg.currentNBaseSym = round(double(currentNBaseSym));

if spreadFactor == 1
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
        dsssCfg.pnInit = advance_pn_state(dsssCfg.pnPolynomial, dsssCfg.pnInit, dsssCfg.packetOffsetChips);
    otherwise
        error("Unsupported dsss.sequenceType: %s", string(dsssCfg.sequenceType));
end
end
