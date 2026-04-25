function rxResult = run_impulse_rx(rxSamples, txArtifacts, rxCfg)
%RUN_IMPULSE_RX Dedicated impulse receiver entry contract.

arguments
    rxSamples (:,1) double
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

rxResult = decode_profile_packet("impulse", rxSamples, txArtifacts, rxCfg);
end
