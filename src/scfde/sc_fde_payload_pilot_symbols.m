function pilot = sc_fde_payload_pilot_symbols(cfg, pktIdx, hopIdx)
%SC_FDE_PAYLOAD_PILOT_SYMBOLS  Known BPSK pilot sequence for one hop.

if ~(isstruct(cfg) && isfield(cfg, "enable") && logical(cfg.enable))
    error("SC-FDE pilot symbols require cfg.enable=true.");
end
if ~(isfield(cfg, "pilotLength") && ~isempty(cfg.pilotLength))
    error("SC-FDE cfg.pilotLength is required.");
end
pilotLength = round(double(cfg.pilotLength));
if ~(isscalar(pilotLength) && isfinite(pilotLength) && pilotLength >= 1)
    error("SC-FDE cfg.pilotLength must be a positive integer scalar.");
end
if ~(isfield(cfg, "pilotPolynomial") && ~isempty(cfg.pilotPolynomial) ...
        && isfield(cfg, "pilotInit") && ~isempty(cfg.pilotInit))
    error("SC-FDE pilot PN polynomial/init are required.");
end
if ~(isfield(cfg, "pilotPeriod") && ~isempty(cfg.pilotPeriod) ...
        && isfield(cfg, "pilotCycleBits") && ~isempty(cfg.pilotCycleBits))
    error("SC-FDE pilot cfg.pilotPeriod/cfg.pilotCycleBits are required.");
end

pktIdx = max(1, round(double(pktIdx)));
hopIdx = max(1, round(double(hopIdx)));
period = round(double(cfg.pilotPeriod));
if ~(isscalar(period) && isfinite(period) && period >= 1)
    error("SC-FDE cfg.pilotPeriod must be a positive integer scalar.");
end
cycleBits = uint8(cfg.pilotCycleBits(:) ~= 0);
if numel(cycleBits) ~= period
    error("SC-FDE cfg.pilotCycleBits length %d does not match pilotPeriod %d.", numel(cycleBits), period);
end

skip = mod((pktIdx - 1) * 4099 + (hopIdx - 1) * pilotLength, period);
idx = mod(skip + (0:pilotLength-1), period) + 1;
bits = cycleBits(idx);
pilot = complex(1 - 2 * double(bits(:)), 0);
end
