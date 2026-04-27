function rxResult = decode_profile_packet(profileName, rxSamples, txArtifacts, rxCfg)
%DECODE_PROFILE_PACKET Thin dispatcher for the explicit profile receivers.

arguments
    profileName (1,1) string
    rxSamples (:,1) double
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

switch string(profileName)
    case "impulse"
        rxResult = run_impulse_rx(rxSamples, txArtifacts, rxCfg);
    case "narrowband"
        rxResult = run_narrowband_rx(rxSamples, txArtifacts, rxCfg);
    case "rayleigh_multipath"
        rxResult = run_rayleigh_multipath_rx(rxSamples, txArtifacts, rxCfg);
    case "robust_unified"
        rxResult = run_robust_unified_rx(rxSamples, txArtifacts, rxCfg);
    otherwise
        error("Unsupported profileName: %s", char(profileName));
end
end
