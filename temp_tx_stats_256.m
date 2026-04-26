addpath(genpath('src'));
profiles = {"impulse", "narrowband", "rayleigh_multipath"};
for k = 1:numel(profiles)
    p = default_params('strictModelLoad', false, 'requireTrainedMlModels', false, 'loadMlModels', strings(1,0), 'linkProfileName', profiles{k});
    p.commonTx.source.maxDimension = 256;
    runtimeCfg = compile_runtime_config(p);
    tx = build_tx_artifacts(p, runtimeCfg);
    nPkt = numel(tx.packetAssist.txPackets);
    nBytes = double(tx.payloadAssist.payloadMeta.payloadBytes);
    burst = double(tx.commonMeta.burstReport.burstDurationSec);
    fprintf('profile=%s payloadBytes=%d packets=%d burst=%.3f\n', profiles{k}, nBytes, nPkt, burst);
end
