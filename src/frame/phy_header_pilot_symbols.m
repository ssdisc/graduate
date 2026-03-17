function sym = phy_header_pilot_symbols(frameCfg)
%PHY_HEADER_PILOT_SYMBOLS  Return the compact PHY-header pilot BPSK symbols.

pilotLen = 0;
if isfield(frameCfg, "phyHeaderPilotLength") && ~isempty(frameCfg.phyHeaderPilotLength)
    pilotLen = max(0, round(double(frameCfg.phyHeaderPilotLength)));
end

if pilotLen <= 0
    sym = zeros(0, 1);
    return;
end

poly = [1 0 0 1 1];
init = [0 0 0 1];
if isfield(frameCfg, "phyHeaderPilotPolynomial") && ~isempty(frameCfg.phyHeaderPilotPolynomial)
    poly = frameCfg.phyHeaderPilotPolynomial;
end
if isfield(frameCfg, "phyHeaderPilotInit") && ~isempty(frameCfg.phyHeaderPilotInit)
    init = frameCfg.phyHeaderPilotInit;
end

[bits, ~] = pn_generate_bits(poly, init, pilotLen);
sym = 1 - 2 * double(bits(:));
end
