function rxResult = run_robust_unified_rx(rxSamples, txArtifacts, rxCfg)
%RUN_ROBUST_UNIFIED_RX Dedicated unified mixed-interference receiver entry.
%
% The robust unified link currently reuses the branch-level SC-FDE/MRC core
% from the Rayleigh receiver, but is dispatched through its own entry so the
% profile can evolve independently.

arguments
    rxSamples
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

rxResult = run_rayleigh_multipath_rx(rxSamples, txArtifacts, rxCfg);
end
