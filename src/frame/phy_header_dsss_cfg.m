function dsssCfg = phy_header_dsss_cfg(frameCfg)
%PHY_HEADER_DSSS_CFG  Return the DSSS config used by the PHY header body.

dsssCfg = struct();
dsssCfg.enable = false;
dsssCfg.spreadFactor = 1;
dsssCfg.sequenceType = 'pn';
dsssCfg.pnPolynomial = [1 0 0 0 0 0 0 0 0 1 0 1];
dsssCfg.pnInit = [0 0 0 0 0 0 0 0 0 1 1];

if nargin < 1 || ~isstruct(frameCfg)
    return;
end

if isfield(frameCfg, "phyHeaderSpreadFactor") && ~isempty(frameCfg.phyHeaderSpreadFactor)
    dsssCfg.spreadFactor = round(double(frameCfg.phyHeaderSpreadFactor));
end
if ~(isscalar(dsssCfg.spreadFactor) && isfinite(dsssCfg.spreadFactor) && dsssCfg.spreadFactor >= 1)
    error("frame.phyHeaderSpreadFactor must be a positive integer scalar.");
end
dsssCfg.spreadFactor = max(1, dsssCfg.spreadFactor);
dsssCfg.enable = dsssCfg.spreadFactor > 1;

if isfield(frameCfg, "phyHeaderSpreadSequenceType") && ~isempty(frameCfg.phyHeaderSpreadSequenceType)
    dsssCfg.sequenceType = char(lower(string(frameCfg.phyHeaderSpreadSequenceType)));
end
if isfield(frameCfg, "phyHeaderSpreadPolynomial") && ~isempty(frameCfg.phyHeaderSpreadPolynomial)
    dsssCfg.pnPolynomial = frameCfg.phyHeaderSpreadPolynomial;
end
if isfield(frameCfg, "phyHeaderSpreadInit") && ~isempty(frameCfg.phyHeaderSpreadInit)
    dsssCfg.pnInit = frameCfg.phyHeaderSpreadInit;
end
end
