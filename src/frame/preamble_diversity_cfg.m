function fhCfg = preamble_diversity_cfg(frameCfg, fhBase, waveform, channelCfg, preambleSymbolLen)
%PREAMBLE_DIVERSITY_CFG  FH config for the long-preamble diversity path.
%
% When frame.preambleDiversity.enable is true, split the long preamble into
% `copies` identical BPSK blocks, each on a spread FH frequency picked by
% select_spread_header_freq_set. Returns an FH config with enable=false when
% diversity is off (copies <= 1).

if nargin < 2 || ~isstruct(fhBase)
    fhBase = struct();
end
if nargin < 3 || isempty(waveform)
    waveform = struct();
end
if nargin < 4 || isempty(channelCfg)
    channelCfg = struct();
end
if nargin < 5 || isempty(preambleSymbolLen)
    preambleSymbolLen = local_preamble_length(frameCfg);
end

fhCfg = fhBase;
fhCfg.enable = false;

copies = preamble_diversity_copies(frameCfg);
if copies <= 1
    return;
end
if ~(isfield(fhBase, "enable") && logical(fhBase.enable))
    error("frame.preambleDiversity requires fh.enable=true.");
end
if ~(isfield(fhBase, "freqSet") && ~isempty(fhBase.freqSet))
    error("frame.preambleDiversity requires a non-empty fh.freqSet.");
end

divCfg = frameCfg.preambleDiversity;
if isfield(divCfg, "freqSet") && ~isempty(divCfg.freqSet)
    manualFreqSet = double(divCfg.freqSet(:).');
    if numel(manualFreqSet) < copies
        error("frame.preambleDiversity.freqSet has %d entries, need %d copies.", ...
            numel(manualFreqSet), copies);
    end
    freqSet = manualFreqSet(1:copies);
else
    freqSet = select_spread_header_freq_set(double(fhBase.freqSet(:).'), copies, waveform, channelCfg);
end

preambleSymbolLen = max(1, round(double(preambleSymbolLen)));

fhCfg.enable = true;
fhCfg.mode = 'slow';
fhCfg.sequenceType = 'linear';
fhCfg.freqSet = freqSet;
fhCfg.nFreqs = numel(freqSet);
fhCfg.symbolsPerHop = preambleSymbolLen;
end

function syncLen = local_preamble_length(frameCfg)
syncLen = 127;
if isstruct(frameCfg) && isfield(frameCfg, "preambleLength") && ~isempty(frameCfg.preambleLength)
    syncLen = max(1, round(double(frameCfg.preambleLength)));
end
end
