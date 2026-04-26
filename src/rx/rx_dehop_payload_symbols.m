function dataSymOut = rx_dehop_payload_symbols(dataSymIn, pkt)
%RX_DEHOP_PAYLOAD_SYMBOLS Remove slow-FH payload hopping in symbol domain.

arguments
    dataSymIn (:,1)
    pkt (1,1) struct
end

dataSymOut = dataSymIn(:);
if ~(isfield(pkt, "fhCfg") && isstruct(pkt.fhCfg) && isfield(pkt.fhCfg, "enable") && logical(pkt.fhCfg.enable))
    return;
end
if isfield(pkt.fhCfg, "nFreqs") && isfinite(double(pkt.fhCfg.nFreqs)) && double(pkt.fhCfg.nFreqs) <= 1
    return;
end
if ~(isfield(pkt, "hopInfo") && isstruct(pkt.hopInfo) && isfield(pkt.hopInfo, "enable") && logical(pkt.hopInfo.enable))
    error("Payload FH dehop requires pkt.hopInfo.enable=true.");
end
if isfield(pkt.hopInfo, "mode") && lower(string(pkt.hopInfo.mode)) == "fast"
    error("rx_dehop_payload_symbols only supports slow FH payload dehop.");
end

dataSymOut = fh_demodulate(dataSymOut, pkt.hopInfo);
end
