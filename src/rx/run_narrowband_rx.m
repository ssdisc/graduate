function rxResult = run_narrowband_rx(rxSamples, txArtifacts, rxCfg)
%RUN_NARROWBAND_RX Dedicated narrowband receiver entry contract.

arguments
    rxSamples (:,1) double
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

rxResult = decode_profile_packet("narrowband", rxSamples, txArtifacts, rxCfg);
end
