function fhCfg = session_header_body_diversity_cfg(frameCfg, fhBase, waveform, channelCfg, copyLen)
%SESSION_HEADER_BODY_DIVERSITY_CFG  Return the dedicated session-header body FH diversity config.

if nargin < 2 || ~isstruct(fhBase)
    fhBase = struct();
end
if nargin < 3
    waveform = struct();
end
if nargin < 4
    channelCfg = struct();
end

fhCfg = struct('enable', false);
copies = session_header_body_diversity_copies(frameCfg);
if copies <= 1
    return;
end

copyLen = round(double(copyLen));
if ~(isscalar(copyLen) && isfinite(copyLen) && copyLen >= 1)
    error("Session-header body diversity requires a positive integer copy length.");
end
if ~(isfield(fhBase, "enable") && logical(fhBase.enable))
    error("frame.sessionHeaderBodyDiversity requires fh.enable=true.");
end
if ~(isfield(fhBase, "freqSet") && ~isempty(fhBase.freqSet))
    error("frame.sessionHeaderBodyDiversity requires a non-empty fh.freqSet.");
end

divCfg = frameCfg.sessionHeaderBodyDiversity;
if isfield(divCfg, "freqSet") && ~isempty(divCfg.freqSet)
    manualFreqSet = double(divCfg.freqSet(:).');
    if numel(manualFreqSet) < copies
        error("frame.sessionHeaderBodyDiversity.freqSet has %d entries, need %d copies.", ...
            numel(manualFreqSet), copies);
    end
    freqSet = manualFreqSet(1:copies);
else
    freqSet = select_spread_header_freq_set(double(fhBase.freqSet(:).'), copies, waveform, channelCfg);
end

fhCfg = fhBase;
fhCfg.enable = true;
fhCfg.mode = 'slow';
fhCfg.sequenceType = 'linear';
fhCfg.symbolsPerHop = copyLen;
fhCfg.freqSet = freqSet;
fhCfg.nFreqs = numel(freqSet);
end
