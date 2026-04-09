function fhCfg = phy_header_fh_cfg(frameCfg, fhBase)
%PHY_HEADER_FH_CFG  Return the known FH config used by the PHY header.

if nargin < 2 || ~isstruct(fhBase)
    fhBase = struct();
end

fhCfg = fhBase;
fhCfg.enable = false;
if ~(isstruct(frameCfg) && isfield(frameCfg, "phyHeaderFhEnable") && logical(frameCfg.phyHeaderFhEnable))
    return;
end
if ~(isfield(fhBase, "enable") && logical(fhBase.enable))
    return;
end

fhCfg.enable = true;
if isfield(frameCfg, "phyHeaderFhSymbolsPerHop") && ~isempty(frameCfg.phyHeaderFhSymbolsPerHop)
    fhCfg.symbolsPerHop = round(double(frameCfg.phyHeaderFhSymbolsPerHop));
end
if ~(isscalar(fhCfg.symbolsPerHop) && isfinite(fhCfg.symbolsPerHop) && fhCfg.symbolsPerHop >= 1)
    error("frame.phyHeaderFhSymbolsPerHop must be a positive integer scalar.");
end
fhCfg.symbolsPerHop = max(1, round(double(fhCfg.symbolsPerHop)));

fhCfg.sequenceType = 'linear';
if isfield(frameCfg, "phyHeaderFhSequenceType") && ~isempty(frameCfg.phyHeaderFhSequenceType)
    fhCfg.sequenceType = char(lower(string(frameCfg.phyHeaderFhSequenceType)));
end
if isfield(frameCfg, "phyHeaderFhFreqSet") && ~isempty(frameCfg.phyHeaderFhFreqSet)
    fhCfg.freqSet = double(frameCfg.phyHeaderFhFreqSet(:).');
    fhCfg.nFreqs = numel(fhCfg.freqSet);
end
end
