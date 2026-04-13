function fhCfg = phy_header_fh_cfg(frameCfg, fhBase, fec)
%PHY_HEADER_FH_CFG  Return the known FH config used by the PHY header.

if nargin < 2 || ~isstruct(fhBase)
    fhBase = struct();
end
if nargin < 3
    fec = struct();
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
if isfield(frameCfg, "phyHeaderFhMode") && strlength(string(frameCfg.phyHeaderFhMode)) > 0
    fhCfg.mode = char(lower(string(frameCfg.phyHeaderFhMode)));
end
if fh_is_fast(fhCfg)
    if phy_header_diversity_copies(frameCfg) > 1
        error("frame.phyHeaderDiversity requires slow PHY-header FH, not fast FH.");
    end
    if isfield(frameCfg, "phyHeaderFhHopsPerSymbol") && ~isempty(frameCfg.phyHeaderFhHopsPerSymbol)
        fhCfg.hopsPerSymbol = round(double(frameCfg.phyHeaderFhHopsPerSymbol));
    end
else
    if isfield(frameCfg, "phyHeaderFhSymbolsPerHop") && ~isempty(frameCfg.phyHeaderFhSymbolsPerHop)
        fhCfg.symbolsPerHop = round(double(frameCfg.phyHeaderFhSymbolsPerHop));
    end
    if ~(isscalar(fhCfg.symbolsPerHop) && isfinite(fhCfg.symbolsPerHop) && fhCfg.symbolsPerHop >= 1)
        error("frame.phyHeaderFhSymbolsPerHop must be a positive integer scalar.");
    end
    fhCfg.symbolsPerHop = max(1, round(double(fhCfg.symbolsPerHop)));
end

fhCfg.sequenceType = 'linear';
if isfield(frameCfg, "phyHeaderFhSequenceType") && ~isempty(frameCfg.phyHeaderFhSequenceType)
    fhCfg.sequenceType = char(lower(string(frameCfg.phyHeaderFhSequenceType)));
end
if isfield(frameCfg, "phyHeaderFhFreqSet") && ~isempty(frameCfg.phyHeaderFhFreqSet)
    fhCfg.freqSet = double(frameCfg.phyHeaderFhFreqSet(:).');
    fhCfg.nFreqs = numel(fhCfg.freqSet);
end

copies = phy_header_diversity_copies(frameCfg);
if copies > 1
    if ~isfield(fhCfg, "freqSet") || numel(fhCfg.freqSet) < copies
        error("frame.phyHeaderDiversity requires at least %d PHY-header FH frequencies.", copies);
    end
    if ~isfield(fec, "trellis") || isempty(fec.trellis)
        error("frame.phyHeaderDiversity requires fec.trellis when PHY-header FH is enabled.");
    end
    fhCfg.mode = 'slow';
    fhCfg.sequenceType = 'linear';
    fhCfg.freqSet = local_spread_copy_freq_set(fhCfg.freqSet, copies);
    fhCfg.nFreqs = numel(fhCfg.freqSet);
    fhCfg.symbolsPerHop = phy_header_single_symbol_length(frameCfg, fec);
end
end

function freqSet = local_spread_copy_freq_set(freqSetIn, copies)
freqSetIn = double(freqSetIn(:).');
idx = round(linspace(1, numel(freqSetIn), copies));
idx = max(1, min(numel(freqSetIn), idx));
if numel(unique(idx, "stable")) ~= copies
    error("Could not choose %d distinct PHY-header diversity frequencies.", copies);
end
freqSet = freqSetIn(idx);
end
