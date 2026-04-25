function rxResult = run_rayleigh_multipath_rx(rxSamples, txArtifacts, rxCfg)
%RUN_RAYLEIGH_MULTIPATH_RX Dedicated Rayleigh multipath receiver entry contract.

arguments
    rxSamples (:,1) double
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

rxResult = decode_profile_packet("rayleigh_multipath", rxSamples, txArtifacts, rxCfg);
end
