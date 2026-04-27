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
if string(profileName) == "robust_unified" && lower(method) == "robust_combo" ...
        && local_channel_narrowband_active_local(runtimeCfg.channel) ...
        && local_robust_sample_nbi_enabled_local(runtimeCfg.mitigation)
    sampleAction = "robust_mixed_sample";
end

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

function tf = local_channel_narrowband_active_local(channelCfg)
tf = isstruct(channelCfg) ...
    && isfield(channelCfg, "narrowband") && isstruct(channelCfg.narrowband) ...
    && isfield(channelCfg.narrowband, "enable") && logical(channelCfg.narrowband.enable) ...
    && isfield(channelCfg.narrowband, "weight") && double(channelCfg.narrowband.weight) > 0;
end

function tf = local_robust_sample_nbi_enabled_local(mitigation)
tf = isstruct(mitigation) ...
    && isfield(mitigation, "robustMixed") && isstruct(mitigation.robustMixed) ...
    && isfield(mitigation.robustMixed, "enableSampleNbiCancel") ...
    && logical(mitigation.robustMixed.enableSampleNbiCancel);
end
