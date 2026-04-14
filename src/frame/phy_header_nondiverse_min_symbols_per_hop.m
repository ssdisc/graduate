function hopLen = phy_header_nondiverse_min_symbols_per_hop(frameCfg, fhCfg, fec)
%PHY_HEADER_NONDIVERSE_MIN_SYMBOLS_PER_HOP  Minimum slow-FH hop length for one PHY-header copy.
%
% A single compact PHY header already sees the full configured FH set once
% when the hop length is ceil(copyLen / nFreqs). Shorter hop lengths wrap
% the same header copy across the FH set repeatedly and push most symbols
% onto hop-transition transients after pulse shaping. We therefore enforce
% that single-copy PHY headers use:
%   1) at most one pass over the PHY-header FH frequency set; and
%   2) an absolute floor of 8 symbols per hop.

if nargin < 3 || ~(isstruct(fec) && isfield(fec, "trellis") && ~isempty(fec.trellis))
    error("phy_header_nondiverse_min_symbols_per_hop requires fec.trellis.");
end

copyLen = phy_header_single_symbol_length(frameCfg, fec);
if ~(isscalar(copyLen) && isfinite(copyLen) && copyLen >= 1)
    error("PHY-header single-copy length must be a positive finite scalar.");
end

freqSet = [];
if isstruct(frameCfg) && isfield(frameCfg, "phyHeaderFhFreqSet") && ~isempty(frameCfg.phyHeaderFhFreqSet)
    freqSet = double(frameCfg.phyHeaderFhFreqSet(:).');
elseif isstruct(fhCfg) && isfield(fhCfg, "freqSet") && ~isempty(fhCfg.freqSet)
    freqSet = double(fhCfg.freqSet(:).');
end

if isempty(freqSet) || any(~isfinite(freqSet))
    error("PHY-header FH minimum hop length requires a finite frequency set.");
end

nFreqs = numel(freqSet);
if nFreqs < 1
    error("PHY-header FH frequency set must contain at least one entry.");
end

hopLen = max(8, ceil(double(copyLen) / double(nFreqs)));
end
