function fhCaptureCfg = rx_packet_sample_fh_capture_cfg(pkt, waveform)
%RX_PACKET_SAMPLE_FH_CAPTURE_CFG Build the sample-domain FH capture contract for one packet.

fhCaptureCfg = struct("enable", false);
if ~(isstruct(waveform) && isfield(waveform, "enable") && logical(waveform.enable))
    return;
end

preambleEnabled = local_effective_fh_capture_enabled_local(pkt, "preambleFhCfg");
headerEnabled = local_effective_fh_capture_enabled_local(pkt, "phyHeaderFhCfg");
dataEnabled = local_effective_fh_capture_enabled_local(pkt, "fhCfg");
if ~(preambleEnabled || headerEnabled || dataEnabled)
    return;
end

if ~preambleEnabled
    pkt.preambleFhCfg = struct("enable", false);
end
if ~headerEnabled
    pkt.phyHeaderFhCfg = struct("enable", false);
end
if ~dataEnabled
    pkt.fhCfg = struct("enable", false);
end

fhCaptureCfg = struct( ...
    "enable", true, ...
    "syncSymbols", double(numel(pkt.syncSym)), ...
    "headerSymbols", double(pkt.nPhyHeaderSymTx), ...
    "preambleFhCfg", pkt.preambleFhCfg, ...
    "headerFhCfg", pkt.phyHeaderFhCfg, ...
    "dataFhCfg", pkt.fhCfg);
end

function tf = local_effective_fh_capture_enabled_local(pkt, fieldName)
tf = false;
fieldName = char(string(fieldName));
if ~(isstruct(pkt) && isfield(pkt, fieldName) && isstruct(pkt.(fieldName)))
    return;
end

fhCfg = pkt.(fieldName);
if ~(isfield(fhCfg, "enable") && logical(fhCfg.enable))
    return;
end

tf = true;
if isfield(fhCfg, "nFreqs") && isfinite(double(fhCfg.nFreqs)) && double(fhCfg.nFreqs) <= 1
    tf = false;
end
if isfield(fhCfg, "freqSet") && ~isempty(fhCfg.freqSet)
    freqSet = unique(double(fhCfg.freqSet(:)));
    if numel(freqSet) <= 1
        tf = false;
    end
end
end
