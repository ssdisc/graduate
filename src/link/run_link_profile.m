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
sessionByMethod = nan(nMethods, nPoints);
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
    frameSession = nan(nMethods, nFrames);
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
        sessionCtxByMethod = cell(nMethods, 1);
        rxCursorByMethod = repmat(local_initial_packet_cursor_local(txArtifacts), nMethods, 1);
        for methodIdx = 1:nMethods
            rxPayloadByMethod{methodIdx} = repmat({uint8([])}, numel(txPackets), 1);
            rawPacketOkByMethod{methodIdx} = false(numel(txPackets), 1);
            frontPacketOkByMethod{methodIdx} = false(numel(txPackets), 1);
            headerPacketOkByMethod{methodIdx} = false(numel(txPackets), 1);
            sessionCtxByMethod{methodIdx} = rx_build_session_context(struct(), session_transport_mode(runtimeCfg.frame), "none");
        end

        txBurst = txScale * txArtifacts.burstForChannel(:);
        [rxBurst, chState] = local_capture_frame_waveform_local(txBurst, noisePsdLin, pointChannel, runtimeCfg.rxDiversity);
        captureGuardSamples = local_capture_guard_samples_local(runtimeCfg, waveform);
        totalRxSamples = rx_capture_total_samples(rxBurst);

        for methodIdx = 1:nMethods
            sessionCfg = struct( ...
                "runtimeCfg", runtimeCfg, ...
                "method", methods(methodIdx), ...
                "ebN0dB", double(budget.bob.ebN0dB(pointIdx)), ...
                "jsrDb", double(budget.bob.jsrDb(pointIdx)), ...
                "noisePsdLin", noisePsdLin, ...
                "channelState", chState);
            sessionResult = rx_decode_session_control(profileName, rxBurst, txArtifacts, sessionCfg);
            sessionCtxByMethod{methodIdx} = sessionResult.sessionCtx;
            frameSession(methodIdx, frameIdx) = double(~sessionResult.required || sessionResult.ok);
            rxCursorByMethod(methodIdx) = max(double(rxCursorByMethod(methodIdx)), double(sessionResult.nextPacketCursor));
        end

        for pktIdx = 1:numel(txPackets)
            txPacket = txPackets(pktIdx);
            pktLenSamples = numel(txPacket.txSymForChannel);
            for methodIdx = 1:nMethods
                rxCursor = max(1, round(double(rxCursorByMethod(methodIdx))));
                rxStop = min(totalRxSamples, rxCursor + pktLenSamples + captureGuardSamples - 1);
                rxWindow = rx_slice_capture_window(rxBurst, rxCursor, rxStop);
                rxCfg = struct( ...
                    "packetIndex", pktIdx, ...
                    "runtimeCfg", runtimeCfg, ...
                    "method", methods(methodIdx), ...
                    "ebN0dB", double(budget.bob.ebN0dB(pointIdx)), ...
                    "jsrDb", double(budget.bob.jsrDb(pointIdx)), ...
                    "noisePsdLin", noisePsdLin, ...
                    "channelState", chState, ...
                    "sessionCtx", sessionCtxByMethod{methodIdx}, ...
                    "windowStartSample", double(rxCursor));
                rxPacket = local_run_profile_packet_rx_local(profileName, rxWindow, txArtifacts, rxCfg);
                rxPayloadByMethod{methodIdx}{pktIdx} = rxPacket.payloadBits;
                rawPacketOkByMethod{methodIdx}(pktIdx) = logical(rxPacket.rawPacketOk);
                frontPacketOkByMethod{methodIdx}(pktIdx) = logical(rxPacket.frontEndOk);
                headerPacketOkByMethod{methodIdx}(pktIdx) = logical(rxPacket.headerOk);
                if isfield(rxPacket, "sessionCtx") && isstruct(rxPacket.sessionCtx) ...
                        && isfield(rxPacket.sessionCtx, "known") && logical(rxPacket.sessionCtx.known)
                    sessionCtxByMethod{methodIdx} = rxPacket.sessionCtx;
                end
                rxCursorByMethod(methodIdx) = local_advance_packet_cursor_local( ...
                    rxCursor, pktLenSamples, rxPacket, totalRxSamples);
            end
        end

        for methodIdx = 1:nMethods
            [payloadBitsOut, ~, rsInfo] = outer_rs_recover_payload( ...
                rxPayloadByMethod{methodIdx}, ...
                rawPacketOkByMethod{methodIdx}, ...
                txPackets, ...
                numel(txArtifacts.payloadAssist.payloadBitsPlain), ...
                double(runtimeCfg.packet.payloadBitsPerPacket), ...
                runtimeCfg.outerRs);

            payloadBitsOut = fit_bits_length(payloadBitsOut, numel(txArtifacts.payloadAssist.payloadBitsPlain));
            payloadBitsOut = local_apply_payload_security_postprocess_local( ...
                payloadBitsOut, txArtifacts, runtimeCfg, "known", 0);
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
    sessionByMethod(:, pointIdx) = local_mean_omit_nan_local(frameSession, 2);
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
    "backend", "continuous_burst_v2", ...
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
    "sessionSuccessRate", max(sessionByMethod, [], 1), ...
    "frontEndSuccessRateByMethod", frontEndByMethod, ...
    "headerSuccessRateByMethod", headerByMethod, ...
    "sessionSuccessRateByMethod", sessionByMethod, ...
    "rawPayloadSuccessRate", rawPayloadSuccess, ...
    "payloadSuccessRate", payloadSuccess);
results.imageMetrics = local_finalize_image_metrics_local(metricAcc);
results.sourceImages = struct( ...
    "original", txArtifacts.commonMeta.sourceImageOriginal, ...
    "resized", txArtifacts.commonMeta.sourceImage);
results.kl = local_build_kl_report_local(budget, txArtifacts);
results.spectrum = local_build_spectrum_report_local(runtimeCfg, txArtifacts);
results.example = local_build_example_outputs_local(results, payloadLast, txArtifacts, runtimeCfg);
results.rxResults = struct();
results.rxResults.bob = local_build_standardized_rx_results_local(results, payloadLast);
results.commonDiagnostics = struct( ...
    "orchestrator", "run_link_profile", ...
    "backend", "continuous_burst_v2", ...
    "burstDurationSec", double(burstReport.burstDurationSec));
results.profileDiagnostics = struct( ...
    "profileName", profileName, ...
    "txMapper", string(linkSpec.linkProfile.txMapper), ...
    "rxChain", string(linkSpec.linkProfile.rxChain), ...
    "runtimeBackend", "continuous_burst_v2");
results = local_apply_extension_layer_local(results, linkSpec, runtimeCfg, txArtifacts, budget, waveform, profileName, methods);
results.summary = make_summary(results);

if isfield(runtimeCfg.sim, "saveFigures") && logical(runtimeCfg.sim.saveFigures) ...
        && isfield(runtimeCfg.sim, "resultsDir") && strlength(string(runtimeCfg.sim.resultsDir)) > 0
    if ~exist(char(runtimeCfg.sim.resultsDir), "dir")
        mkdir(char(runtimeCfg.sim.resultsDir));
    end
    save_figures(runtimeCfg.sim.resultsDir, results);
end
end

function [rxBurst, chState] = local_capture_frame_waveform_local(txBurst, noisePsdLin, pointChannel, rxDiversityCfg)
cfg = rx_validate_diversity_cfg(rxDiversityCfg, "runtimeCfg.rxDiversity");
if cfg.enable
    channelBank = freeze_rx_diversity_channel_bank(pointChannel, cfg);
    [rxBurst, chState] = capture_rx_diversity_waveforms(txBurst, noisePsdLin, channelBank, cfg);
else
    [rxBurst, ~, chState] = channel_bg_impulsive(txBurst, noisePsdLin, pointChannel);
    chState.rxDiversity = cfg;
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
    case "robust_unified"
        rxPacket = run_robust_unified_rx(rxSamples, txArtifacts, rxCfg);
    otherwise
        error("Unsupported profileName: %s", char(profileName));
end
end

function tf = local_profile_has_jsr_axis_local(profileName, channelCfg)
switch string(profileName)
    case "impulse"
        tf = local_impulse_power_budget_active_local(channelCfg);
    case "narrowband"
        tf = isfield(channelCfg, "narrowband") && isstruct(channelCfg.narrowband) ...
            && isfield(channelCfg.narrowband, "enable") && logical(channelCfg.narrowband.enable) ...
            && isfield(channelCfg.narrowband, "weight") && double(channelCfg.narrowband.weight) > 0;
    case "robust_unified"
        tf = local_impulse_power_budget_active_local(channelCfg) ...
            || (isfield(channelCfg, "narrowband") && isstruct(channelCfg.narrowband) ...
            && isfield(channelCfg.narrowband, "enable") && logical(channelCfg.narrowband.enable) ...
            && isfield(channelCfg.narrowband, "weight") && double(channelCfg.narrowband.weight) > 0);
    otherwise
        tf = false;
end
end

function pointChannel = local_build_point_channel_local(runtimeCfg, budget, pointIdx, waveform)
pointChannel = adapt_channel_for_sps(runtimeCfg.channel, waveform, runtimeCfg.fh);
jsrLin = 10^(double(budget.bob.jsrDb(pointIdx)) / 10);
txPowerLin = double(budget.bob.txPowerLin(pointIdx));
noisePsdLin = double(budget.bob.noisePsdLin(pointIdx));
jsrShare = local_interference_jsr_share_local(runtimeCfg);
if local_impulse_power_budget_active_local(runtimeCfg.channel)
    impulseProbSample = local_required_impulse_probability_local(pointChannel);
    targetImpulsePower = txPowerLin * jsrLin * double(jsrShare.impulse);
    pointChannel.impulseToBgRatio = targetImpulsePower / max(impulseProbSample * noisePsdLin, eps);
else
    pointChannel.impulseToBgRatio = 0;
end
if isfield(pointChannel, "singleTone") && isstruct(pointChannel.singleTone) && logical(pointChannel.singleTone.enable)
    pointChannel.singleTone.power = txPowerLin * jsrLin * double(jsrShare.singleTone);
end
if isfield(pointChannel, "narrowband") && isstruct(pointChannel.narrowband) && logical(pointChannel.narrowband.enable)
    pointChannel.narrowband.power = txPowerLin * jsrLin * double(jsrShare.narrowband);
end
if isfield(pointChannel, "sweep") && isstruct(pointChannel.sweep) && logical(pointChannel.sweep.enable)
    pointChannel.sweep.power = txPowerLin * jsrLin * double(jsrShare.sweep);
end
if double(jsrShare.multipathAttenuationDb) > 0 ...
        && isfield(pointChannel, "multipath") && isstruct(pointChannel.multipath) ...
        && isfield(pointChannel.multipath, "enable") && logical(pointChannel.multipath.enable) ...
        && isfield(pointChannel.multipath, "pathGainsDb") && numel(pointChannel.multipath.pathGainsDb) > 1
    pathGainsDb = double(pointChannel.multipath.pathGainsDb(:)).';
    pathGainsDb(2:end) = pathGainsDb(2:end) - double(jsrShare.multipathAttenuationDb);
    pointChannel.multipath.pathGainsDb = pathGainsDb;
end
end

function jsrShare = local_interference_jsr_share_local(runtimeCfg)
jsrShare = struct( ...
    "impulse", 1, ...
    "singleTone", 1, ...
    "narrowband", 1, ...
    "sweep", 1, ...
    "multipathAttenuationDb", 0);
if ~(isfield(runtimeCfg, "linkProfile") && isstruct(runtimeCfg.linkProfile) ...
        && isfield(runtimeCfg.linkProfile, "name") ...
        && string(runtimeCfg.linkProfile.name) == "robust_unified")
    return;
end

activeNames = strings(1, 0);
if local_impulse_power_budget_active_local(runtimeCfg.channel)
    activeNames(end + 1) = "impulse"; %#ok<AGROW>
end
if isfield(runtimeCfg.channel, "narrowband") && isstruct(runtimeCfg.channel.narrowband) ...
        && isfield(runtimeCfg.channel.narrowband, "enable") && logical(runtimeCfg.channel.narrowband.enable) ...
        && isfield(runtimeCfg.channel.narrowband, "weight") && double(runtimeCfg.channel.narrowband.weight) > 0
    activeNames(end + 1) = "narrowband"; %#ok<AGROW>
end
if isfield(runtimeCfg.channel, "multipath") && isstruct(runtimeCfg.channel.multipath) ...
        && isfield(runtimeCfg.channel.multipath, "enable") && logical(runtimeCfg.channel.multipath.enable)
    activeNames(end + 1) = "multipath"; %#ok<AGROW>
end

nActive = numel(activeNames);
if nActive <= 1
    return;
end
share = 1 / double(nActive);
if any(activeNames == "impulse")
    jsrShare.impulse = share;
end
if any(activeNames == "narrowband")
    jsrShare.narrowband = share;
end
if any(activeNames == "multipath")
    jsrShare.multipathAttenuationDb = 10 * log10(double(nActive));
end
end

function tf = local_impulse_power_budget_active_local(channelCfg)
tf = isfield(channelCfg, "impulseWeight") && isfinite(double(channelCfg.impulseWeight)) ...
    && double(channelCfg.impulseWeight) > 0 ...
    && isfield(channelCfg, "impulseProb") && isfinite(double(channelCfg.impulseProb)) ...
    && double(channelCfg.impulseProb) > 0;
end

function impulseProbSample = local_required_impulse_probability_local(channelCfg)
if ~(isfield(channelCfg, "impulseProb") && isfinite(double(channelCfg.impulseProb)))
    error("Impulse JSR power calibration requires a finite sample-domain channel.impulseProb.");
end
impulseProbSample = double(channelCfg.impulseProb);
if ~(isscalar(impulseProbSample) && impulseProbSample > 0 && impulseProbSample <= 1)
    error("Impulse JSR power calibration requires sample-domain channel.impulseProb in (0, 1].");
end
end

function cursor = local_initial_packet_cursor_local(txArtifacts)
cursor = 1;
if isfield(txArtifacts, "profileMeta") && isstruct(txArtifacts.profileMeta) ...
        && isfield(txArtifacts.profileMeta, "sessionFramePlan") && isstruct(txArtifacts.profileMeta.sessionFramePlan) ...
        && isfield(txArtifacts.profileMeta.sessionFramePlan, "txBurstForChannel") ...
        && ~isempty(txArtifacts.profileMeta.sessionFramePlan.txBurstForChannel)
    cursor = numel(txArtifacts.profileMeta.sessionFramePlan.txBurstForChannel) + 1;
end
end

function guardSamples = local_capture_guard_samples_local(runtimeCfg, waveform)
guardSymbols = 8;
if isfield(runtimeCfg, "channel") && isstruct(runtimeCfg.channel)
    channelCfg = runtimeCfg.channel;
    if isfield(channelCfg, "maxDelaySymbols") && isfinite(double(channelCfg.maxDelaySymbols))
        guardSymbols = max(guardSymbols, ceil(double(channelCfg.maxDelaySymbols)) + 8);
    elseif isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
            && isfield(channelCfg.multipath, "enable") && logical(channelCfg.multipath.enable)
        if isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)
            guardSymbols = max(guardSymbols, ceil(max(double(channelCfg.multipath.pathDelaysSymbols(:)))) + 8);
        elseif isfield(channelCfg.multipath, "pathDelays") && ~isempty(channelCfg.multipath.pathDelays)
            guardSymbols = max(guardSymbols, ceil(max(double(channelCfg.multipath.pathDelays(:)))) + 8);
        end
    end
end

sps = 1;
if isstruct(waveform) && isfield(waveform, "enable") && logical(waveform.enable) ...
        && isfield(waveform, "sps") && isfinite(double(waveform.sps))
    sps = max(1, round(double(waveform.sps)));
end
guardSamples = max(8, guardSymbols * sps);
end

function nextCursor = local_advance_packet_cursor_local(cursor, nominalPacketLen, rxPacket, totalSamples)
nextCursor = double(cursor) + double(nominalPacketLen);
if isfield(rxPacket, "commonDiagnostics") && isstruct(rxPacket.commonDiagnostics) ...
        && isfield(rxPacket.commonDiagnostics, "capture") && isstruct(rxPacket.commonDiagnostics.capture) ...
        && isfield(rxPacket.commonDiagnostics.capture, "packetStopSample") ...
        && isfinite(double(rxPacket.commonDiagnostics.capture.packetStopSample))
    nextCursor = double(cursor) + ceil(double(rxPacket.commonDiagnostics.capture.packetStopSample));
end
if ~(isfinite(nextCursor) && nextCursor > double(cursor))
    nextCursor = double(cursor) + double(nominalPacketLen);
end
nextCursor = min(double(totalSamples) + 1, nextCursor);
end

function scan = local_build_scan_struct_local(budget)
scan = struct( ...
    "type", string(budget.scanType), ...
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

function spectrum = local_build_spectrum_report_local(~, txArtifacts)
waveform = txArtifacts.commonMeta.waveform;
try
    [psd, freqHz, bw99Hz, eta, info] = estimate_spectrum( ...
        txArtifacts.burstForChannel(:), ...
        txArtifacts.commonMeta.modInfo, ...
        waveform, ...
        struct("payloadBits", numel(txArtifacts.payloadAssist.payloadBitsPlain)));
catch
    psd = NaN;
    freqHz = NaN;
    rolloff = 0;
    if isfield(waveform, "rolloff")
        rolloff = double(waveform.rolloff);
    end
    bw99Hz = double(waveform.symbolRateHz) * (1 + rolloff);
    if ~isfinite(bw99Hz) || bw99Hz <= 0
        bw99Hz = double(waveform.sampleRateHz);
    end
    eta = numel(txArtifacts.payloadAssist.payloadBitsPlain) / max(double(txArtifacts.commonMeta.burstReport.burstDurationSec), eps) / max(bw99Hz, eps);
    info = struct();
end
spectrum = struct( ...
    "freqHz", freqHz, ...
    "psd", psd, ...
    "bw99Hz", bw99Hz, ...
    "etaBpsHz", eta, ...
    "burstBw99Hz", bw99Hz, ...
    "burstEtaBpsHz", eta, ...
    "basebandBw99Hz", bw99Hz, ...
    "basebandEtaBpsHz", eta, ...
    "info", info);
end

function kl = local_build_kl_report_local(budget, txArtifacts)
nPoints = double(budget.nPoints);
signalVsNoise = nan(1, nPoints);
noiseVsSignal = nan(1, nPoints);
symmetric = nan(1, nPoints);
baseBurst = txArtifacts.burstForChannel(:);
for pointIdx = 1:nPoints
    txBurst = double(budget.txAmplitudeScaleList(pointIdx)) * baseBurst;
    [signalVsNoise(pointIdx), noiseVsSignal(pointIdx), symmetric(pointIdx)] = ...
        signal_noise_kl(txBurst, double(budget.bob.noisePsdLin(pointIdx)), 128);
end
kl = struct( ...
    "signalVsNoise", signalVsNoise, ...
    "noiseVsSignal", noiseVsSignal, ...
    "symmetric", symmetric);
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
        "headerSuccessRate", results.packetDiagnostics.bob.headerSuccessRateByMethod(idx, :), ...
        "sessionSuccessRate", results.packetDiagnostics.bob.sessionSuccessRateByMethod(idx, :));
    rxResults(idx).profileDiagnostics = struct( ...
        "profileName", string(results.linkSpec.linkProfile.name), ...
        "receiver", string(results.linkSpec.linkProfile.rxChain), ...
        "backend", "continuous_burst_v2", ...
        "role", "bob");
end
end

function results = local_apply_extension_layer_local(results, linkSpec, runtimeCfg, txArtifacts, budget, waveform, profileName, methods)
if local_eve_extension_enabled_local(runtimeCfg)
    [eveResults, eveBudget] = local_run_eve_extension_local( ...
        linkSpec, runtimeCfg, txArtifacts, budget, waveform, profileName, methods);
    results.eve = eveResults;
    results.linkBudget.eve = eveBudget;
end

if local_warden_extension_enabled_local(runtimeCfg)
    [wardenResults, wardenBudget] = local_run_warden_extension_local( ...
        runtimeCfg, txArtifacts, budget, waveform, profileName);
    results.covert = struct("warden", wardenResults);
    results.linkBudget.warden = wardenBudget;
end
end

function tf = local_eve_extension_enabled_local(runtimeCfg)
tf = isfield(runtimeCfg, "eve") && isstruct(runtimeCfg.eve) ...
    && isfield(runtimeCfg.eve, "enable") && logical(runtimeCfg.eve.enable);
end

function tf = local_warden_extension_enabled_local(runtimeCfg)
tf = isfield(runtimeCfg, "covert") && isstruct(runtimeCfg.covert) ...
    && isfield(runtimeCfg.covert, "enable") && logical(runtimeCfg.covert.enable) ...
    && isfield(runtimeCfg.covert, "warden") && isstruct(runtimeCfg.covert.warden) ...
    && isfield(runtimeCfg.covert.warden, "enable") && logical(runtimeCfg.covert.warden.enable);
end

function [eveResults, eveBudget] = local_run_eve_extension_local(linkSpec, runtimeCfg, txArtifacts, budget, waveform, profileName, methods)
eveCfg = runtimeCfg.eve;
local_validate_eve_extension_cfg_local(eveCfg);
eveBudget = local_offset_budget_from_bob_local(budget.bob, double(eveCfg.linkGainOffsetDb));
rxDiversityCfg = eveCfg.rxDiversity;

[roleMetrics, payloadLast] = local_decode_role_metrics_local( ...
    "eve", linkSpec, runtimeCfg, txArtifacts, budget, eveBudget, waveform, profileName, methods, rxDiversityCfg, eveCfg.assumptions, 200000);

eveResults = struct();
eveResults.methods = methods;
eveResults.ebN0dB = double(eveBudget.ebN0dB(:).');
eveResults.jsrDb = double(budget.bob.jsrDb(:).');
eveResults.scan = local_build_scan_struct_local(budget);
eveResults.ber = roleMetrics.ber;
eveResults.rawPer = roleMetrics.rawPer;
eveResults.per = roleMetrics.per;
eveResults.packetDiagnostics = struct( ...
    "frontEndSuccessRate", max(roleMetrics.frontEndByMethod, [], 1), ...
    "headerSuccessRate", max(roleMetrics.headerByMethod, [], 1), ...
    "sessionSuccessRate", max(roleMetrics.sessionByMethod, [], 1), ...
    "frontEndSuccessRateByMethod", roleMetrics.frontEndByMethod, ...
    "headerSuccessRateByMethod", roleMetrics.headerByMethod, ...
    "sessionSuccessRateByMethod", roleMetrics.sessionByMethod, ...
    "rawPayloadSuccessRate", roleMetrics.rawPayloadSuccess, ...
    "payloadSuccessRate", roleMetrics.payloadSuccess);
eveResults.imageMetrics = local_finalize_image_metrics_local(roleMetrics.imageMetricAcc);
eveResults.assumptions = eveCfg.assumptions;
eveResults.receiver = struct( ...
    "rxDiversity", rxDiversityCfg, ...
    "methods", methods, ...
    "profileName", profileName);
eveResults.example = local_build_example_outputs_local( ...
    local_make_role_result_for_examples_local(eveResults, linkSpec), payloadLast, txArtifacts, runtimeCfg);
eveResults.rxResults = local_build_role_standardized_rx_results_local(eveResults, payloadLast, linkSpec, "eve");
end

function local_validate_eve_extension_cfg_local(eveCfg)
required = ["linkGainOffsetDb" "assumptions" "rxDiversity"];
for idx = 1:numel(required)
    if ~isfield(eveCfg, required(idx))
        error("extensions.eve.%s is required when Eve is enabled.", required(idx));
    end
end
if ~(isscalar(double(eveCfg.linkGainOffsetDb)) && isfinite(double(eveCfg.linkGainOffsetDb)))
    error("extensions.eve.linkGainOffsetDb must be a finite scalar.");
end
assumptions = eveCfg.assumptions;
requiredAssumptions = ["protocol" "fh" "scramble" "chaos" "chaosApproxDelta"];
for idx = 1:numel(requiredAssumptions)
    if ~isfield(assumptions, requiredAssumptions(idx))
        error("extensions.eve.assumptions.%s is required.", requiredAssumptions(idx));
    end
end
if string(assumptions.protocol) ~= "protocol_aware"
    error("Only extensions.eve.assumptions.protocol='protocol_aware' is implemented in the refactored extension layer.");
end
if string(assumptions.fh) ~= "known" || string(assumptions.scramble) ~= "known"
    error("The refactored Eve extension currently supports only known FH and scramble assumptions.");
end
chaosAssumption = string(assumptions.chaos);
if ~any(chaosAssumption == ["known" "wrong_key" "approximate"])
    error("extensions.eve.assumptions.chaos must be one of: known, wrong_key, approximate.");
end
if chaosAssumption == "approximate"
    approxDelta = double(assumptions.chaosApproxDelta);
    if ~(isscalar(approxDelta) && isfinite(approxDelta) && approxDelta > 0)
        error("extensions.eve.assumptions.chaosApproxDelta must be a positive finite scalar when chaos='approximate'.");
    end
end
rx_validate_diversity_cfg(eveCfg.rxDiversity, "extensions.eve.rxDiversity");
end

function [roleMetrics, payloadLast] = local_decode_role_metrics_local( ...
    roleName, ~, runtimeCfg, txArtifacts, budget, roleBudget, waveform, profileName, methods, rxDiversityCfg, roleAssumptions, seedOffset)
txPackets = txArtifacts.packetAssist.txPackets;
nMethods = numel(methods);
nPoints = budget.nPoints;
nFrames = max(1, round(double(runtimeCfg.sim.nFramesPerPoint)));

roleMetrics = struct();
roleMetrics.ber = nan(nMethods, nPoints);
roleMetrics.rawPer = nan(nMethods, nPoints);
roleMetrics.per = nan(nMethods, nPoints);
roleMetrics.frontEndByMethod = nan(nMethods, nPoints);
roleMetrics.headerByMethod = nan(nMethods, nPoints);
roleMetrics.sessionByMethod = nan(nMethods, nPoints);
roleMetrics.rawPayloadSuccess = nan(nMethods, nPoints);
roleMetrics.payloadSuccess = nan(nMethods, nPoints);
roleMetrics.imageMetricAcc = local_init_image_metric_acc_local(nMethods, nPoints);
payloadLast = cell(nMethods, nPoints);

for pointIdx = 1:nPoints
    frameBer = nan(nMethods, nFrames);
    frameRawSuccess = nan(nMethods, nFrames);
    framePayloadSuccess = nan(nMethods, nFrames);
    frameFrontEnd = nan(nMethods, nFrames);
    frameHeader = nan(nMethods, nFrames);
    frameSession = nan(nMethods, nFrames);
    frameMetrics = local_init_image_metric_acc_local(nMethods, nFrames);

    pointChannel = local_build_point_channel_local(runtimeCfg, budget, pointIdx, waveform);
    rxScale = double(roleBudget.rxAmplitudeScale(pointIdx));
    noisePsdLin = double(roleBudget.noisePsdLin(pointIdx));

    for frameIdx = 1:nFrames
        rng(double(runtimeCfg.rngSeed) + double(seedOffset) + pointIdx * 1000 + frameIdx, "twister");
        rxPayloadByMethod = cell(nMethods, 1);
        rawPacketOkByMethod = cell(nMethods, 1);
        frontPacketOkByMethod = cell(nMethods, 1);
        headerPacketOkByMethod = cell(nMethods, 1);
        sessionCtxByMethod = cell(nMethods, 1);
        rxCursorByMethod = repmat(local_initial_packet_cursor_local(txArtifacts), nMethods, 1);
        for methodIdx = 1:nMethods
            rxPayloadByMethod{methodIdx} = repmat({uint8([])}, numel(txPackets), 1);
            rawPacketOkByMethod{methodIdx} = false(numel(txPackets), 1);
            frontPacketOkByMethod{methodIdx} = false(numel(txPackets), 1);
            headerPacketOkByMethod{methodIdx} = false(numel(txPackets), 1);
            sessionCtxByMethod{methodIdx} = rx_build_session_context(struct(), session_transport_mode(runtimeCfg.frame), "none");
        end

        txBurst = rxScale * txArtifacts.burstForChannel(:);
        [rxBurst, chState] = local_capture_frame_waveform_local(txBurst, noisePsdLin, pointChannel, rxDiversityCfg);
        captureGuardSamples = local_capture_guard_samples_local(runtimeCfg, waveform);
        totalRxSamples = rx_capture_total_samples(rxBurst);

        for methodIdx = 1:nMethods
            sessionCfg = struct( ...
                "runtimeCfg", runtimeCfg, ...
                "method", methods(methodIdx), ...
                "ebN0dB", double(roleBudget.ebN0dB(pointIdx)), ...
                "jsrDb", double(budget.bob.jsrDb(pointIdx)), ...
                "noisePsdLin", noisePsdLin, ...
                "channelState", chState);
            sessionResult = rx_decode_session_control(profileName, rxBurst, txArtifacts, sessionCfg);
            sessionCtxByMethod{methodIdx} = sessionResult.sessionCtx;
            frameSession(methodIdx, frameIdx) = double(~sessionResult.required || sessionResult.ok);
            rxCursorByMethod(methodIdx) = max(double(rxCursorByMethod(methodIdx)), double(sessionResult.nextPacketCursor));
        end

        for pktIdx = 1:numel(txPackets)
            txPacket = txPackets(pktIdx);
            pktLenSamples = numel(txPacket.txSymForChannel);
            for methodIdx = 1:nMethods
                rxCursor = max(1, round(double(rxCursorByMethod(methodIdx))));
                rxStop = min(totalRxSamples, rxCursor + pktLenSamples + captureGuardSamples - 1);
                rxWindow = rx_slice_capture_window(rxBurst, rxCursor, rxStop);
                rxCfg = struct( ...
                    "packetIndex", pktIdx, ...
                    "runtimeCfg", runtimeCfg, ...
                    "method", methods(methodIdx), ...
                    "ebN0dB", double(roleBudget.ebN0dB(pointIdx)), ...
                    "jsrDb", double(budget.bob.jsrDb(pointIdx)), ...
                    "noisePsdLin", noisePsdLin, ...
                    "channelState", chState, ...
                    "sessionCtx", sessionCtxByMethod{methodIdx}, ...
                    "windowStartSample", double(rxCursor), ...
                    "receiverRole", string(roleName));
                rxPacket = local_run_profile_packet_rx_local(profileName, rxWindow, txArtifacts, rxCfg);
                rxPayloadByMethod{methodIdx}{pktIdx} = rxPacket.payloadBits;
                rawPacketOkByMethod{methodIdx}(pktIdx) = logical(rxPacket.rawPacketOk);
                frontPacketOkByMethod{methodIdx}(pktIdx) = logical(rxPacket.frontEndOk);
                headerPacketOkByMethod{methodIdx}(pktIdx) = logical(rxPacket.headerOk);
                if isfield(rxPacket, "sessionCtx") && isstruct(rxPacket.sessionCtx) ...
                        && isfield(rxPacket.sessionCtx, "known") && logical(rxPacket.sessionCtx.known)
                    sessionCtxByMethod{methodIdx} = rxPacket.sessionCtx;
                end
                rxCursorByMethod(methodIdx) = local_advance_packet_cursor_local( ...
                    rxCursor, pktLenSamples, rxPacket, totalRxSamples);
            end
        end

        for methodIdx = 1:nMethods
            [payloadBitsOut, ~, rsInfo] = outer_rs_recover_payload( ...
                rxPayloadByMethod{methodIdx}, ...
                rawPacketOkByMethod{methodIdx}, ...
                txPackets, ...
                numel(txArtifacts.payloadAssist.payloadBitsPlain), ...
                double(runtimeCfg.packet.payloadBitsPerPacket), ...
                runtimeCfg.outerRs);
            payloadBitsOut = fit_bits_length(payloadBitsOut, numel(txArtifacts.payloadAssist.payloadBitsPlain));
            payloadBitsOut = local_apply_payload_security_postprocess_local( ...
                payloadBitsOut, txArtifacts, runtimeCfg, ...
                string(roleAssumptions.chaos), double(roleAssumptions.chaosApproxDelta));
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

    roleMetrics.ber(:, pointIdx) = local_mean_omit_nan_local(frameBer, 2);
    roleMetrics.rawPayloadSuccess(:, pointIdx) = local_mean_omit_nan_local(frameRawSuccess, 2);
    roleMetrics.payloadSuccess(:, pointIdx) = local_mean_omit_nan_local(framePayloadSuccess, 2);
    roleMetrics.rawPer(:, pointIdx) = max(min(1 - roleMetrics.rawPayloadSuccess(:, pointIdx), 1), 0);
    roleMetrics.per(:, pointIdx) = max(min(1 - roleMetrics.payloadSuccess(:, pointIdx), 1), 0);
    roleMetrics.frontEndByMethod(:, pointIdx) = local_mean_omit_nan_local(frameFrontEnd, 2);
    roleMetrics.headerByMethod(:, pointIdx) = local_mean_omit_nan_local(frameHeader, 2);
    roleMetrics.sessionByMethod(:, pointIdx) = local_mean_omit_nan_local(frameSession, 2);
    roleMetrics.imageMetricAcc = local_merge_point_image_metrics_local(roleMetrics.imageMetricAcc, frameMetrics, pointIdx);
end
end

function [wardenResults, wardenBudget] = local_run_warden_extension_local(runtimeCfg, txArtifacts, budget, waveform, profileName)
wardenCfg = runtimeCfg.covert.warden;
local_validate_warden_extension_cfg_local(wardenCfg);
wardenBudget = local_offset_budget_from_bob_local(budget.bob, double(wardenCfg.linkGainOffsetDb));

nPoints = budget.nPoints;
detCells = cell(1, nPoints);
for pointIdx = 1:nPoints
    pointChannel = local_build_point_channel_local(runtimeCfg, budget, pointIdx, waveform);
    detCfg = wardenCfg;
    detCfg.referenceLink = string(wardenCfg.referenceLink);
    detCfg.fhNarrowband.nFreqs = double(runtimeCfg.fh.nFreqs);
    detCfg.cyclostationary.sps = double(waveform.sps);
    txBurst = double(wardenBudget.rxAmplitudeScale(pointIdx)) * txArtifacts.burstForChannel(:);
    delayMax = local_capture_guard_samples_local(runtimeCfg, waveform);
    rng(double(runtimeCfg.rngSeed) + 300000 + pointIdx, "twister");
    detCells{pointIdx} = warden_energy_detector( ...
        txBurst, double(wardenBudget.noisePsdLin(pointIdx)), pointChannel, delayMax, detCfg);
end

wardenResults = local_pack_warden_extension_results_local( ...
    detCells, double(budget.bob.ebN0dB(:).'), double(wardenBudget.ebN0dB(:).'), ...
    double(budget.bob.jsrDb(:).'), string(wardenCfg.referenceLink), ...
    local_build_scan_struct_local(budget), string(wardenCfg.enabledLayers), ...
    string(wardenCfg.primaryLayer), string(profileName));
end

function local_validate_warden_extension_cfg_local(wardenCfg)
required = ["enable" "pfaTarget" "nObs" "nTrials" "useParallel" "nWorkers" ...
    "referenceLink" "linkGainOffsetDb" "primaryLayer" "noiseUncertaintyDb" ...
    "extraDelaySamples" "fhNarrowband" "cyclostationary" "enabledLayers"];
for idx = 1:numel(required)
    if ~isfield(wardenCfg, required(idx))
        error("extensions.warden.warden.%s is required when Warden is enabled.", required(idx));
    end
end
if string(wardenCfg.referenceLink) ~= "independent"
    error("The refactored Warden extension currently supports referenceLink='independent'.");
end
if ~(isscalar(double(wardenCfg.linkGainOffsetDb)) && isfinite(double(wardenCfg.linkGainOffsetDb)))
    error("extensions.warden.warden.linkGainOffsetDb must be finite.");
end
allowedLayers = ["energyNp" "energyOpt" "energyOptUncertain" "energyFhNarrow" "cyclostationaryOpt"];
enabledLayers = unique(string(wardenCfg.enabledLayers(:).'), "stable");
if isempty(enabledLayers)
    error("extensions.warden.warden.enabledLayers must not be empty.");
end
if any(~ismember(enabledLayers, allowedLayers))
    error("extensions.warden.warden.enabledLayers contains unsupported layer names.");
end
if ~ismember(string(wardenCfg.primaryLayer), enabledLayers)
    error("extensions.warden.warden.primaryLayer must be included in enabledLayers.");
end
end

function budgetOut = local_offset_budget_from_bob_local(bobBudget, linkGainOffsetDb)
gainDb = double(linkGainOffsetDb);
gainLin = 10^(gainDb / 10);
budgetOut = bobBudget;
budgetOut.linkGainDb = double(bobBudget.linkGainDb) + gainDb;
budgetOut.linkGainLin = double(bobBudget.linkGainLin) * gainLin;
budgetOut.rxAmplitudeScale = double(bobBudget.rxAmplitudeScale) * sqrt(gainLin);
budgetOut.rxPowerLin = double(bobBudget.rxPowerLin) * gainLin;
budgetOut.ebN0Lin = double(bobBudget.ebN0Lin) * gainLin;
budgetOut.ebN0dB = double(bobBudget.ebN0dB) + gainDb;
budgetOut.txPowerDb = double(bobBudget.txPowerDb);
budgetOut.txPowerLin = double(bobBudget.txPowerLin);
budgetOut.noisePsdLin = double(bobBudget.noisePsdLin);
end

function w = local_pack_warden_extension_results_local(detCells, bobEbN0dBList, wardenEbN0dBList, jsrDbList, referenceLink, scan, enabledLayers, primaryLayer, profileName)
layerNames = unique(string(enabledLayers(:).'), "stable");
w = struct();
w.primaryLayer = string(primaryLayer);
w.enabledLayers = layerNames;
w.profileName = string(profileName);
w.referenceLink = string(referenceLink);
w.bobEbN0dB = double(bobEbN0dBList(:).');
w.wardenEbN0dB = double(wardenEbN0dBList(:).');
w.jsrDb = double(jsrDbList(:).');
w.scan = scan;
w.layers = struct();
for idx = 1:numel(layerNames)
    w.layers.(char(layerNames(idx))) = local_collect_warden_extension_layer_local(detCells, layerNames(idx));
end
end

function layer = local_collect_warden_extension_layer_local(detCells, layerName)
nPoints = numel(detCells);
template = ["threshold" "pfa" "pd" "pmd" "xi" "pe"];
layer = struct();
for fieldName = template
    layer.(char(fieldName)) = nan(1, nPoints);
end
for pointIdx = 1:nPoints
    det = detCells{pointIdx};
    if ~(isstruct(det) && isfield(det, "layers") && isfield(det.layers, char(layerName)))
        error("Warden detector output for point %d lacks layer %s.", pointIdx, layerName);
    end
    src = det.layers.(char(layerName));
    for fieldName = template
        if isfield(src, fieldName)
            layer.(char(fieldName))(pointIdx) = double(src.(char(fieldName)));
        end
    end
end
end

function exampleResults = local_make_role_result_for_examples_local(roleResults, linkSpec)
exampleResults = struct();
exampleResults.methods = roleResults.methods;
exampleResults.ebN0dB = roleResults.ebN0dB;
exampleResults.jsrDb = roleResults.jsrDb;
exampleResults.ber = roleResults.ber;
exampleResults.rawPer = roleResults.rawPer;
exampleResults.per = roleResults.per;
exampleResults.packetDiagnostics = struct("bob", roleResults.packetDiagnostics);
exampleResults.linkSpec = linkSpec;
end

function rxResults = local_build_role_standardized_rx_results_local(roleResults, payloadLast, linkSpec, roleName)
tmp = local_make_role_result_for_examples_local(roleResults, linkSpec);
rxResults = local_build_standardized_rx_results_local(tmp, payloadLast);
for idx = 1:numel(rxResults)
    rxResults(idx).profileDiagnostics.role = string(roleName);
end
end

function payloadBitsOut = local_apply_payload_security_postprocess_local(payloadBitsIn, txArtifacts, runtimeCfg, chaosAssumption, chaosApproxDelta)
payloadBitsOut = uint8(payloadBitsIn(:) ~= 0);
if ~(isfield(runtimeCfg, "chaosEncrypt") && isstruct(runtimeCfg.chaosEncrypt) ...
        && isfield(runtimeCfg.chaosEncrypt, "enable") && logical(runtimeCfg.chaosEncrypt.enable))
    return;
end
if ~(isfield(txArtifacts, "payloadAssist") && isstruct(txArtifacts.payloadAssist) ...
        && isfield(txArtifacts.payloadAssist, "packetIndependentBitChaos"))
    error("txArtifacts.payloadAssist.packetIndependentBitChaos is required when chaosEncrypt is enabled.");
end
if ~logical(txArtifacts.payloadAssist.packetIndependentBitChaos)
    error("Refactored payload security postprocess requires packetIndependentBitChaos=true.");
end
payloadBitsOut = decrypt_payload_packets( ...
    payloadBitsOut, local_data_packet_mask_local(txArtifacts.packetAssist.txPackets), ...
    txArtifacts.packetAssist.txPackets, string(chaosAssumption), double(chaosApproxDelta));
end

function packetMask = local_data_packet_mask_local(txPackets)
packetMask = false(numel(txPackets), 1);
for pktIdx = 1:numel(txPackets)
    packetMask(pktIdx) = isfield(txPackets(pktIdx), "isDataPacket") && logical(txPackets(pktIdx).isDataPacket);
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


