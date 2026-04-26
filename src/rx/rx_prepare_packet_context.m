function ctx = rx_prepare_packet_context(profileName, rxSamples, txArtifacts, rxCfg)
%RX_PREPARE_PACKET_CONTEXT Build the packet-level RX context shared by all profiles.

arguments
    profileName (1,1) string
    rxSamples
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

rx_require_packet_context(txArtifacts, rxCfg);

runtimeCfg = rxCfg.runtimeCfg;
pkt = txArtifacts.packetAssist.txPackets(rxCfg.packetIndex);
waveform = resolve_waveform_cfg(runtimeCfg);
method = string(rxCfg.method);
[sampleAction, symbolAction] = rx_split_receiver_actions(profileName, method);

ctx = struct();
ctx.profileName = string(profileName);
ctx.rxCapture = rxSamples;
ctx.txArtifacts = txArtifacts;
ctx.rxCfg = rxCfg;
ctx.runtimeCfg = runtimeCfg;
ctx.waveform = waveform;
ctx.method = method;
ctx.sampleAction = sampleAction;
ctx.symbolAction = symbolAction;
ctx.pkt = pkt;
ctx.expectedLen = numel(pkt.txSymPkt);
ctx.syncCfg = rx_prepare_capture_sync_cfg(runtimeCfg.rxSync, runtimeCfg.channel);
ctx.fhCaptureCfg = rx_packet_sample_fh_capture_cfg(pkt, waveform);
end
