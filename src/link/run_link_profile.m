function results = run_link_profile(linkSpec)
%RUN_LINK_PROFILE Unified orchestrator for the independent three-profile architecture.

arguments
    linkSpec (1,1) struct
end

profileName = validate_link_profile(linkSpec);
runtimeCfg = compile_runtime_config(linkSpec);
[methods, ~, ~] = resolve_profile_methods(linkSpec);
txArtifacts = build_tx_artifacts(linkSpec, runtimeCfg);
txPackets = txArtifacts.packetAssist.txPackets;
waveform = txArtifacts.commonMeta.waveform;
burstReport = txArtifacts.commonMeta.burstReport;

budget = resolve_link_budget( ...
    runtimeCfg.linkBudget, ...
    txArtifacts.commonMeta.modInfo, ...
    double(burstReport.averagePowerLin), ...
    local_profile_has_jsr_axis_local(profileName, runtimeCfg.channel));

nMethods = numel(methods);
nPoints = budget.nPoints;
nFrames = max(1, round(double(runtimeCfg.sim.nFramesPerPoint)));

ber = nan(nMethods, nPoints);
rawPer = nan(nMethods, nPoints);
per = nan(nMethods, nPoints);
frontEndByMethod = nan(nMethods, nPoints);
headerByMethod = nan(nMethods, nPoints);
rawPayloadSuccess = nan(nMethods, nPoints);
payloadSuccess = nan(nMethods, nPoints);

metricAcc = local_init_image_metric_acc_local(nMethods, nPoints);
payloadLast = cell(nMethods, nPoints);

for pointIdx = 1:nPoints
    frameBer = nan(nMethods, nFrames);
    frameRawSuccess = nan(nMethods, nFrames);
    framePayloadSuccess = nan(nMethods, nFrames);
    frameFrontEnd = nan(nMethods, nFrames);
    frameHeader = nan(nMethods, nFrames);
    frameMetrics = local_init_image_metric_acc_local(nMethods, nFrames);

    pointChannel = local_build_point_channel_local(runtimeCfg, budget, pointIdx, waveform);
    txScale = double(budget.txAmplitudeScaleList(pointIdx));
    noisePsdLin = double(budget.bob.noisePsdLin(pointIdx));

    for frameIdx = 1:nFrames
        rng(double(runtimeCfg.rngSeed) + pointIdx * 1000 + frameIdx, "twister");
        rxPayloadByMethod = cell(nMethods, 1);
        rawPacketOkByMethod = cell(nMethods, 1);
        frontPacketOkByMethod = cell(nMethods, 1);
        headerPacketOkByMethod = cell(nMethods, 1);
        for methodIdx = 1:nMethods
            rxPayloadByMethod{methodIdx} = repmat({uint8([])}, numel(txPackets), 1);
            rawPacketOkByMethod{methodIdx} = false(numel(txPackets), 1);
            frontPacketOkByMethod{methodIdx} = false(numel(txPackets), 1);
            headerPacketOkByMethod{methodIdx} = false(numel(txPackets), 1);
        end

        for pktIdx = 1:numel(txPackets)
            txPacket = txPackets(pktIdx);
            txSamples = txScale * txPacket.txSymForChannel(:);
            [rxSamples, ~, chState] = channel_bg_impulsive(txSamples, noisePsdLin, pointChannel);

            for methodIdx = 1:nMethods
                rxCfg = struct( ...
                    "packetIndex", pktIdx, ...
                    "runtimeCfg", runtimeCfg, ...
                    "method", methods(methodIdx), ...
                    "ebN0dB", double(budget.bob.ebN0dB(pointIdx)), ...
                    "jsrDb", double(budget.bob.jsrDb(pointIdx)), ...
                    "noisePsdLin", noisePsdLin, ...
                    "channelState", chState);
                rxPacket = local_run_profile_packet_rx_local(profileName, rxSamples, txArtifacts, rxCfg);
                rxPayloadByMethod{methodIdx}{pktIdx} = rxPacket.payloadBits;
                rawPacketOkByMethod{methodIdx}(pktIdx) = logical(rxPacket.rawPacketOk);
                frontPacketOkByMethod{methodIdx}(pktIdx) = logical(rxPacket.frontEndOk);
                headerPacketOkByMethod{methodIdx}(pktIdx) = logical(rxPacket.headerOk);
            end
        end

        for methodIdx = 1:nMethods
            [payloadBitsOut, dataPacketOkOut, rsInfo] = outer_rs_recover_payload( ...
                rxPayloadByMethod{methodIdx}, ...
                rawPacketOkByMethod{methodIdx}, ...
                txPackets, ...
                numel(txArtifacts.payloadAssist.payloadBitsPlain), ...
                double(runtimeCfg.packet.payloadBitsPerPacket), ...
                runtimeCfg.outerRs);

            payloadBitsOut = fit_bits_length(payloadBitsOut, numel(txArtifacts.payloadAssist.payloadBitsPlain));
            payloadLast{methodIdx, pointIdx} = payloadBitsOut;
            frameBer(methodIdx, frameIdx) = mean(double(payloadBitsOut ~= txArtifacts.payloadAssist.payloadBitsPlain));
            frameRawSuccess(methodIdx, frameIdx) = double(rsInfo.rawDataPacketSuccessRate);
            framePayloadSuccess(methodIdx, frameIdx) = double(rsInfo.effectiveDataPacketSuccessRate);
            frameFrontEnd(methodIdx, frameIdx) = mean(double(frontPacketOkByMethod{methodIdx}));
            frameHeader(methodIdx, frameIdx) = mean(double(headerPacketOkByMethod{methodIdx}));
            frameMetrics = local_store_frame_image_metrics_local(frameMetrics, methodIdx, frameIdx, ...
                payloadBitsOut, txArtifacts, runtimeCfg);
        end
    end

    ber(:, pointIdx) = local_mean_omit_nan_local(frameBer, 2);
    rawPayloadSuccess(:, pointIdx) = local_mean_omit_nan_local(frameRawSuccess, 2);
    payloadSuccess(:, pointIdx) = local_mean_omit_nan_local(framePayloadSuccess, 2);
    rawPer(:, pointIdx) = max(min(1 - rawPayloadSuccess(:, pointIdx), 1), 0);
    per(:, pointIdx) = max(min(1 - payloadSuccess(:, pointIdx), 1), 0);
    frontEndByMethod(:, pointIdx) = local_mean_omit_nan_local(frameFrontEnd, 2);
    headerByMethod(:, pointIdx) = local_mean_omit_nan_local(frameHeader, 2);
    metricAcc = local_merge_point_image_metrics_local(metricAcc, frameMetrics, pointIdx);
end

results = struct();
results.methods = methods;
results.ebN0dB = double(budget.bob.ebN0dB(:).');
results.jsrDb = double(budget.bob.jsrDb(:).');
results.ber = ber;
results.rawPer = rawPer;
results.per = per;
results.params = runtimeCfg;
results.linkSpec = linkSpec;
results.runtime = struct( ...
    "backend", "packet_sim_v1", ...
    "profileName", profileName, ...
    "txSkeleton", string(linkSpec.runtime.txSkeleton));
results.txArtifacts = txArtifacts;
results.linkBudget = budget;
results.scan = local_build_scan_struct_local(budget);
results.tx = local_build_tx_report_local(burstReport, budget);
results.packetConceal = struct("active", false);
results.packetDiagnostics = struct();
results.packetDiagnostics.bob = struct( ...
    "frontEndSuccessRate", max(frontEndByMethod, [], 1), ...
    "headerSuccessRate", max(headerByMethod, [], 1), ...
    "frontEndSuccessRateByMethod", frontEndByMethod, ...
    "headerSuccessRateByMethod", headerByMethod, ...
    "rawPayloadSuccessRate", rawPayloadSuccess, ...
    "payloadSuccessRate", payloadSuccess);
results.imageMetrics = local_finalize_image_metrics_local(metricAcc);
results.sourceImages = struct( ...
    "original", txArtifacts.commonMeta.sourceImageOriginal, ...
    "resized", txArtifacts.commonMeta.sourceImage);
results.kl = struct( ...
    "signalVsNoise", nan(1, nPoints), ...
    "noiseVsSignal", nan(1, nPoints), ...
    "symmetric", nan(1, nPoints));
results.spectrum = local_build_spectrum_report_local(runtimeCfg, txArtifacts);
results.example = local_build_example_outputs_local(results, payloadLast, txArtifacts, runtimeCfg);
results.rxResults = struct();
results.rxResults.bob = local_build_standardized_rx_results_local(results, payloadLast);
results.commonDiagnostics = struct( ...
    "orchestrator", "run_link_profile", ...
    "backend", "packet_sim_v1", ...
    "burstDurationSec", double(burstReport.burstDurationSec));
results.profileDiagnostics = struct( ...
    "profileName", profileName, ...
    "txMapper", string(linkSpec.linkProfile.txMapper), ...
    "rxChain", string(linkSpec.linkProfile.rxChain), ...
    "runtimeBackend", "packet_sim_v1");
results.summary = make_summary(results);

if isfield(runtimeCfg.sim, "saveFigures") && logical(runtimeCfg.sim.saveFigures) ...
        && isfield(runtimeCfg.sim, "resultsDir") && strlength(string(runtimeCfg.sim.resultsDir)) > 0
    if ~exist(char(runtimeCfg.sim.resultsDir), "dir")
        mkdir(char(runtimeCfg.sim.resultsDir));
    end
    save_figures(results);
end
end

function rxPacket = local_run_profile_packet_rx_local(profileName, rxSamples, txArtifacts, rxCfg)
switch profileName
    case "impulse"
        rxPacket = run_impulse_rx(rxSamples, txArtifacts, rxCfg);
    case "narrowband"
        rxPacket = run_narrowband_rx(rxSamples, txArtifacts, rxCfg);
    case "rayleigh_multipath"
        rxPacket = run_rayleigh_multipath_rx(rxSamples, txArtifacts, rxCfg);
    otherwise
        error("Unsupported profileName: %s", char(profileName));
end
end

function tf = local_profile_has_jsr_axis_local(profileName, channelCfg)
if profileName ~= "narrowband"
    tf = false;
    return;
end
tf = isfield(channelCfg, "narrowband") && isstruct(channelCfg.narrowband) && isfield(channelCfg.narrowband, "enable") ...
    && logical(channelCfg.narrowband.enable);
end

function pointChannel = local_build_point_channel_local(runtimeCfg, budget, pointIdx, waveform)
pointChannel = runtimeCfg.channel;
jsrLin = 10^(double(budget.bob.jsrDb(pointIdx)) / 10);
txPowerLin = double(budget.bob.txPowerLin(pointIdx));
if isfield(pointChannel, "singleTone") && isstruct(pointChannel.singleTone) && logical(pointChannel.singleTone.enable)
    pointChannel.singleTone.power = txPowerLin * jsrLin;
end
if isfield(pointChannel, "narrowband") && isstruct(pointChannel.narrowband) && logical(pointChannel.narrowband.enable)
    pointChannel.narrowband.power = txPowerLin * jsrLin;
end
if isfield(pointChannel, "sweep") && isstruct(pointChannel.sweep) && logical(pointChannel.sweep.enable)
    pointChannel.sweep.power = txPowerLin * jsrLin;
end
pointChannel = adapt_channel_for_sps(pointChannel, waveform, runtimeCfg.fh);
end

function scan = local_build_scan_struct_local(budget)
scan = struct( ...
    "nSnr", double(budget.nSnr), ...
    "nJsr", double(budget.nJsr), ...
    "ebN0dBList", double(budget.snrDbList(:)), ...
    "jsrDbList", double(budget.jsrDbList(:)), ...
    "ebN0dBPoint", double(budget.bob.ebN0dB(:)), ...
    "jsrDbPoint", double(budget.bob.jsrDb(:)), ...
    "snrIndex", double(budget.bob.snrIndex(:)), ...
    "jsrIndex", double(budget.bob.jsrIndex(:)));
end

function tx = local_build_tx_report_local(burstReport, budget)
scale2 = double(budget.txAmplitudeScaleList(:).') .^ 2;
tx = struct();
tx.burstDurationSec = double(burstReport.burstDurationSec);
tx.baseAveragePowerLin = double(burstReport.averagePowerLin);
tx.baseAveragePowerDb = double(burstReport.averagePowerDb);
tx.averagePowerLin = double(burstReport.averagePowerLin) * scale2;
tx.averagePowerDb = 10 * log10(max(tx.averagePowerLin, realmin('double')));
tx.peakPowerLin = double(burstReport.peakPowerLin) * scale2;
tx.peakPowerDb = 10 * log10(max(tx.peakPowerLin, realmin('double')));
tx.configuredPowerLin = double(budget.bob.txPowerLin(:).');
tx.configuredPowerDb = double(budget.bob.txPowerDb(:).');
tx.powerErrorLin = tx.averagePowerLin - tx.configuredPowerLin;
tx.powerErrorDb = tx.averagePowerDb - tx.configuredPowerDb;
end

function spectrum = local_build_spectrum_report_local(runtimeCfg, txArtifacts)
waveform = txArtifacts.commonMeta.waveform;
rolloff = 0;
if isfield(waveform, "rolloff")
    rolloff = double(waveform.rolloff);
end
bw99Hz = double(waveform.symbolRateHz) * (1 + rolloff);
if ~isfinite(bw99Hz) || bw99Hz <= 0
    bw99Hz = double(waveform.sampleRateHz);
end
eta = numel(txArtifacts.payloadAssist.payloadBitsPlain) / max(double(txArtifacts.commonMeta.burstReport.burstDurationSec), eps) / max(bw99Hz, eps);
spectrum = struct( ...
    "bw99Hz", bw99Hz, ...
    "etaBpsHz", eta, ...
    "burstBw99Hz", bw99Hz, ...
    "burstEtaBpsHz", eta, ...
    "basebandBw99Hz", bw99Hz, ...
    "basebandEtaBpsHz", eta);
end

function metricAcc = local_init_image_metric_acc_local(nMethods, nPoints)
metricAcc = struct();
metricAcc.originalCommMse = nan(nMethods, nPoints);
metricAcc.originalCommPsnr = nan(nMethods, nPoints);
metricAcc.originalCommSsim = nan(nMethods, nPoints);
metricAcc.originalCompMse = nan(nMethods, nPoints);
metricAcc.originalCompPsnr = nan(nMethods, nPoints);
metricAcc.originalCompSsim = nan(nMethods, nPoints);
metricAcc.resizedCommMse = nan(nMethods, nPoints);
metricAcc.resizedCommPsnr = nan(nMethods, nPoints);
metricAcc.resizedCommSsim = nan(nMethods, nPoints);
metricAcc.resizedCompMse = nan(nMethods, nPoints);
metricAcc.resizedCompPsnr = nan(nMethods, nPoints);
metricAcc.resizedCompSsim = nan(nMethods, nPoints);
end

function metricAcc = local_store_frame_image_metrics_local(metricAcc, methodIdx, frameIdx, payloadBitsOut, txArtifacts, runtimeCfg)
payloadMeta = txArtifacts.payloadAssist.payloadMeta;
imgTx = txArtifacts.commonMeta.sourceImage;
imgTxOriginal = txArtifacts.commonMeta.sourceImageOriginal;
imgRxResized = payload_bits_to_image(payloadBitsOut, payloadMeta, runtimeCfg.payload);
imgRxOriginal = imgRxResized;
if ~isequal(size(imgRxOriginal), size(imgTxOriginal))
    imgRxOriginal = imresize(imgRxResized, [size(imgTxOriginal, 1), size(imgTxOriginal, 2)]);
end

[psnrResizedComm, ssimResizedComm, mseResizedComm] = image_quality(imgTx, imgRxResized);
[psnrOriginalComm, ssimOriginalComm, mseOriginalComm] = image_quality(imgTxOriginal, imgRxOriginal);
metricAcc.resizedCommMse(methodIdx, frameIdx) = mseResizedComm;
metricAcc.resizedCommPsnr(methodIdx, frameIdx) = psnrResizedComm;
metricAcc.resizedCommSsim(methodIdx, frameIdx) = ssimResizedComm;
metricAcc.originalCommMse(methodIdx, frameIdx) = mseOriginalComm;
metricAcc.originalCommPsnr(methodIdx, frameIdx) = psnrOriginalComm;
metricAcc.originalCommSsim(methodIdx, frameIdx) = ssimOriginalComm;
metricAcc.resizedCompMse(methodIdx, frameIdx) = mseResizedComm;
metricAcc.resizedCompPsnr(methodIdx, frameIdx) = psnrResizedComm;
metricAcc.resizedCompSsim(methodIdx, frameIdx) = ssimResizedComm;
metricAcc.originalCompMse(methodIdx, frameIdx) = mseOriginalComm;
metricAcc.originalCompPsnr(methodIdx, frameIdx) = psnrOriginalComm;
metricAcc.originalCompSsim(methodIdx, frameIdx) = ssimOriginalComm;
end

function metricAccOut = local_merge_point_image_metrics_local(metricAccOut, frameMetrics, pointIdx)
fieldNames = string(fieldnames(metricAccOut));
for idx = 1:numel(fieldNames)
    fieldName = fieldNames(idx);
    metricAccOut.(fieldName)(:, pointIdx) = local_mean_omit_nan_local(frameMetrics.(fieldName), 2);
end
end

function imageMetrics = local_finalize_image_metrics_local(metricAcc)
imageMetrics = struct();
imageMetrics.resized = struct( ...
    "communication", struct( ...
        "mse", metricAcc.resizedCommMse, ...
        "psnr", metricAcc.resizedCommPsnr, ...
        "ssim", metricAcc.resizedCommSsim), ...
    "compensated", struct( ...
        "mse", metricAcc.resizedCompMse, ...
        "psnr", metricAcc.resizedCompPsnr, ...
        "ssim", metricAcc.resizedCompSsim));
imageMetrics.original = struct( ...
    "communication", struct( ...
        "mse", metricAcc.originalCommMse, ...
        "psnr", metricAcc.originalCommPsnr, ...
        "ssim", metricAcc.originalCommSsim), ...
    "compensated", struct( ...
        "mse", metricAcc.originalCompMse, ...
        "psnr", metricAcc.originalCompPsnr, ...
        "ssim", metricAcc.originalCompSsim));
end

function out = local_mean_omit_nan_local(x, dim)
if nargin < 2
    dim = 1;
end
valid = isfinite(x);
count = sum(valid, dim);
xUse = x;
xUse(~valid) = 0;
sumVal = sum(xUse, dim);
out = sumVal ./ max(count, 1);
out(count == 0) = NaN;
end

function rxResults = local_build_standardized_rx_results_local(results, payloadLast)
methods = string(results.methods(:).');
nMethods = numel(methods);
lastPoint = numel(results.ebN0dB);
rxResults = repmat(struct( ...
    "method", "", ...
    "frontEndOk", false(1, 0), ...
    "headerOk", false(1, 0), ...
    "packetOk", false(1, 0), ...
    "rawPacketOk", false(1, 0), ...
    "payloadBits", uint8([]), ...
    "metrics", struct(), ...
    "commonDiagnostics", struct(), ...
    "profileDiagnostics", struct()), nMethods, 1);
for idx = 1:nMethods
    rxResults(idx).method = methods(idx);
    rxResults(idx).frontEndOk = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(idx, :)) >= 1 - 1e-12;
    rxResults(idx).headerOk = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(idx, :)) >= 1 - 1e-12;
    rxResults(idx).packetOk = double(1 - results.per(idx, :)) >= 1 - 1e-12;
    rxResults(idx).rawPacketOk = double(1 - results.rawPer(idx, :)) >= 1 - 1e-12;
    if lastPoint >= 1 && ~isempty(payloadLast{idx, lastPoint})
        rxResults(idx).payloadBits = uint8(payloadLast{idx, lastPoint});
    else
        rxResults(idx).payloadBits = uint8([]);
    end
    rxResults(idx).metrics = struct( ...
        "ebN0dB", results.ebN0dB, ...
        "jsrDb", results.jsrDb, ...
        "ber", results.ber(idx, :), ...
        "rawPer", results.rawPer(idx, :), ...
        "per", results.per(idx, :));
    rxResults(idx).commonDiagnostics = struct( ...
        "frontEndSuccessRate", results.packetDiagnostics.bob.frontEndSuccessRateByMethod(idx, :), ...
        "headerSuccessRate", results.packetDiagnostics.bob.headerSuccessRateByMethod(idx, :));
    rxResults(idx).profileDiagnostics = struct( ...
        "profileName", string(results.linkSpec.linkProfile.name), ...
        "receiver", string(results.linkSpec.linkProfile.rxChain), ...
        "backend", "packet_sim_v1", ...
        "role", "bob");
end
end

function example = local_build_example_outputs_local(results, payloadLast, txArtifacts, runtimeCfg)
nPoints = numel(results.ebN0dB);
nMethods = numel(results.methods);
payloadMeta = txArtifacts.payloadAssist.payloadMeta;
imgTxOriginal = txArtifacts.commonMeta.sourceImageOriginal;
example = repmat(struct("methods", struct()), nPoints, 1);
for pointIdx = 1:nPoints
    methodsStruct = struct();
    for methodIdx = 1:nMethods
        payloadBits = payloadLast{methodIdx, pointIdx};
        if isempty(payloadBits)
            imgRxResized = zeros(size(txArtifacts.commonMeta.sourceImage), "uint8");
        else
            imgRxResized = payload_bits_to_image(payloadBits, payloadMeta, runtimeCfg.payload);
        end
        imgRx = imgRxResized;
        if ~isequal(size(imgRx), size(imgTxOriginal))
            imgRx = imresize(imgRxResized, [size(imgTxOriginal, 1), size(imgTxOriginal, 2)]);
        end
        methodsStruct.(char(results.methods(methodIdx))) = struct( ...
            "imgRx", imgRx, ...
            "imgRxComm", imgRx, ...
            "imgRxCompensated", imgRx, ...
            "packetSuccessRate", double(1 - results.per(methodIdx, pointIdx)), ...
            "rawPacketSuccessRate", double(1 - results.rawPer(methodIdx, pointIdx)), ...
            "headerOk", logical(results.packetDiagnostics.bob.headerSuccessRateByMethod(methodIdx, pointIdx) >= 1 - 1e-12));
    end
    example(pointIdx).methods = methodsStruct;
end
end


