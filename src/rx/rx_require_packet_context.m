function rx_require_packet_context(txArtifacts, rxCfg)
%RX_REQUIRE_PACKET_CONTEXT Validate the standardized packet RX contract.

if ~(isfield(txArtifacts, "packetAssist") && isstruct(txArtifacts.packetAssist) ...
        && isfield(txArtifacts.packetAssist, "txPackets") && ~isempty(txArtifacts.packetAssist.txPackets))
    error("rx packet decode requires txArtifacts.packetAssist.txPackets.");
end

requiredFields = ["packetIndex" "runtimeCfg" "method" "ebN0dB" "jsrDb" "noisePsdLin"];
for idx = 1:numel(requiredFields)
    fieldName = requiredFields(idx);
    if ~isfield(rxCfg, char(fieldName))
        error("rxCfg.%s is required.", fieldName);
    end
end

packetIndex = round(double(rxCfg.packetIndex));
if packetIndex < 1 || packetIndex > numel(txArtifacts.packetAssist.txPackets)
    error("rxCfg.packetIndex=%d is out of range.", packetIndex);
end
end
