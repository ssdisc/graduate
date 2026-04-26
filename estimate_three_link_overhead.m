function report = estimate_three_link_overhead()
%ESTIMATE_THREE_LINK_OVERHEAD Build Tx-only artifacts and report burst cost.
%
% This is intentionally Tx-only: it verifies the true 256-long-edge source
% payload and over-the-air burst duration without running channel/Rx sweeps.

profiles = ["impulse", "narrowband", "rayleigh_multipath"];
rows = repmat(local_empty_row_local(), numel(profiles), 1);

for idx = 1:numel(profiles)
    profileName = profiles(idx);
    linkSpec = default_link_spec( ...
        "linkProfileName", profileName, ...
        "loadMlModels", strings(1, 0), ...
        "strictModelLoad", false, ...
        "requireTrainedMlModels", false);
    runtimeCfg = compile_runtime_config(linkSpec);
    txArtifacts = build_tx_artifacts(linkSpec, runtimeCfg);

    txPlan = txArtifacts.packetAssist.txPlan;
    burst = txArtifacts.commonMeta.burstReport;
    payloadMeta = txArtifacts.payloadAssist.payloadMeta;
    outerRs = txArtifacts.profileMeta.outerRs;

    rows(idx).profile = profileName;
    rows(idx).payloadBytes = double(payloadMeta.payloadBytes);
    rows(idx).imageRows = double(payloadMeta.rows);
    rows(idx).imageCols = double(payloadMeta.cols);
    rows(idx).dataPackets = double(txPlan.nDataPackets);
    rows(idx).parityPackets = double(outerRs.parityPacketCount);
    rows(idx).totalPackets = double(outerRs.totalTxPacketCount);
    rows(idx).rsK = double(outerRs.dataPacketsPerBlock);
    rows(idx).rsP = double(outerRs.parityPacketsPerBlock);
    rows(idx).packetBits = double(outerRs.packetBitsPerPacket);
    rows(idx).burstSec = double(burst.burstDurationSec);
    rows(idx).symbolRateHz = double(burst.symbolRateHz);
end

report = struct2table(rows);
disp(report);
end

function row = local_empty_row_local()
row = struct( ...
    "profile", "", ...
    "payloadBytes", NaN, ...
    "imageRows", NaN, ...
    "imageCols", NaN, ...
    "dataPackets", NaN, ...
    "parityPackets", NaN, ...
    "totalPackets", NaN, ...
    "rsK", NaN, ...
    "rsP", NaN, ...
    "packetBits", NaN, ...
    "burstSec", NaN, ...
    "symbolRateHz", NaN);
end
