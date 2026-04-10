function results = simulate(p)
%SIMULATE  端到端链路仿真，包含脉冲噪声抑制。
%
% 输入:
%   p - 仿真参数结构体（建议由default_params()生成）
%       .rngSeed, .sim, .tx, .source, .chaosEncrypt, .payload, .waveform, .linkBudget
%       .frame, .scramble, .fec, .interleaver, .mod, .fh
%       .channel, .mitigation, .softMetric, .rxSync
%       .eve（可选）, .covert（可选）
%
% 返回包含BER/MSE/PSNR/SSIM/KL/PSD结果的结构体，启用时保存图形。

arguments
    p (1,1) struct
end

rng(p.rngSeed);
set(0, 'DefaultFigureVisible', 'off');

if ~isfield(p, "rxSync"); p.rxSync = struct(); end
if ~isfield(p.rxSync, "fineSearchRadius"); p.rxSync.fineSearchRadius = 0; end
if ~isfield(p.rxSync, "compensateCarrier"); p.rxSync.compensateCarrier = false; end
if ~isfield(p.rxSync, "equalizeAmplitude"); p.rxSync.equalizeAmplitude = true; end
if ~isfield(p.rxSync, "enableFractionalTiming"); p.rxSync.enableFractionalTiming = false; end
if ~isfield(p.rxSync, "fractionalRange"); p.rxSync.fractionalRange = 0.5; end
if ~isfield(p.rxSync, "fractionalStep"); p.rxSync.fractionalStep = 0.05; end
if ~isfield(p.rxSync, "estimateCfo"); p.rxSync.estimateCfo = false; end
if ~isfield(p.rxSync, "carrierPll"); p.rxSync.carrierPll = struct(); end
if ~isfield(p.rxSync.carrierPll, "enable"); p.rxSync.carrierPll.enable = false; end
if ~isfield(p.rxSync.carrierPll, "alpha"); p.rxSync.carrierPll.alpha = 0.02; end
if ~isfield(p.rxSync.carrierPll, "beta"); p.rxSync.carrierPll.beta = 3e-4; end
if ~isfield(p.rxSync.carrierPll, "maxFreq"); p.rxSync.carrierPll.maxFreq = 0.1; end
commonRandomFramesAcrossPoints = false;
if isfield(p, "sim") && isstruct(p.sim) && isfield(p.sim, "commonRandomFramesAcrossPoints")
    commonRandomFramesAcrossPoints = logical(p.sim.commonRandomFramesAcrossPoints);
end
bobRxSync = p.rxSync;
bobMitigation = p.mitigation;
waveform = resolve_waveform_cfg(p);
local_require_presync_mitigation_cfg_local(bobMitigation, "p.mitigation");
[methods, activeInterferenceTypes, allowedMethods] = resolve_mitigation_methods(bobMitigation, p.channel);
bobMitigation.methods = methods;
p.mitigation.methods = methods;

%% 发送端（TRANSMITTER）

imgTx = load_source_image(p.source);

payloadCodec = get_payload_codec(p.payload);
usePayloadBitChaos = payloadCodec == "dct";
packetIndependentBitChaos = false;

% 混沌加密
chaosEnabled = isfield(p, 'chaosEncrypt') && isfield(p.chaosEncrypt, 'enable') && p.chaosEncrypt.enable;
imgForPayload = imgTx;
chaosEncInfo = struct('enabled', false, 'mode', "none");
if chaosEnabled && ~usePayloadBitChaos
    [imgForPayload, chaosEncInfo] = chaos_encrypt(imgTx, p.chaosEncrypt);
    chaosEncInfo.mode = "image";
end

[payloadBitsPlain, meta] = image_to_payload_bits(imgForPayload, p.payload);%将图像转换为比特流载荷，并生成元数据（尺寸等）
payloadBits = payloadBitsPlain;
if chaosEnabled && usePayloadBitChaos
    if ~isfield(p.chaosEncrypt, "packetIndependent")
        p.chaosEncrypt.packetIndependent = true;
    end
    packetIndependentBitChaos = logical(p.chaosEncrypt.packetIndependent);
    if packetIndependentBitChaos
        chaosEncInfo.enabled = true;
        chaosEncInfo.mode = "payload_bits_packet";
    else
        [payloadBits, chaosEncInfo] = chaos_encrypt_bits(payloadBitsPlain, p.chaosEncrypt);
    end
end

[~, firstSyncSym] = make_packet_sync(p.frame, 1);
[~, shortSyncSym] = make_packet_sync(p.frame, 2);

% 构建按包发送计划（每包独立同步/头部/载荷）
[txPackets, txPlan] = build_tx_packets(payloadBits, meta, p, packetIndependentBitChaos, waveform);
meta = txPlan.sessionMeta;
nTxPackets = numel(txPackets);
nDataPackets = txPlan.nDataPackets;
sessionFrames = txPlan.sessionFrames;
hasDedicatedSessionFrames = ~isempty(sessionFrames);
% 主链路译码统计仅依赖每包payload比特（避免在并行worker间广播巨大的txPackets结构体）
txPktIndex = (1:nTxPackets).';
txPayloadBits = {txPackets.payloadBitsPlain}.';
fhEnabled = txPlan.fhEnabled;
dsssEnabled = isfield(txPlan, "dsssEnable") && txPlan.dsssEnable;
packetConcealEnable = false;
packetConcealMode = "nearest";
if isfield(p, "packet") && isstruct(p.packet)
    if isfield(p.packet, "concealLostPackets")
        packetConcealEnable = logical(p.packet.concealLostPackets);
    end
    if isfield(p.packet, "concealMode") && strlength(string(p.packet.concealMode)) > 0
        packetConcealMode = lower(string(p.packet.concealMode));
    end
end
packetConcealActive = packetConcealEnable && nDataPackets > 1;

% 用于信道/频谱/监视者评估的整段突发
txSymForChannel = txPlan.txBurstForChannel;
modInfo = txPlan.modInfo;
txBaseReport = measure_tx_burst(txSymForChannel, waveform);
jsrScanEnabled = local_channel_has_enabled_jammer_local(p.channel);
linkBudget = resolve_link_budget(p.linkBudget, modInfo, txBaseReport.averagePowerLin, jsrScanEnabled);
jsrScanIsGrid = string(linkBudget.scanType) == "ebn0_jsr_grid";
powerScaleLinList = linkBudget.bob.txPowerLin ./ txBaseReport.averagePowerLin;
txReport = struct( ...
    "burstDurationSec", txBaseReport.burstDurationSec, ...
    "baseAveragePowerLin", txBaseReport.averagePowerLin, ...
    "baseAveragePowerDb", txBaseReport.averagePowerDb, ...
    "basePeakPowerLin", txBaseReport.peakPowerLin, ...
    "basePeakPowerDb", txBaseReport.peakPowerDb, ...
    "txAmplitudeScale", linkBudget.bob.rxAmplitudeScale, ...
    "configuredPowerLin", linkBudget.bob.txPowerLin, ...
    "configuredPowerDb", linkBudget.bob.txPowerDb, ...
    "averagePowerLin", txBaseReport.averagePowerLin .* powerScaleLinList, ...
    "averagePowerDb", 10 * log10(max(txBaseReport.averagePowerLin .* powerScaleLinList, realmin('double'))), ...
    "peakPowerLin", txBaseReport.peakPowerLin .* powerScaleLinList, ...
    "peakPowerDb", 10 * log10(max(txBaseReport.peakPowerLin .* powerScaleLinList, realmin('double'))), ...
    "powerErrorLin", txBaseReport.averagePowerLin .* powerScaleLinList - linkBudget.bob.txPowerLin, ...
    "powerErrorDb", 10 * log10(max(txBaseReport.averagePowerLin .* powerScaleLinList, realmin('double'))) - linkBudget.bob.txPowerDb);
if jsrScanIsGrid
    fprintf('[SIM] Tx记录: burst %.3fs, Eb/N0点=%s dB, JSR点=%s dB, base avg %.4f (1 sps等效)\n', ...
        txReport.burstDurationSec, mat2str(double(linkBudget.snrDbList)), mat2str(double(linkBudget.jsrDbList)), txBaseReport.averagePowerLin);
else
    fprintf('[SIM] Tx记录: burst %.3fs, Eb/N0点=%s dB, JSR扫描=OFF, base avg %.4f (1 sps等效)\n', ...
        txReport.burstDurationSec, mat2str(double(linkBudget.snrDbList)), txBaseReport.averagePowerLin);
end

%% 仿真参数初始化与配置

EbN0dBList = linkBudget.bob.ebN0dB(:).'; % 按点展开后的Bob接收端Eb/N0
JsrDbList = linkBudget.bob.jsrDb(:).';
pointSnrIndex = double(linkBudget.bob.snrIndex(:).');
pointJsrIndex = double(linkBudget.bob.jsrIndex(:).');

ber = nan(numel(methods), numel(EbN0dBList)); %比特错误率（BER）统计
packetFrontEndBobVals = nan(1, numel(EbN0dBList));
packetHeaderBobVals = nan(1, numel(EbN0dBList));
packetFrontEndBobMethodVals = nan(numel(methods), numel(EbN0dBList));
packetHeaderBobMethodVals = nan(numel(methods), numel(EbN0dBList));
packetSuccessBobVals = nan(numel(methods), numel(EbN0dBList));
rawPacketSuccessBobVals = nan(numel(methods), numel(EbN0dBList));
adaptiveDiagCfgGlobal = local_adaptive_frontend_catalog_local(bobMitigation);
adaptiveClassBobVals = zeros(numel(adaptiveDiagCfgGlobal.classNames), numel(methods), numel(EbN0dBList));
adaptiveActionBobVals = zeros(numel(adaptiveDiagCfgGlobal.actionNames), numel(methods), numel(EbN0dBList));
adaptivePathBobVals = zeros(numel(adaptiveDiagCfgGlobal.bootstrapPaths), numel(methods), numel(EbN0dBList));
adaptiveMeanConfidenceBobVals = nan(numel(methods), numel(EbN0dBList));
mseCommVals = nan(numel(methods), numel(EbN0dBList)); % 纯通信重建图像的MSE
psnrCommVals = nan(numel(methods), numel(EbN0dBList)); % 纯通信重建图像的PSNR
ssimCommVals = nan(numel(methods), numel(EbN0dBList)); % 纯通信重建图像的SSIM
mseCompVals = nan(numel(methods), numel(EbN0dBList)); % 丢包补偿/修复后的MSE
psnrCompVals = nan(numel(methods), numel(EbN0dBList)); % 丢包补偿/修复后的PSNR
ssimCompVals = nan(numel(methods), numel(EbN0dBList)); % 丢包补偿/修复后的SSIM
klSigVsNoise = nan(1, numel(EbN0dBList)); % KL(P_signal || P_noise)
klNoiseVsSig = nan(1, numel(EbN0dBList)); % KL(P_noise || P_signal)
klSym = nan(1, numel(EbN0dBList)); % 对称KL


example = repmat(struct("EbN0dB", NaN, "methods", struct()), 1, numel(EbN0dBList));

eveEnabled = isfield(p, "eve") && isfield(p.eve, "enable") && p.eve.enable;
scrambleAssumptionEve = "";
fhAssumptionEve = "";
chaosAssumptionEve = "";
chaosApproxDeltaEve = NaN;
chaosEncInfoEve = struct('enabled', false, 'mode', "none");
eveEbN0dBList = [];
eveRxSync = struct();
eveMitigation = struct();
eveBudget = struct();
if eveEnabled
    eveCfg = local_validate_eve_config_local(p.eve, methods, p.channel);
    eveRxSync = eveCfg.rxSync;
    eveMitigation = eveCfg.mitigation;
    chaosApproxDeltaEve = double(eveCfg.chaosApproxDelta);
    local_require_presync_mitigation_cfg_local(eveMitigation, "eve.mitigation");

    eveBudget = local_offset_budget_from_base_local(linkBudget.bob, double(eveCfg.linkGainOffsetDb));
    eveEbN0dBList = eveBudget.ebN0dB;
    berEve = nan(numel(methods), numel(EbN0dBList));
    packetFrontEndEveVals = nan(1, numel(EbN0dBList));
    packetHeaderEveVals = nan(1, numel(EbN0dBList));
    packetFrontEndEveMethodVals = nan(numel(methods), numel(EbN0dBList));
    packetHeaderEveMethodVals = nan(numel(methods), numel(EbN0dBList));
    packetSuccessEveVals = nan(numel(methods), numel(EbN0dBList));
    rawPacketSuccessEveVals = nan(numel(methods), numel(EbN0dBList));
    mseCommEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrCommEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimCommEveVals = nan(numel(methods), numel(EbN0dBList));
    mseCompEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrCompEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimCompEveVals = nan(numel(methods), numel(EbN0dBList));
    exampleEve = repmat(struct("EbN0dB", NaN, "methods", struct()), 1, numel(EbN0dBList));

    scrambleAssumptionEve = lower(string(eveCfg.scrambleAssumption));
    switch scrambleAssumptionEve
        case {"known", "none", "wrong_key"}
            % 有效配置
        otherwise
            error("Unknown eve.scrambleAssumption: %s", string(eveCfg.scrambleAssumption));
    end

    % Eve对跳频的知识（具体每包序列在后面统一预计算）
    fhAssumptionEve = lower(string(eveCfg.fhAssumption));
    switch fhAssumptionEve
        case {"known", "none", "partial"}
            % 有效配置
        otherwise
            error("Unknown eve.fhAssumption: %s", string(eveCfg.fhAssumption));
    end

    % Eve对混沌加密的知识
    chaosAssumptionEve = lower(string(eveCfg.chaosAssumption));
    switch chaosAssumptionEve
        case "known"
            if packetIndependentBitChaos
                chaosEncInfoEve = struct('enabled', true, 'mode', "payload_bits_packet");
            else
                % Eve知道混沌密钥（最佳截获情况）
                chaosEncInfoEve = chaosEncInfo;
            end
        case "none"
            % Eve不知道混沌加密，不解密（看到的是加密图像）
            chaosEncInfoEve = struct('enabled', false);
        case "approximate"
            if chaosEnabled
                if packetIndependentBitChaos
                    chaosEncInfoEve = struct('enabled', true, 'mode', "payload_bits_packet");
                else
                    chaosEncInfoEve = perturb_chaos_enc_info(chaosEncInfo, chaosApproxDeltaEve);
                end
            else
                chaosEncInfoEve = struct('enabled', false);
            end
        case "wrong_key"
            if chaosEnabled
                if packetIndependentBitChaos
                    chaosEncInfoEve = struct('enabled', true, 'mode', "payload_bits_packet");
                else
                    % Eve使用错误的混沌密钥
                    chaosEncInfoEve = perturb_chaos_enc_info(chaosEncInfo, local_wrong_key_delta_local(1));
                end
            else
                chaosEncInfoEve = struct('enabled', false);
            end
        otherwise
            error("Unknown eve.chaosAssumption: %s", string(eveCfg.chaosAssumption));
    end
end

wardenEnabled = isfield(p, "covert") && isfield(p.covert, "enable") && p.covert.enable ...
    && isfield(p.covert, "warden") && isfield(p.covert.warden, "enable") && p.covert.warden.enable;

% 主链路并行配置（可选）
simUseParallel = isfield(p, "sim") && isfield(p.sim, "useParallel") && logical(p.sim.useParallel);
simParallelMode = "methods";
if isfield(p, "sim") && isfield(p.sim, "parallelMode") && strlength(string(p.sim.parallelMode)) > 0
    simParallelMode = lower(string(p.sim.parallelMode));
end
if ~any(simParallelMode == ["methods", "frames"])
    error("simulate:UnsupportedParallelMode", ...
        "sim.parallelMode must be ""methods"" or ""frames"", got %s.", string(simParallelMode));
end
simNWorkers = 0;
if isfield(p, "sim") && isfield(p.sim, "nWorkers") && ~isempty(p.sim.nWorkers)
    simNWorkers = max(0, round(double(p.sim.nWorkers)));
end

% 若Warden或主链路任一启用并行，则统一开池（避免重复开池的额外开销）。
wardenUseParallel = false;
wardenNWorkers = 0;
if wardenEnabled && isfield(p.covert.warden, "useParallel") && logical(p.covert.warden.useParallel)
    wardenUseParallel = true;
    if isfield(p.covert.warden, "nWorkers") && ~isempty(p.covert.warden.nWorkers)
        wardenNWorkers = max(0, round(double(p.covert.warden.nWorkers)));
    end
end

poolWorkers = 0;
if simUseParallel
    poolWorkers = max(poolWorkers, simNWorkers);
end
if wardenUseParallel
    poolWorkers = max(poolWorkers, wardenNWorkers);
end
poolObj = [];
if poolWorkers > 0
    poolObj = ensure_parpool(poolWorkers);
end
if wardenEnabled
    wardenPointDetections = cell(1, numel(EbN0dBList));
    [wardenBudget, wardenReferenceLink] = local_resolve_warden_budget_local( ...
        linkBudget.bob, eveBudget, eveEnabled, p.covert.warden);
    wardenEbN0dBList = wardenBudget.ebN0dB;
end

maxDelaySamples = max(0, round(double(p.channel.maxDelaySymbols) * waveform.sps));

totalPointCount = numel(EbN0dBList);
totalFrames = totalPointCount * p.sim.nFramesPerPoint;
globalFrameIdx = 0;
frameLogStep = max(1, floor(p.sim.nFramesPerPoint / 10));
simTic = tic;

fprintf('\n========================================\n');
fprintf('[SIM] 链路仿真开始\n');
if jsrScanIsGrid
    fprintf('[SIM] 仿真点数=%d (Eb/N0=%d × JSR=%d), 每点帧数=%d, 总帧数=%d\n', ...
        totalPointCount, double(linkBudget.nSnr), double(linkBudget.nJsr), p.sim.nFramesPerPoint, totalFrames);
else
    fprintf('[SIM] 仿真点数=%d (Eb/N0=%d), 每点帧数=%d, 总帧数=%d\n', ...
        totalPointCount, double(linkBudget.nSnr), p.sim.nFramesPerPoint, totalFrames);
end
fprintf('[SIM] Eb/N0点=%s dB\n', mat2str(double(linkBudget.snrDbList)));
if jsrScanIsGrid
    fprintf('[SIM] JSR点=%s dB\n', mat2str(double(linkBudget.jsrDbList)));
else
    fprintf('[SIM] JSR扫描: OFF (all configured interference sources disabled)\n');
end
if isempty(activeInterferenceTypes)
    activeTxt = "none";
else
    activeTxt = strjoin(cellstr(activeInterferenceTypes), ", ");
end
fprintf('[SIM] 启用干扰类型: %s\n', activeTxt);
fprintf('[SIM] 允许方法: %s\n', strjoin(cellstr(allowedMethods), ', '));
fprintf('[SIM] 抑制方法(%d): %s\n', numel(methods), strjoin(cellstr(methods), ', '));
if numel(methods) > 1 && ~jsrScanIsGrid
    fprintf('[SIM] NOTE: impulse/tone/narrowband/sweep all disabled. Most mitigation methods will behave like \"none\".\n');
end
syncEnabledBob = local_sync_enabled_local(bobRxSync);
syncEnabledEve = false;
if eveEnabled
    syncEnabledEve = local_sync_enabled_local(eveRxSync);
end
mpEnabled = isfield(p.channel, "multipath") && isfield(p.channel.multipath, "enable") && p.channel.multipath.enable;
if waveform.enable
    pulseTxt = sprintf('ON(sps=%d)', waveform.sps);
else
    pulseTxt = 'OFF';
end
if dsssEnabled
    dsssTxt = sprintf('ON(sf=%d)', dsss_effective_spread_factor(p.dsss));
else
    dsssTxt = 'OFF';
end
fprintf('[SIM] Eve=%s, Warden=%s, FH=%s, DSSS=%s, Chaos=%s, Pulse=%s, RxSync(B/E)=%s/%s, MP=%s\n', ...
    on_off_text(eveEnabled), on_off_text(wardenEnabled), on_off_text(fhEnabled), ...
    dsssTxt, on_off_text(chaosEnabled), pulseTxt, on_off_text(syncEnabledBob), on_off_text(syncEnabledEve), on_off_text(mpEnabled));
if simUseParallel || wardenUseParallel
    fprintf('[SIM] Parallel requested: MainLink=%s(mode=%s, workers=%d), Warden=%s(workers=%d)\n', ...
        on_off_text(simUseParallel), char(simParallelMode), simNWorkers, ...
        on_off_text(wardenUseParallel), wardenNWorkers);
else
    fprintf('[SIM] Parallel requested: OFF\n');
end
poolTxt = "OFF";
poolN = 0;
try
    if isempty(poolObj) && exist("gcp", "file") == 2
        poolObj = gcp("nocreate");
    end
    if ~isempty(poolObj)
        poolN = poolObj.NumWorkers;
        poolTxt = sprintf("ON(%d workers)", poolN);
    end
catch
    poolTxt = "OFF";
end
fprintf('[SIM] Parallel pool: %s\n', char(poolTxt));
fprintf('========================================\n\n');

%% 主仿真循环：信道传输与接收端处理
for ie = 1:numel(EbN0dBList)
    pointTic = tic;
    EbN0dB = EbN0dBList(ie);
    JsrDb = JsrDbList(ie);
    N0 = linkBudget.bob.noisePsdLin(ie);
    txBurstBobForPoint = linkBudget.bob.rxAmplitudeScale(ie) * txSymForChannel;
    channelPoint = p.channel;
    if jsrScanIsGrid
        channelPoint = local_scale_channel_for_jsr_local(p.channel, linkBudget.bob.rxPowerLin(ie), N0, JsrDb, waveform);
    end
    channelSample = adapt_channel_for_sps(channelPoint, waveform, p.fh);
    [klSigVsNoise(ie), klNoiseVsSig(ie), klSym(ie)] = signal_noise_kl(txBurstBobForPoint, N0, 128);

    if jsrScanIsGrid
        fprintf('[SIM] >>> 仿真点 %d/%d: Eb/N0 %.2f dB, JSR %.2f dB, txPower %.2f dB\n', ...
            ie, totalPointCount, EbN0dB, JsrDb, linkBudget.bob.txPowerDb(ie));
    else
        fprintf('[SIM] >>> 仿真点 %d/%d: Eb/N0 %.2f dB, txPower %.2f dB\n', ...
            ie, totalPointCount, EbN0dB, linkBudget.bob.txPowerDb(ie));
    end

    if eveEnabled
        EbN0dBEve = eveBudget.ebN0dB(ie);
        N0Eve = eveBudget.noisePsdLin(ie);
        fprintf('[SIM]     Eve等效Eb/N0: %.2f dB (linkGain偏移 %.2f dB)\n', ...
            EbN0dBEve, double(p.eve.linkGainOffsetDb));
    end

    if wardenEnabled
        EbN0dBWarden = wardenEbN0dBList(ie);
        N0Warden = wardenBudget.noisePsdLin(ie);
        fprintf('[SIM]     Warden等效Eb/N0: %.2f dB (%s)\n', EbN0dBWarden, wardenReferenceLink);
        wardenCfg = p.covert.warden;
        wardenCfg.referenceLink = wardenReferenceLink;
        % 同步跳频频点数和过采样率到warden配置，确保两个新层参数与仿真一致
        if isfield(wardenCfg, "fhNarrowband") && isfield(wardenCfg.fhNarrowband, "enable") && wardenCfg.fhNarrowband.enable
            if isfield(p, "fh") && isfield(p.fh, "nFreqs")
                wardenCfg.fhNarrowband.nFreqs = p.fh.nFreqs;
            end
        end
        if isfield(wardenCfg, "cyclostationary") && isfield(wardenCfg.cyclostationary, "enable") && wardenCfg.cyclostationary.enable
            wardenCfg.cyclostationary.sps = waveform.sps;
        end

        % 避免Warden评估消耗全局RNG，导致Bob/Eve结果随“是否开启Warden”而变化。
        wardenRngScope = rng_scope(local_point_seed_base_local(double(p.rngSeed) + 100000, ie, commonRandomFramesAcrossPoints)); %#ok<NASGU>
        det = warden_energy_detector( ...
            wardenBudget.rxAmplitudeScale(ie) * txSymForChannel, N0Warden, channelSample, maxDelaySamples, wardenCfg);
        clear wardenRngScope
        wardenPointDetections{ie} = det;
    end


    nErr = zeros(numel(methods), 1);
    nTot = zeros(numel(methods), 1);
    packetFrontEndBobAcc = zeros(numel(methods), 1);
    packetHeaderBobAcc = zeros(numel(methods), 1);
    packetSuccessBobAcc = zeros(numel(methods), 1);
    rawPacketSuccessBobAcc = zeros(numel(methods), 1);
    adaptiveClassBobAcc = zeros(numel(adaptiveDiagCfgGlobal.classNames), numel(methods));
    adaptiveActionBobAcc = zeros(numel(adaptiveDiagCfgGlobal.actionNames), numel(methods));
    adaptivePathBobAcc = zeros(numel(adaptiveDiagCfgGlobal.bootstrapPaths), numel(methods));
    adaptiveConfidenceBobAcc = zeros(numel(methods), 1);
    adaptiveDecisionBobAcc = zeros(numel(methods), 1);
    metricAccComm = init_image_metric_acc_local(numel(methods));
    metricAccComp = init_image_metric_acc_local(numel(methods));
    exampleCandidates = init_example_candidate_bank_local(numel(methods), p.sim.nFramesPerPoint);


    if eveEnabled
        nErrEve = zeros(numel(methods), 1);
        nTotEve = zeros(numel(methods), 1);
        packetFrontEndEveAcc = zeros(numel(methods), 1);
        packetHeaderEveAcc = zeros(numel(methods), 1);
        packetSuccessEveAcc = zeros(numel(methods), 1);
        rawPacketSuccessEveAcc = zeros(numel(methods), 1);
        metricAccCommEve = init_image_metric_acc_local(numel(methods));
        metricAccCompEve = init_image_metric_acc_local(numel(methods));
        exampleCandidatesEve = init_example_candidate_bank_local(numel(methods), p.sim.nFramesPerPoint);
    end

    % --- 帧循环：每个链路预算点仿真多帧 ---
    totalPayloadBits = double(meta.totalPayloadBytes) * 8;
    useParallelFrames = simUseParallel && simParallelMode == "frames";
    useParallelMethods = simUseParallel && simParallelMode == "methods";
    if useParallelFrames && ~local_has_parallel_pool_local()
        error("simulate:FrameParallelPoolUnavailable", ...
            "sim.parallelMode=""frames"" requires an active parallel pool.");
    end

    EbN0dBEveLocal = NaN;
    N0EveLocal = NaN;
    eveRxAmplitudeScaleLocal = NaN;
    if eveEnabled
        EbN0dBEveLocal = EbN0dBEve;
        N0EveLocal = N0Eve;
        eveRxAmplitudeScaleLocal = eveBudget.rxAmplitudeScale(ie);
    end

    syncCfgUseBob = local_prepare_frame_sync_cfg_local(bobRxSync, p.channel, NaN);
    syncCfgUseEve = struct();
    if eveEnabled
        syncCfgUseEve = local_prepare_frame_sync_cfg_local(eveRxSync, p.channel, syncCfgUseBob.maxSearchIndex);
    end

    frameCtx = struct();
    frameCtx.p = p;
    frameCtx.methods = methods;
    frameCtx.txPackets = txPackets;
    frameCtx.txPktIndex = txPktIndex;
    frameCtx.txPayloadBits = txPayloadBits;
    frameCtx.sessionFrames = sessionFrames;
    frameCtx.waveform = waveform;
    frameCtx.channelSample = channelSample;
    frameCtx.firstSyncSym = firstSyncSym;
    frameCtx.shortSyncSym = shortSyncSym;
    frameCtx.linkBudgetBobRxAmplitudeScale = linkBudget.bob.rxAmplitudeScale(ie);
    frameCtx.eveRxAmplitudeScale = eveRxAmplitudeScaleLocal;
    frameCtx.N0 = N0;
    frameCtx.N0Eve = N0EveLocal;
    frameCtx.EbN0dB = EbN0dB;
    frameCtx.EbN0dBEve = EbN0dBEveLocal;
    frameCtx.fhEnabled = fhEnabled;
    frameCtx.packetIndependentBitChaos = packetIndependentBitChaos;
    frameCtx.chaosEnabled = chaosEnabled;
    frameCtx.chaosEncInfo = chaosEncInfo;
    frameCtx.outerRs = txPlan.outerRs;
    frameCtx.packetConcealActive = packetConcealActive;
    frameCtx.packetConcealMode = packetConcealMode;
    frameCtx.imgTx = imgTx;
    frameCtx.meta = meta;
    frameCtx.totalPayloadBits = totalPayloadBits;
    frameCtx.bobRxSync = bobRxSync;
    frameCtx.bobMitigation = bobMitigation;
    frameCtx.eveRxSync = eveRxSync;
    frameCtx.eveMitigation = eveMitigation;
    frameCtx.eveEnabled = eveEnabled;
    frameCtx.scrambleAssumptionEve = scrambleAssumptionEve;
    frameCtx.fhAssumptionEve = fhAssumptionEve;
    frameCtx.chaosAssumptionEve = chaosAssumptionEve;
    frameCtx.chaosApproxDeltaEve = chaosApproxDeltaEve;
    frameCtx.chaosEncInfoEve = chaosEncInfoEve;
    frameCtx.useParallelMethods = useParallelMethods;
    frameCtx.syncCfgUseBob = syncCfgUseBob;
    frameCtx.syncCfgUseEve = syncCfgUseEve;
    frameCtx.frameSeedBase = local_point_seed_base_local(p.rngSeed, ie, commonRandomFramesAcrossPoints);

    frameOutputs = cell(p.sim.nFramesPerPoint, 1);
    if useParallelFrames
        fprintf('[SIM]     帧并行模式: dispatch %d 帧到 worker。\n', p.sim.nFramesPerPoint);
        parfor frameIdx = 1:p.sim.nFramesPerPoint
            frameOutputs{frameIdx} = local_run_single_frame_local(frameIdx, frameCtx);
        end
        globalFrameIdx = globalFrameIdx + p.sim.nFramesPerPoint;
    else
        for frameIdx = 1:p.sim.nFramesPerPoint
            globalFrameIdx = globalFrameIdx + 1;
            if p.sim.nFramesPerPoint <= 20 || frameIdx == 1 || frameIdx == p.sim.nFramesPerPoint || mod(frameIdx, frameLogStep) == 0
                fprintf('[SIM]     帧 %d/%d (总进度 %d/%d, %.1f%%)\n', ...
                    frameIdx, p.sim.nFramesPerPoint, globalFrameIdx, totalFrames, ...
                    100 * globalFrameIdx / max(totalFrames, 1));
            end
            frameOutputs{frameIdx} = local_run_single_frame_local(frameIdx, frameCtx);
        end
    end

    for frameIdx = 1:p.sim.nFramesPerPoint
        frameOut = frameOutputs{frameIdx};
        packetFrontEndBobAcc = packetFrontEndBobAcc + frameOut.bobFrontEndSuccessRate;
        packetHeaderBobAcc = packetHeaderBobAcc + frameOut.bobHeaderSuccessRate;

        bobFrame = frameOut.bobFrame;
        exampleCandidates = accumulate_example_candidate_bank_local(exampleCandidates, frameIdx, bobFrame, EbN0dB, "Bob");
        nErr = nErr + bobFrame.nErr;
        nTot = nTot + bobFrame.nTot;
        packetSuccessBobAcc = packetSuccessBobAcc + bobFrame.packetSuccessRate;
        rawPacketSuccessBobAcc = rawPacketSuccessBobAcc + bobFrame.rawPacketSuccessRate;
        adaptiveClassBobAcc = adaptiveClassBobAcc + bobFrame.adaptiveFrontEnd.classCounts;
        adaptiveActionBobAcc = adaptiveActionBobAcc + bobFrame.adaptiveFrontEnd.actionCounts;
        adaptivePathBobAcc = adaptivePathBobAcc + bobFrame.adaptiveFrontEnd.pathCounts;
        adaptiveConfidenceBobAcc = adaptiveConfidenceBobAcc + bobFrame.adaptiveFrontEnd.confidenceSum;
        adaptiveDecisionBobAcc = adaptiveDecisionBobAcc + bobFrame.adaptiveFrontEnd.decisionCount;
        for im = 1:numel(methods)
            metricAccComm = accumulate_image_metric_acc_local(metricAccComm, im, ...
                bobFrame.metricsComm.mse(im), bobFrame.metricsComm.psnr(im), bobFrame.metricsComm.ssim(im));
            metricAccComp = accumulate_image_metric_acc_local(metricAccComp, im, ...
                bobFrame.metricsComp.mse(im), bobFrame.metricsComp.psnr(im), bobFrame.metricsComp.ssim(im));
        end

        if eveEnabled
            packetFrontEndEveAcc = packetFrontEndEveAcc + frameOut.eveFrontEndSuccessRate;
            packetHeaderEveAcc = packetHeaderEveAcc + frameOut.eveHeaderSuccessRate;
            eveFrame = frameOut.eveFrame;
            exampleCandidatesEve = accumulate_example_candidate_bank_local(exampleCandidatesEve, frameIdx, eveFrame, EbN0dBEveLocal, "Eve");
            nErrEve = nErrEve + eveFrame.nErr;
            nTotEve = nTotEve + eveFrame.nTot;
            packetSuccessEveAcc = packetSuccessEveAcc + eveFrame.packetSuccessRate;
            rawPacketSuccessEveAcc = rawPacketSuccessEveAcc + eveFrame.rawPacketSuccessRate;
            for im = 1:numel(methods)
                metricAccCommEve = accumulate_image_metric_acc_local(metricAccCommEve, im, ...
                    eveFrame.metricsComm.mse(im), eveFrame.metricsComm.psnr(im), eveFrame.metricsComm.ssim(im));
                metricAccCompEve = accumulate_image_metric_acc_local(metricAccCompEve, im, ...
                    eveFrame.metricsComp.mse(im), eveFrame.metricsComp.psnr(im), eveFrame.metricsComp.ssim(im));
            end
        end
    end

    % --- 当前链路预算点的性能统计 ---
    ber(:, ie) = nErr ./ max(nTot, 1);
    packetFrontEndBobMethodVals(:, ie) = packetFrontEndBobAcc / p.sim.nFramesPerPoint;
    packetHeaderBobMethodVals(:, ie) = packetHeaderBobAcc / p.sim.nFramesPerPoint;
    packetFrontEndBobVals(ie) = mean(packetFrontEndBobMethodVals(:, ie));
    packetHeaderBobVals(ie) = mean(packetHeaderBobMethodVals(:, ie));
    packetSuccessBobVals(:, ie) = packetSuccessBobAcc / p.sim.nFramesPerPoint;
    rawPacketSuccessBobVals(:, ie) = rawPacketSuccessBobAcc / p.sim.nFramesPerPoint;
    adaptiveClassBobVals(:, :, ie) = adaptiveClassBobAcc;
    adaptiveActionBobVals(:, :, ie) = adaptiveActionBobAcc;
    adaptivePathBobVals(:, :, ie) = adaptivePathBobAcc;
    adaptiveMeanConfidenceNow = nan(numel(methods), 1);
    hasAdaptiveDecision = adaptiveDecisionBobAcc > 0;
    adaptiveMeanConfidenceNow(hasAdaptiveDecision) = ...
        adaptiveConfidenceBobAcc(hasAdaptiveDecision) ./ adaptiveDecisionBobAcc(hasAdaptiveDecision);
    adaptiveMeanConfidenceBobVals(:, ie) = adaptiveMeanConfidenceNow;

    [mseOutComm, psnrOutComm, ssimOutComm] = finalize_image_metric_acc_local(metricAccComm);
    [mseOutComp, psnrOutComp, ssimOutComp] = finalize_image_metric_acc_local(metricAccComp);
    mseCommVals(:, ie) = mseOutComm;
    psnrCommVals(:, ie) = psnrOutComm;
    ssimCommVals(:, ie) = ssimOutComm;
    mseCompVals(:, ie) = mseOutComp;
    psnrCompVals(:, ie) = psnrOutComp;
    ssimCompVals(:, ie) = ssimOutComp;
    example(ie) = select_example_point_nearest_mean_local( ...
        EbN0dB, methods, exampleCandidates, ...
        struct("mse", mseOutComm, "psnr", psnrOutComm, "ssim", ssimOutComm), ...
        struct("mse", mseOutComp, "psnr", psnrOutComp, "ssim", ssimOutComp), ...
        packetConcealActive, "Bob");


    if eveEnabled
        berEve(:, ie) = nErrEve ./ max(nTotEve, 1);
        packetFrontEndEveMethodVals(:, ie) = packetFrontEndEveAcc / p.sim.nFramesPerPoint;
        packetHeaderEveMethodVals(:, ie) = packetHeaderEveAcc / p.sim.nFramesPerPoint;
        packetFrontEndEveVals(ie) = mean(packetFrontEndEveMethodVals(:, ie));
        packetHeaderEveVals(ie) = mean(packetHeaderEveMethodVals(:, ie));
        packetSuccessEveVals(:, ie) = packetSuccessEveAcc / p.sim.nFramesPerPoint;
        rawPacketSuccessEveVals(:, ie) = rawPacketSuccessEveAcc / p.sim.nFramesPerPoint;

        [mseOutCommEve, psnrOutCommEve, ssimOutCommEve] = finalize_image_metric_acc_local(metricAccCommEve);
        [mseOutCompEve, psnrOutCompEve, ssimOutCompEve] = finalize_image_metric_acc_local(metricAccCompEve);
        mseCommEveVals(:, ie) = mseOutCommEve;
        psnrCommEveVals(:, ie) = psnrOutCommEve;
        ssimCommEveVals(:, ie) = ssimOutCommEve;
        mseCompEveVals(:, ie) = mseOutCompEve;
        psnrCompEveVals(:, ie) = psnrOutCompEve;
        ssimCompEveVals(:, ie) = ssimOutCompEve;
        exampleEve(ie) = select_example_point_nearest_mean_local( ...
            EbN0dBEve, methods, exampleCandidatesEve, ...
            struct("mse", mseOutCommEve, "psnr", psnrOutCommEve, "ssim", ssimOutCommEve), ...
            struct("mse", mseOutCompEve, "psnr", psnrOutCompEve, "ssim", ssimOutCompEve), ...
            packetConcealActive, "Eve");
    end

    if jsrScanIsGrid
        fprintf('[SIM] <<< 仿真点完成: Eb/N0 %.2f dB, JSR %.2f dB, txPower %.2f dB, 用时 %.2fs\n', ...
            EbN0dB, JsrDb, linkBudget.bob.txPowerDb(ie), toc(pointTic));
    else
        fprintf('[SIM] <<< 仿真点完成: Eb/N0 %.2f dB, txPower %.2f dB, 用时 %.2fs\n', ...
            EbN0dB, linkBudget.bob.txPowerDb(ie), toc(pointTic));
    end
    fprintf('[SIM]     Bob BER: %s\n', format_metric_pairs(methods, ber(:, ie)));
    if eveEnabled
        fprintf('[SIM]     Eve BER: %s\n', format_metric_pairs(methods, berEve(:, ie)));
    end
    fprintf('\n');
end

%% 仿真评估与结果汇总（SIMULATION EVALUATION）
fprintf('[SIM] 开始频谱估计与结果汇总...\n');

% 波形/频谱（单次突发，无信道，基于真实发射采样波形）
[~, spectrumPointIdx] = max(linkBudget.bob.txPowerLin);
txBurstForSpectrum = linkBudget.bob.rxAmplitudeScale(spectrumPointIdx) * txSymForChannel;
txBurstBasebandForSpectrum = txBurstForSpectrum;
if isfield(txPlan, "txBurstBasebandForSpectrum") && ~isempty(txPlan.txBurstBasebandForSpectrum)
    txBurstBasebandForSpectrum = linkBudget.bob.rxAmplitudeScale(spectrumPointIdx) * txPlan.txBurstBasebandForSpectrum;
end
[psd, freqHz, burstBw99Hz, burstEtaBpsHz, burstSpectrumInfo] = estimate_spectrum( ...
    txBurstForSpectrum, modInfo, waveform, struct("payloadBits", numel(payloadBits)));
[~, ~, basebandBw99Hz, basebandEtaBpsHz, basebandSpectrumInfo] = estimate_spectrum( ...
    txBurstBasebandForSpectrum, modInfo, waveform, struct("payloadBits", numel(payloadBits)));

results = struct();
results.params = p;
results.ebN0dB = EbN0dBList;
results.jsrDb = JsrDbList;
results.scan = struct( ...
    "type", string(linkBudget.scanType), ...
    "ebN0dBList", linkBudget.snrDbList, ...
    "jsrDbList", linkBudget.jsrDbList, ...
    "snrIndex", pointSnrIndex, ...
    "jsrIndex", pointJsrIndex, ...
    "nSnr", double(linkBudget.nSnr), ...
    "nJsr", double(linkBudget.nJsr));
results.methods = methods;
results.tx = txReport;
results.linkBudget = linkBudget;
results.ber = ber;
results.rawPer = max(min(1 - rawPacketSuccessBobVals, 1), 0);
results.per = max(min(1 - packetSuccessBobVals, 1), 0);
results.packetDiagnostics = struct();
results.packetDiagnostics.bob = struct( ...
    "frontEndSuccessRate", packetFrontEndBobVals, ...
    "headerSuccessRate", packetHeaderBobVals, ...
    "frontEndSuccessRateByMethod", packetFrontEndBobMethodVals, ...
    "headerSuccessRateByMethod", packetHeaderBobMethodVals, ...
    "rawPayloadSuccessRate", rawPacketSuccessBobVals, ...
    "payloadSuccessRate", packetSuccessBobVals, ...
    "adaptiveFrontEnd", struct( ...
        "classNames", adaptiveDiagCfgGlobal.classNames, ...
        "actionNames", adaptiveDiagCfgGlobal.actionNames, ...
        "bootstrapPaths", adaptiveDiagCfgGlobal.bootstrapPaths, ...
        "classCounts", adaptiveClassBobVals, ...
        "actionCounts", adaptiveActionBobVals, ...
        "pathCounts", adaptivePathBobVals, ...
        "meanConfidence", adaptiveMeanConfidenceBobVals));
results.packetConceal = struct("configured", packetConcealEnable, "active", packetConcealActive, "mode", packetConcealMode);
results.imageMetrics = struct();
results.imageMetrics.communication = struct("mse", mseCommVals, "psnr", psnrCommVals, "ssim", ssimCommVals);
results.imageMetrics.compensated = struct("mse", mseCompVals, "psnr", psnrCompVals, "ssim", ssimCompVals);
results.mse = mseCommVals;
results.psnr = psnrCommVals;
results.ssim = ssimCommVals;
results.mseCompensated = mseCompVals;
results.psnrCompensated = psnrCompVals;
results.ssimCompensated = ssimCompVals;
results.example = example;
results.spectrum = struct( ...
    "freqHz", freqHz, ...
    "psd", psd, ...
    "bw99Hz", burstBw99Hz, ...
    "etaBpsHz", burstEtaBpsHz, ...
    "burstBw99Hz", burstBw99Hz, ...
    "burstEtaBpsHz", burstEtaBpsHz, ...
    "basebandBw99Hz", basebandBw99Hz, ...
    "basebandEtaBpsHz", basebandEtaBpsHz, ...
    "symbolRateHz", burstSpectrumInfo.symbolRateHz, ...
    "sampleRateHz", burstSpectrumInfo.sampleRateHz, ...
    "burstDurationSec", burstSpectrumInfo.burstDurationSec, ...
    "grossInfoBitRateBps", burstSpectrumInfo.grossInfoBitRateBps, ...
    "payloadBitRateBps", burstSpectrumInfo.payloadBitRateBps, ...
    "burstInfo", burstSpectrumInfo, ...
    "basebandInfo", basebandSpectrumInfo);
results.kl = struct("ebN0dB", EbN0dBList, ...
    "jsrDb", JsrDbList, ...
    "signalVsNoise", klSigVsNoise, ...
    "noiseVsSignal", klNoiseVsSig, ...
    "symmetric", klSym);


if eveEnabled
    results.linkBudget.eve = eveBudget;
    results.eve = struct();
    results.eve.methods = methods;
    results.eve.ebN0dB = eveEbN0dBList;
    results.eve.jsrDb = JsrDbList;
    results.eve.scan = results.scan;
    results.eve.ber = berEve;
    results.eve.rawPer = max(min(1 - rawPacketSuccessEveVals, 1), 0);
    results.eve.per = max(min(1 - packetSuccessEveVals, 1), 0);
    results.eve.packetDiagnostics = struct( ...
        "frontEndSuccessRate", packetFrontEndEveVals, ...
        "headerSuccessRate", packetHeaderEveVals, ...
        "frontEndSuccessRateByMethod", packetFrontEndEveMethodVals, ...
        "headerSuccessRateByMethod", packetHeaderEveMethodVals, ...
        "rawPayloadSuccessRate", rawPacketSuccessEveVals, ...
        "payloadSuccessRate", packetSuccessEveVals);
    results.eve.assumptions = struct( ...
        "scramble", string(scrambleAssumptionEve), ...
        "fh", string(fhAssumptionEve), ...
        "chaos", string(chaosAssumptionEve), ...
        "chaosApproxDelta", chaosApproxDeltaEve);
    results.eve.receiver = struct( ...
        "rxSync", local_pack_rx_sync_summary_local(eveRxSync), ...
        "mitigation", local_pack_mitigation_summary_local(eveMitigation));
    results.eve.imageMetrics = struct();
    results.eve.imageMetrics.communication = struct("mse", mseCommEveVals, "psnr", psnrCommEveVals, "ssim", ssimCommEveVals);
    results.eve.imageMetrics.compensated = struct("mse", mseCompEveVals, "psnr", psnrCompEveVals, "ssim", ssimCompEveVals);
    results.eve.mse = mseCommEveVals;
    results.eve.psnr = psnrCommEveVals;
    results.eve.ssim = ssimCommEveVals;
    results.eve.mseCompensated = mseCompEveVals;
    results.eve.psnrCompensated = psnrCompEveVals;
    results.eve.ssimCompensated = ssimCompEveVals;
    results.eve.example = exampleEve;
    results.eve.scrambleAssumption = string(scrambleAssumptionEve);
    results.eve.fhAssumption = string(fhAssumptionEve);
    results.eve.chaosAssumption = string(chaosAssumptionEve);
    results.eve.chaosApproxDelta = chaosApproxDeltaEve;
end

if wardenEnabled
    results.linkBudget.warden = wardenBudget;
    results.covert = struct();
    results.covert.warden = local_pack_warden_results( ...
        wardenPointDetections, EbN0dBList, wardenEbN0dBList, wardenReferenceLink);
    results.covert.warden.jsrDb = JsrDbList;
    results.covert.warden.scan = results.scan;
    if eveEnabled
        results.covert.warden.eveEbN0dB = eveEbN0dBList;
    end
end

results.summary = make_summary(results);

if p.sim.saveFigures
    fprintf('[SIM] 保存结果与图像...\n');
    outDir = make_results_dir(p.sim.resultsDir);
    save(fullfile(outDir, "results.mat"), "-struct", "results");
    save_figures(outDir, imgTx, results);
    export_thesis_tables(outDir, results);
    fprintf('[SIM] 已保存至: %s\n', outDir);
end

fprintf('[SIM] 链路仿真结束，总耗时 %.2fs\n', toc(simTic));

end

function acc = init_image_metric_acc_local(nMethods)
acc = struct();
acc.mse = zeros(nMethods, 1);
acc.psnr = zeros(nMethods, 1);
acc.ssim = zeros(nMethods, 1);
acc.nMse = zeros(nMethods, 1);
acc.nPsnr = zeros(nMethods, 1);
acc.nSsim = zeros(nMethods, 1);
end

function acc = accumulate_image_metric_acc_local(acc, methodIdx, mseVal, psnrVal, ssimVal)
if isfinite(mseVal)
    acc.mse(methodIdx) = acc.mse(methodIdx) + mseVal;
    acc.nMse(methodIdx) = acc.nMse(methodIdx) + 1;
end
if ~isnan(psnrVal)
    acc.psnr(methodIdx) = acc.psnr(methodIdx) + psnrVal;
    acc.nPsnr(methodIdx) = acc.nPsnr(methodIdx) + 1;
end
if isfinite(ssimVal)
    acc.ssim(methodIdx) = acc.ssim(methodIdx) + ssimVal;
    acc.nSsim(methodIdx) = acc.nSsim(methodIdx) + 1;
end
end

function [mseOut, psnrOut, ssimOut] = finalize_image_metric_acc_local(acc)
mseOut = nan(size(acc.mse));
psnrOut = nan(size(acc.psnr));
ssimOut = nan(size(acc.ssim));
validMse = acc.nMse > 0;
validPsnr = acc.nPsnr > 0;
validSsim = acc.nSsim > 0;
mseOut(validMse) = acc.mse(validMse) ./ acc.nMse(validMse);
psnrOut(validPsnr) = acc.psnr(validPsnr) ./ acc.nPsnr(validPsnr);
ssimOut(validSsim) = acc.ssim(validSsim) ./ acc.nSsim(validSsim);
end

function bank = init_example_candidate_bank_local(nMethods, nFrames)
bank = struct();
bank.examples = cell(nMethods, nFrames);
bank.comm = struct( ...
    "mse", nan(nMethods, nFrames), ...
    "psnr", nan(nMethods, nFrames), ...
    "ssim", nan(nMethods, nFrames));
bank.comp = struct( ...
    "mse", nan(nMethods, nFrames), ...
    "psnr", nan(nMethods, nFrames), ...
    "ssim", nan(nMethods, nFrames));
end

function bank = accumulate_example_candidate_bank_local(bank, frameIdx, frameResult, ebN0Val, roleName)
nMethods = size(bank.examples, 1);
if numel(frameResult.example) ~= nMethods
    error("simulate:ExampleCandidateCountMismatch", ...
        "%s frame example count mismatch at frame %d: expected %d methods, got %d.", ...
        char(string(roleName)), frameIdx, nMethods, numel(frameResult.example));
end

bank.comm.mse(:, frameIdx) = frameResult.metricsComm.mse;
bank.comm.psnr(:, frameIdx) = frameResult.metricsComm.psnr;
bank.comm.ssim(:, frameIdx) = frameResult.metricsComm.ssim;
bank.comp.mse(:, frameIdx) = frameResult.metricsComp.mse;
bank.comp.psnr(:, frameIdx) = frameResult.metricsComp.psnr;
bank.comp.ssim(:, frameIdx) = frameResult.metricsComp.ssim;

for methodIdx = 1:nMethods
    exampleEntry = frameResult.example{methodIdx};
    if isempty(exampleEntry) || ~isstruct(exampleEntry)
        error("simulate:MissingExampleCandidate", ...
            "%s example candidate missing at frame %d for method index %d.", ...
            char(string(roleName)), frameIdx, methodIdx);
    end
    exampleEntry.frameIdx = frameIdx;
    exampleEntry.EbN0dB = ebN0Val;
    bank.examples{methodIdx, frameIdx} = exampleEntry;
end
end

function examplePoint = select_example_point_nearest_mean_local( ...
    ebN0Val, methods, bank, avgComm, avgComp, packetConcealActive, roleName)
examplePoint = struct("EbN0dB", ebN0Val, "methods", struct());
for methodIdx = 1:numel(methods)
    methodName = char(methods(methodIdx));
    [exampleEntry, bestFrameIdx, bestDistance] = local_select_nearest_example_candidate_local( ...
        methodName, bank, avgComm, avgComp, methodIdx, packetConcealActive, roleName);
    exampleEntry.selectedFrameIdx = bestFrameIdx;
    exampleEntry.selectionDistanceToMean = bestDistance;
    exampleEntry.selectionRule = "nearest_mean_metrics";
    examplePoint.methods.(methodName) = exampleEntry;
end
end

function [exampleEntry, bestFrameIdx, bestDistance] = local_select_nearest_example_candidate_local( ...
    methodName, bank, avgComm, avgComp, methodIdx, packetConcealActive, roleName)
metricMatrix = [ ...
    bank.comm.mse(methodIdx, :).', ...
    bank.comm.psnr(methodIdx, :).', ...
    bank.comm.ssim(methodIdx, :).'];
targetVector = [avgComm.mse(methodIdx), avgComm.psnr(methodIdx), avgComm.ssim(methodIdx)];
if packetConcealActive
    metricMatrix = [metricMatrix, ...
        bank.comp.mse(methodIdx, :).', ...
        bank.comp.psnr(methodIdx, :).', ...
        bank.comp.ssim(methodIdx, :).'];
    targetVector = [targetVector, avgComp.mse(methodIdx), avgComp.psnr(methodIdx), avgComp.ssim(methodIdx)];
end

metricMatrix = local_transform_metric_matrix_local(metricMatrix, methodName, roleName);
targetVector = local_transform_metric_vector_local(targetVector, methodName, roleName);

hasExample = ~cellfun(@isempty, bank.examples(methodIdx, :));
if ~any(hasExample)
    error("simulate:NoExampleCandidates", ...
        "No %s example candidates collected for method %s at Eb/N0=%.6f dB.", ...
        char(string(roleName)), methodName, double(ebN0Val_from_bank_local(bank, methodIdx)));
end

validDims = isfinite(targetVector) & any(isfinite(metricMatrix(hasExample, :)), 1);
if ~any(validDims)
    error("simulate:NoComparableMetrics", ...
        "No comparable metrics available to select the nearest-mean %s example for method %s at Eb/N0=%.6f dB.", ...
        char(string(roleName)), methodName, double(ebN0Val_from_bank_local(bank, methodIdx)));
end

targetVector = targetVector(validDims);
metricMatrix = metricMatrix(:, validDims);
scales = local_metric_scales_local(metricMatrix(hasExample, :));

distances = inf(1, size(metricMatrix, 1));
for frameIdx = 1:size(metricMatrix, 1)
    if ~hasExample(frameIdx)
        continue;
    end
    candidateVector = metricMatrix(frameIdx, :);
    validNow = isfinite(candidateVector) & isfinite(targetVector);
    if ~any(validNow)
        continue;
    end
    delta = (candidateVector(validNow) - targetVector(validNow)) ./ scales(validNow);
    distances(frameIdx) = mean(delta .^ 2);
end

if ~any(isfinite(distances))
    error("simulate:ExampleSelectionFailed", ...
        "Failed to select nearest-mean %s example for method %s at Eb/N0=%.6f dB.", ...
        char(string(roleName)), methodName, double(ebN0Val_from_bank_local(bank, methodIdx)));
end

[bestDistance, bestFrameIdx] = min(distances);
exampleEntry = bank.examples{methodIdx, bestFrameIdx};
if ~isstruct(exampleEntry)
    error("simulate:InvalidSelectedExample", ...
        "Selected %s example for method %s at frame %d is invalid.", ...
        char(string(roleName)), methodName, bestFrameIdx);
end
end

function ebN0Val = ebN0Val_from_bank_local(bank, methodIdx)
ebN0Val = NaN;
for frameIdx = 1:size(bank.examples, 2)
    exampleEntry = bank.examples{methodIdx, frameIdx};
    if isempty(exampleEntry)
        continue;
    end
    if ~isfield(exampleEntry, "EbN0dB")
        error("simulate:InvalidExampleCandidate", ...
            "Example candidate at frame %d is missing EbN0dB.", frameIdx);
    end
    ebN0Val = double(exampleEntry.EbN0dB);
    return;
end
end

function values = local_transform_metric_matrix_local(values, methodName, roleName)
for colIdx = [1, 4]
    if colIdx > size(values, 2)
        continue;
    end
    for rowIdx = 1:size(values, 1)
        values(rowIdx, colIdx) = local_transform_mse_metric_local(values(rowIdx, colIdx), methodName, roleName);
    end
end
end

function values = local_transform_metric_vector_local(values, methodName, roleName)
for colIdx = [1, 4]
    if colIdx > numel(values)
        continue;
    end
    values(colIdx) = local_transform_mse_metric_local(values(colIdx), methodName, roleName);
end
end

function value = local_transform_mse_metric_local(value, methodName, roleName)
if ~isfinite(value)
    return;
end
if value < 0
    error("simulate:InvalidMseMetric", ...
        "%s MSE metric for method %s must be nonnegative, got %.6g.", ...
        char(string(roleName)), methodName, value);
end
value = log10(max(value, eps));
end

function scales = local_metric_scales_local(values)
scales = ones(1, size(values, 2));
for colIdx = 1:size(values, 2)
    finiteVals = values(isfinite(values(:, colIdx)), colIdx);
    if numel(finiteVals) >= 2
        scaleNow = std(finiteVals);
    else
        scaleNow = 1;
    end
    if ~isfinite(scaleNow) || scaleNow < eps
        scaleNow = 1;
    end
    scales(colIdx) = scaleNow;
end
end

function h = empty_phy_header_local()
% A fixed-field placeholder so we can store PHY headers in a struct array.
h = struct();
h.magic = uint16(0);
h.flags = uint8(0);
h.hasSessionHeader = false;
h.packetIndex = uint16(0);
h.packetDataBytes = uint16(0);
h.packetDataCrc16 = uint16(0);
h.headerCrc16 = uint16(0);
end

function rxSyncUse = local_prepare_frame_sync_cfg_local(rxSyncBase, channelCfg, fallbackMaxSearchIndex)
rxSyncUse = rxSyncBase;
if ~isfield(rxSyncUse, "minSearchIndex")
    rxSyncUse.minSearchIndex = 1;
end
if isfield(rxSyncUse, "maxSearchIndex") && isfinite(double(rxSyncUse.maxSearchIndex))
    return;
end

if nargin >= 3 && isfinite(double(fallbackMaxSearchIndex))
    rxSyncUse.maxSearchIndex = double(fallbackMaxSearchIndex);
    return;
end

mpExtra = 0;
if isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "enable") && channelCfg.multipath.enable ...
        && ( ...
            (isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)) || ...
            (isfield(channelCfg.multipath, "pathDelays") && ~isempty(channelCfg.multipath.pathDelays)) )
    if isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)
        mpExtra = max(double(channelCfg.multipath.pathDelaysSymbols(:)));
    else
        mpExtra = max(double(channelCfg.multipath.pathDelays(:)));
    end
end

if isfield(channelCfg, "maxDelaySymbols")
    rxSyncUse.maxSearchIndex = double(channelCfg.maxDelaySymbols) + mpExtra + 6;
else
    rxSyncUse.maxSearchIndex = inf;
end
end

function baseSeed = local_point_seed_base_local(globalSeed, pointIdx, commonAcrossPoints)
globalSeed = round(double(globalSeed));
pointIdx = round(double(pointIdx));
commonAcrossPoints = logical(commonAcrossPoints);
pointSalt = 0;
if ~commonAcrossPoints
    pointSalt = 1000000 * pointIdx;
end
baseSeed = mod(globalSeed + pointSalt - 1, 2^32 - 1) + 1;
end

function seed = local_frame_seed_local(baseSeed, frameIdx)
seed = mod(round(double(baseSeed)) + round(double(frameIdx)) - 1, 2^32 - 1);
if seed <= 0
    seed = seed + 1;
end
end

function frameOut = local_run_single_frame_local(frameIdx, frameCtx)
if isfield(frameCtx, "frameSeedBase") && isfinite(double(frameCtx.frameSeedBase))
    frameRngScope = rng_scope(local_frame_seed_local(frameCtx.frameSeedBase, frameIdx)); %#ok<NASGU>
end

p = frameCtx.p;
waveform = frameCtx.waveform;
eveEnabled = logical(frameCtx.eveEnabled);
txPackets = frameCtx.txPackets;
nPackets = numel(txPackets);
bobRaw = local_init_raw_capture_local(nPackets, numel(frameCtx.sessionFrames));
eveRaw = struct();
if eveEnabled
    eveRaw = local_init_raw_capture_local(nPackets, numel(frameCtx.sessionFrames));
end

frameDelaySym = randi([0, p.channel.maxDelaySymbols], 1, 1);
frameDelay = round(double(frameDelaySym) * waveform.sps);
channelSampleBob = local_freeze_channel_realization_local(frameCtx.channelSample);
if eveEnabled
    channelSampleEve = local_freeze_channel_realization_local(frameCtx.channelSample);
end

if ~isempty(frameCtx.sessionFrames)
    bobRaw.sessionRx = local_capture_session_frames_raw_local( ...
        frameCtx.sessionFrames, frameCtx.linkBudgetBobRxAmplitudeScale, frameCtx.N0, channelSampleBob, frameDelay, ...
        waveform);
    if eveEnabled
        eveRaw.sessionRx = local_capture_session_frames_raw_local( ...
            frameCtx.sessionFrames, frameCtx.eveRxAmplitudeScale, frameCtx.N0Eve, channelSampleEve, frameDelay, ...
            waveform);
    end
end

for pktIdx = 1:nPackets
    pkt = txPackets(pktIdx);

    tx = [zeros(frameDelay, 1); frameCtx.linkBudgetBobRxAmplitudeScale * pkt.txSymForChannel];
    rx = channel_bg_impulsive(tx, frameCtx.N0, channelSampleBob);
    bobRaw.rxPackets{pktIdx} = rx;

    if eveEnabled
        txEve = [zeros(frameDelay, 1); frameCtx.eveRxAmplitudeScale * pkt.txSymForChannel];
        rxEve = channel_bg_impulsive(txEve, frameCtx.N0Eve, channelSampleEve);
        eveRaw.rxPackets{pktIdx} = rxEve;
    end
end

[bobFrame, eveFrame] = local_decode_frame_methods_local( ...
    frameCtx.methods, txPackets, frameCtx.txPktIndex, frameCtx.txPayloadBits, frameCtx.sessionFrames, bobRaw, eveRaw, p, waveform, frameCtx.N0, frameCtx.N0Eve, frameCtx.fhEnabled, ...
    frameCtx.packetIndependentBitChaos, frameCtx.chaosEnabled, frameCtx.chaosEncInfo, ...
    frameCtx.packetConcealActive, frameCtx.packetConcealMode, frameCtx.imgTx, frameCtx.meta, frameCtx.totalPayloadBits, ...
    frameCtx.syncCfgUseBob, frameCtx.syncCfgUseEve, frameCtx.bobRxSync, frameCtx.bobMitigation, frameCtx.eveRxSync, frameCtx.eveMitigation, ...
    eveEnabled, frameCtx.scrambleAssumptionEve, frameCtx.fhAssumptionEve, frameCtx.chaosAssumptionEve, frameCtx.chaosApproxDeltaEve, frameCtx.chaosEncInfoEve, ...
    true, frameCtx.EbN0dB, frameCtx.EbN0dBEve, frameCtx.useParallelMethods);

frameOut = struct();
frameOut.bobFrontEndSuccessRate = bobFrame.frontEndSuccessRate;
frameOut.bobHeaderSuccessRate = bobFrame.headerSuccessRate;
frameOut.bobFrame = bobFrame;
frameOut.eveFrontEndSuccessRate = zeros(numel(frameCtx.methods), 1);
frameOut.eveHeaderSuccessRate = zeros(numel(frameCtx.methods), 1);
frameOut.eveFrame = struct();
if eveEnabled
    frameOut.eveFrontEndSuccessRate = eveFrame.frontEndSuccessRate;
    frameOut.eveHeaderSuccessRate = eveFrame.headerSuccessRate;
    frameOut.eveFrame = eveFrame;
end
end

function [bobFrame, eveFrame] = local_decode_frame_methods_local( ...
    methods, txPackets, txPktIndex, txPayloadBits, sessionFrames, bobRaw, eveRaw, p, waveform, N0Bob, N0Eve, fhEnabled, ...
    packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
    packetConcealActive, packetConcealMode, imgTx, metaTx, totalPayloadBitsTx, ...
    syncCfgUseBob, syncCfgUseEve, bobRxSync, bobMitigation, eveRxSync, eveMitigation, ...
    eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosApproxDeltaEve, chaosEncInfoEve, ...
    captureExample, EbN0dB, EbN0dBEve, useParallelMethods)

nMethods = numel(methods);
nPackets = numel(txPktIndex);

nErrBob = zeros(nMethods, 1);
nTotBob = zeros(nMethods, 1);
frontEndBob = zeros(nMethods, 1);
headerBob = zeros(nMethods, 1);
mseCommBob = nan(nMethods, 1);
psnrCommBob = nan(nMethods, 1);
ssimCommBob = nan(nMethods, 1);
mseCompBob = nan(nMethods, 1);
psnrCompBob = nan(nMethods, 1);
ssimCompBob = nan(nMethods, 1);
packetSuccessBob = zeros(nMethods, 1);
rawPacketSuccessBob = zeros(nMethods, 1);
exampleBob = cell(nMethods, 1);
adaptiveDiagCfg = local_adaptive_frontend_catalog_local(bobMitigation);
adaptiveClassBob = zeros(numel(adaptiveDiagCfg.classNames), nMethods);
adaptiveActionBob = zeros(numel(adaptiveDiagCfg.actionNames), nMethods);
adaptivePathBob = zeros(numel(adaptiveDiagCfg.bootstrapPaths), nMethods);
adaptiveConfidenceBob = zeros(nMethods, 1);
adaptiveDecisionBob = zeros(nMethods, 1);

% Always preallocate Eve arrays so PARFOR variable classification is stable.
nErrEve = zeros(nMethods, 1);
nTotEve = zeros(nMethods, 1);
frontEndEve = zeros(nMethods, 1);
headerEve = zeros(nMethods, 1);
mseCommEve = nan(nMethods, 1);
psnrCommEve = nan(nMethods, 1);
ssimCommEve = nan(nMethods, 1);
mseCompEve = nan(nMethods, 1);
psnrCompEve = nan(nMethods, 1);
ssimCompEve = nan(nMethods, 1);
packetSuccessEve = zeros(nMethods, 1);
rawPacketSuccessEve = zeros(nMethods, 1);
exampleEve = cell(nMethods, 1);

useParfor = logical(useParallelMethods) && local_has_parallel_pool_local();
if useParfor
    try
        parfor im = 1:nMethods
            bobNom = local_build_packet_nominal_local( ...
                bobRaw, txPackets, sessionFrames, methods(im), bobMitigation, ...
                syncCfgUseBob, bobRxSync, p, waveform, N0Bob, fhEnabled, "known", true);
            eveNom = struct();
            if eveEnabled
                eveNom = local_build_packet_nominal_local( ...
                    eveRaw, txPackets, sessionFrames, methods(im), eveMitigation, ...
                    syncCfgUseEve, eveRxSync, p, waveform, N0Eve, fhEnabled, fhAssumptionEve, false);
            end

            [bobRes, eveRes] = local_decode_single_method_local( ...
                methods(im), txPackets, txPktIndex, txPayloadBits, sessionFrames, bobNom, eveNom, p, fhEnabled, ...
                packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
                packetConcealActive, packetConcealMode, imgTx, metaTx, totalPayloadBitsTx, ...
                bobRxSync, bobMitigation, eveRxSync, eveMitigation, ...
                eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosApproxDeltaEve, chaosEncInfoEve, ...
                captureExample, EbN0dB, EbN0dBEve, nPackets);

            nErrBob(im) = bobRes.nErr;
            nTotBob(im) = bobRes.nTot;
            frontEndBob(im) = mean(double(bobNom.frontEndOk));
            headerBob(im) = mean(double(bobNom.headerOk));
            mseCommBob(im) = bobRes.mseComm;
            psnrCommBob(im) = bobRes.psnrComm;
            ssimCommBob(im) = bobRes.ssimComm;
            mseCompBob(im) = bobRes.mseComp;
            psnrCompBob(im) = bobRes.psnrComp;
            ssimCompBob(im) = bobRes.ssimComp;
            packetSuccessBob(im) = bobRes.packetSuccessRate;
            rawPacketSuccessBob(im) = bobRes.rawPacketSuccessRate;
            exampleBob{im} = bobRes.example;
            adaptiveClassBob(:, im) = bobRes.adaptiveFrontEnd.classCounts;
            adaptiveActionBob(:, im) = bobRes.adaptiveFrontEnd.actionCounts;
            adaptivePathBob(:, im) = bobRes.adaptiveFrontEnd.pathCounts;
            adaptiveConfidenceBob(im) = bobRes.adaptiveFrontEnd.confidenceSum;
            adaptiveDecisionBob(im) = bobRes.adaptiveFrontEnd.decisionCount;

            if eveEnabled
                nErrEve(im) = eveRes.nErr;
                nTotEve(im) = eveRes.nTot;
                frontEndEve(im) = mean(double(eveNom.frontEndOk));
                headerEve(im) = mean(double(eveNom.headerOk));
                mseCommEve(im) = eveRes.mseComm;
                psnrCommEve(im) = eveRes.psnrComm;
                ssimCommEve(im) = eveRes.ssimComm;
                mseCompEve(im) = eveRes.mseComp;
                psnrCompEve(im) = eveRes.psnrComp;
                ssimCompEve(im) = eveRes.ssimComp;
                packetSuccessEve(im) = eveRes.packetSuccessRate;
                rawPacketSuccessEve(im) = eveRes.rawPacketSuccessRate;
                exampleEve{im} = eveRes.example;
            end
        end
    catch ME
        persistent warnedParallel;
        if isempty(warnedParallel); warnedParallel = false; end %#ok<PSET>
        if ~warnedParallel
            warning('SIM:MainLinkParDecodeFailed', ...
                'Main-link method-parallel decode failed (%s). Falling back to serial.', ME.message);
            warnedParallel = true;
        end
        useParfor = false;

        % Reset outputs; recompute below using serial loop.
        nErrBob = zeros(nMethods, 1);
        nTotBob = zeros(nMethods, 1);
        frontEndBob = zeros(nMethods, 1);
        headerBob = zeros(nMethods, 1);
        mseCommBob = nan(nMethods, 1);
        psnrCommBob = nan(nMethods, 1);
        ssimCommBob = nan(nMethods, 1);
        mseCompBob = nan(nMethods, 1);
        psnrCompBob = nan(nMethods, 1);
        ssimCompBob = nan(nMethods, 1);
        packetSuccessBob = zeros(nMethods, 1);
        rawPacketSuccessBob = zeros(nMethods, 1);
        exampleBob = cell(nMethods, 1);
        adaptiveClassBob = zeros(numel(adaptiveDiagCfg.classNames), nMethods);
        adaptiveActionBob = zeros(numel(adaptiveDiagCfg.actionNames), nMethods);
        adaptivePathBob = zeros(numel(adaptiveDiagCfg.bootstrapPaths), nMethods);
        adaptiveConfidenceBob = zeros(nMethods, 1);
        adaptiveDecisionBob = zeros(nMethods, 1);

        nErrEve = zeros(nMethods, 1);
        nTotEve = zeros(nMethods, 1);
        frontEndEve = zeros(nMethods, 1);
        headerEve = zeros(nMethods, 1);
        mseCommEve = nan(nMethods, 1);
        psnrCommEve = nan(nMethods, 1);
        ssimCommEve = nan(nMethods, 1);
        mseCompEve = nan(nMethods, 1);
        psnrCompEve = nan(nMethods, 1);
        ssimCompEve = nan(nMethods, 1);
        packetSuccessEve = zeros(nMethods, 1);
        rawPacketSuccessEve = zeros(nMethods, 1);
        exampleEve = cell(nMethods, 1);
    end
end

if ~useParfor
    for im = 1:nMethods
        bobNom = local_build_packet_nominal_local( ...
            bobRaw, txPackets, sessionFrames, methods(im), bobMitigation, ...
            syncCfgUseBob, bobRxSync, p, waveform, N0Bob, fhEnabled, "known", true);
        eveNom = struct();
        if eveEnabled
            eveNom = local_build_packet_nominal_local( ...
                eveRaw, txPackets, sessionFrames, methods(im), eveMitigation, ...
                syncCfgUseEve, eveRxSync, p, waveform, N0Eve, fhEnabled, fhAssumptionEve, false);
        end

        [bobRes, eveRes] = local_decode_single_method_local( ...
            methods(im), txPackets, txPktIndex, txPayloadBits, sessionFrames, bobNom, eveNom, p, fhEnabled, ...
            packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
            packetConcealActive, packetConcealMode, imgTx, metaTx, totalPayloadBitsTx, ...
            bobRxSync, bobMitigation, eveRxSync, eveMitigation, ...
            eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosApproxDeltaEve, chaosEncInfoEve, ...
            captureExample, EbN0dB, EbN0dBEve, nPackets);

        nErrBob(im) = bobRes.nErr;
        nTotBob(im) = bobRes.nTot;
        frontEndBob(im) = mean(double(bobNom.frontEndOk));
        headerBob(im) = mean(double(bobNom.headerOk));
        mseCommBob(im) = bobRes.mseComm;
        psnrCommBob(im) = bobRes.psnrComm;
        ssimCommBob(im) = bobRes.ssimComm;
        mseCompBob(im) = bobRes.mseComp;
        psnrCompBob(im) = bobRes.psnrComp;
        ssimCompBob(im) = bobRes.ssimComp;
        packetSuccessBob(im) = bobRes.packetSuccessRate;
        rawPacketSuccessBob(im) = bobRes.rawPacketSuccessRate;
        exampleBob{im} = bobRes.example;
        adaptiveClassBob(:, im) = bobRes.adaptiveFrontEnd.classCounts;
        adaptiveActionBob(:, im) = bobRes.adaptiveFrontEnd.actionCounts;
        adaptivePathBob(:, im) = bobRes.adaptiveFrontEnd.pathCounts;
        adaptiveConfidenceBob(im) = bobRes.adaptiveFrontEnd.confidenceSum;
        adaptiveDecisionBob(im) = bobRes.adaptiveFrontEnd.decisionCount;

        if eveEnabled
            nErrEve(im) = eveRes.nErr;
            nTotEve(im) = eveRes.nTot;
            frontEndEve(im) = mean(double(eveNom.frontEndOk));
            headerEve(im) = mean(double(eveNom.headerOk));
            mseCommEve(im) = eveRes.mseComm;
            psnrCommEve(im) = eveRes.psnrComm;
            ssimCommEve(im) = eveRes.ssimComm;
            mseCompEve(im) = eveRes.mseComp;
            psnrCompEve(im) = eveRes.psnrComp;
            ssimCompEve(im) = eveRes.ssimComp;
            packetSuccessEve(im) = eveRes.packetSuccessRate;
            rawPacketSuccessEve(im) = eveRes.rawPacketSuccessRate;
            exampleEve{im} = eveRes.example;
        end
    end
end

bobFrame = struct();
bobFrame.nErr = nErrBob;
bobFrame.nTot = nTotBob;
bobFrame.frontEndSuccessRate = frontEndBob;
bobFrame.headerSuccessRate = headerBob;
bobFrame.packetSuccessRate = packetSuccessBob;
bobFrame.rawPacketSuccessRate = rawPacketSuccessBob;
bobFrame.metricsComm = struct("mse", mseCommBob, "psnr", psnrCommBob, "ssim", ssimCommBob);
bobFrame.metricsComp = struct("mse", mseCompBob, "psnr", psnrCompBob, "ssim", ssimCompBob);
bobFrame.adaptiveFrontEnd = struct( ...
    "classNames", adaptiveDiagCfg.classNames, ...
    "actionNames", adaptiveDiagCfg.actionNames, ...
    "bootstrapPaths", adaptiveDiagCfg.bootstrapPaths, ...
    "classCounts", adaptiveClassBob, ...
    "actionCounts", adaptiveActionBob, ...
    "pathCounts", adaptivePathBob, ...
    "confidenceSum", adaptiveConfidenceBob, ...
    "decisionCount", adaptiveDecisionBob);
bobFrame.example = exampleBob;

eveFrame = struct();
if eveEnabled
    eveFrame.nErr = nErrEve;
    eveFrame.nTot = nTotEve;
    eveFrame.frontEndSuccessRate = frontEndEve;
    eveFrame.headerSuccessRate = headerEve;
    eveFrame.packetSuccessRate = packetSuccessEve;
    eveFrame.rawPacketSuccessRate = rawPacketSuccessEve;
    eveFrame.metricsComm = struct("mse", mseCommEve, "psnr", psnrCommEve, "ssim", ssimCommEve);
    eveFrame.metricsComp = struct("mse", mseCompEve, "psnr", psnrCompEve, "ssim", ssimCompEve);
    eveFrame.example = exampleEve;
end
end

function [bobRes, eveRes] = local_decode_single_method_local( ...
    methodName, txPackets, txPktIndex, txPayloadBits, sessionFrames, bobNom, eveNom, p, fhEnabled, ...
    packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
    packetConcealActive, packetConcealMode, imgTx, metaTx, totalPayloadBitsTx, ...
    bobRxSync, bobMitigation, eveRxSync, eveMitigation, ...
    eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosApproxDeltaEve, chaosEncInfoEve, ...
    captureExample, EbN0dB, EbN0dBEve, nPackets)

outerRsCfgBob = resolve_outer_rs_cfg(p);
outerRsCfgEve = resolve_outer_rs_cfg(p);
if packetIndependentBitChaos && chaosEnabled && chaosAssumptionEve ~= "known"
    outerRsCfgEve.enable = false;
end

% -------- Bob --------
sessionBob = local_init_rx_session_local(p, metaTx, nPackets);
packetPayloadBob = cell(nPackets, 1);
packetOkBobTx = false(1, nPackets);
nErrBob = 0;
nTotBob = 0;
calStateBob = local_init_threshold_calibration_state_local(methodName, bobMitigation);
[sessionBob, calStateBob] = local_recover_session_from_nominal_local( ...
    sessionBob, bobNom.session, sessionFrames, methodName, bobMitigation, p, calStateBob);

for pktIdx = 1:nPackets
    txPayload = txPayloadBits{pktIdx};
    if bobNom.ok(pktIdx)
        phy = bobNom.phy(pktIdx);
        rxState = bobNom.rxState{pktIdx};
        if isempty(rxState)
            rxState = derive_rx_packet_state_local( ...
                p, double(phy.packetIndex), local_packet_data_bits_len_from_header_local(p, double(phy.packetIndex), phy));
        end
        rData = fit_complex_length_local(bobNom.rDataPrepared{pktIdx}, local_rx_demod_symbol_count_local(rxState));
        reliability = [];
        if isfield(bobNom, "rDataReliability") && numel(bobNom.rDataReliability) >= pktIdx ...
                && ~isempty(bobNom.rDataReliability{pktIdx})
            reliability = local_fit_reliability_length_local(bobNom.rDataReliability{pktIdx}, local_rx_demod_symbol_count_local(rxState));
        end

        demodSoft = demodulate_to_softbits(rData, p.mod, p.fec, p.softMetric, reliability);
        demodDeint = deinterleave_bits(demodSoft, rxState.intState, p.interleaver);
        dataBitsRxScr = fec_decode(demodDeint, p.fec);
        packetDataBitsRx = descramble_bits(dataBitsRxScr, rxState.scrambleCfg);
        packetDataBitsRx = fit_bits_length(packetDataBitsRx, rxState.packetDataBitsLen);

        [payloadPktRx, sessionNext, packetInfo, okPacket] = recover_payload_packet_local(packetDataBitsRx, phy, sessionBob, p);
        if okPacket && packetInfo.packetIndex == txPktIndex(pktIdx)
            sessionBob = sessionNext;
            payloadPktBob = local_prepare_plain_packet_payload_local( ...
                payloadPktRx, txPktIndex(pktIdx), packetIndependentBitChaos, chaosEnabled, ...
                p.chaosEncrypt, "known", 0);
            txBits = txPayload;
            nCompare = min(numel(payloadPktBob), numel(txBits));
            if nCompare > 0
                nErrBob = nErrBob + sum(payloadPktBob(1:nCompare) ~= txBits(1:nCompare));
            end
            if numel(payloadPktBob) < numel(txBits)
                nErrBob = nErrBob + (numel(txBits) - numel(payloadPktBob));
            end
            nTotBob = nTotBob + numel(txBits);
            packetPayloadBob{pktIdx} = payloadPktBob;
            packetOkBobTx(pktIdx) = true;
        else
            nErrBob = nErrBob + numel(txPayload);
            nTotBob = nTotBob + numel(txPayload);
        end
    else
        nErrBob = nErrBob + numel(txPayload);
        nTotBob = nTotBob + numel(txPayload);
    end
end

[payloadFrameBob, packetOkBob, outerRsInfoBob] = outer_rs_recover_payload( ...
    packetPayloadBob, packetOkBobTx, txPackets, totalPayloadBitsTx, nominal_payload_bits_local(p), outerRsCfgBob);

metaBobUse = metaTx;
totalPayloadBitsBob = totalPayloadBitsTx;
if isfield(sessionBob, "known") && sessionBob.known
    metaBobUse = sessionBob.meta;
    totalPayloadBitsBob = sessionBob.totalPayloadBits;
end
rxLayoutBob = derive_packet_layout_local(totalPayloadBitsBob, p);

if packetIndependentBitChaos && chaosEnabled
    imgRxComm = payload_bits_to_image(payloadFrameBob, metaBobUse, p.payload);
elseif chaosEnabled && isfield(chaosEncInfo, "enabled") && chaosEncInfo.enabled
    if isfield(chaosEncInfo, "mode") && lower(string(chaosEncInfo.mode)) == "payload_bits"
        payloadBitsRxDec = chaos_decrypt_bits(payloadFrameBob, chaosEncInfo);
        imgRxComm = payload_bits_to_image(payloadBitsRxDec, metaBobUse, p.payload);
    else
        imgRxEnc = payload_bits_to_image(payloadFrameBob, metaBobUse, p.payload);
        imgRxComm = chaos_decrypt(imgRxEnc, chaosEncInfo);
    end
else
    imgRxComm = payload_bits_to_image(payloadFrameBob, metaBobUse, p.payload);
end

imgRxComp = imgRxComm;
if packetConcealActive
    imgRxComp = conceal_image_from_packets(imgRxComp, packetOkBob, rxLayoutBob, metaBobUse, p.payload, packetConcealMode);
end

[psnrNowComm, ssimNowComm, mseNowComm] = image_quality(imgTx, imgRxComm);
[psnrNowComp, ssimNowComp, mseNowComp] = image_quality(imgTx, imgRxComp);

bobRes = struct();
bobRes.nErr = nErrBob;
bobRes.nTot = nTotBob;
bobRes.mseComm = mseNowComm;
bobRes.psnrComm = psnrNowComm;
bobRes.ssimComm = ssimNowComm;
bobRes.mseComp = mseNowComp;
bobRes.psnrComp = psnrNowComp;
bobRes.ssimComp = ssimNowComp;
bobRes.packetSuccessRate = mean(packetOkBob);
bobRes.rawPacketSuccessRate = outerRsInfoBob.rawDataPacketSuccessRate;
bobRes.outerRs = outerRsInfoBob;
bobRes.adaptiveFrontEnd = local_collect_adaptive_frontend_summary_local(bobNom, bobMitigation);
bobRes.thresholdCalibration = local_pack_threshold_calibration_state_local(calStateBob);
bobRes.example = [];
if captureExample
    bobRes.example = struct();
    bobRes.example.EbN0dB = EbN0dB;
    bobRes.example.frontEndSuccessRate = mean(double(bobNom.frontEndOk));
    bobRes.example.headerSuccessRate = mean(double(bobNom.headerOk));
    bobRes.example.sessionKnown = logical(sessionBob.known);
    bobRes.example.sessionFrameFrontEndSuccessRate = local_nominal_success_rate_local(bobNom.session);
    bobRes.example.imgRxComm = imgRxComm;
    bobRes.example.imgRxCompensated = imgRxComp;
    bobRes.example.imgRx = imgRxComp;
    bobRes.example.packetSuccessRate = bobRes.packetSuccessRate;
    bobRes.example.rawPacketSuccessRate = bobRes.rawPacketSuccessRate;
    bobRes.example.headerOk = all(bobNom.headerOk);
    bobRes.example.adaptiveFrontEnd = bobRes.adaptiveFrontEnd;
    bobRes.example.thresholdCalibration = bobRes.thresholdCalibration;
    bobRes.example.outerRs = outerRsInfoBob;
end

% -------- Eve --------
eveRes = struct();
if ~eveEnabled
    return;
end

sessionEve = local_init_rx_session_local(p, metaTx, nPackets);
packetPayloadEve = cell(nPackets, 1);
packetOkEveTx = false(1, nPackets);
nErrEve = 0;
nTotEve = 0;
calStateEve = local_init_threshold_calibration_state_local(methodName, eveMitigation);
[sessionEve, calStateEve] = local_recover_session_from_nominal_local( ...
    sessionEve, eveNom.session, sessionFrames, methodName, eveMitigation, p, calStateEve);

for pktIdx = 1:nPackets
    txPayload = txPayloadBits{pktIdx};
    if eveNom.ok(pktIdx)
        phy = eveNom.phy(pktIdx);
        rxState = eveNom.rxState{pktIdx};
        if isempty(rxState)
            rxState = derive_rx_packet_state_local( ...
                p, double(phy.packetIndex), local_packet_data_bits_len_from_header_local(p, double(phy.packetIndex), phy));
        end
        rData = fit_complex_length_local(eveNom.rDataPrepared{pktIdx}, local_rx_demod_symbol_count_local(rxState));
        reliabilityEve = [];
        if isfield(eveNom, "rDataReliability") && numel(eveNom.rDataReliability) >= pktIdx ...
                && ~isempty(eveNom.rDataReliability{pktIdx})
            reliabilityEve = local_fit_reliability_length_local(eveNom.rDataReliability{pktIdx}, local_rx_demod_symbol_count_local(rxState));
        end
        scrambleCfgEve = eve_scramble_cfg_local(rxState.scrambleCfg, scrambleAssumptionEve);

        demodSoftEve = demodulate_to_softbits(rData, p.mod, p.fec, p.softMetric, reliabilityEve);
        demodDeintEve = deinterleave_bits(demodSoftEve, rxState.intState, p.interleaver);
        dataBitsEveScr = fec_decode(demodDeintEve, p.fec);
        packetDataBitsEve = descramble_bits(dataBitsEveScr, scrambleCfgEve);
        packetDataBitsEve = fit_bits_length(packetDataBitsEve, rxState.packetDataBitsLen);

        [payloadPktEve, sessionNext, packetInfo, okPacket] = recover_payload_packet_local(packetDataBitsEve, phy, sessionEve, p);
        if okPacket && packetInfo.packetIndex == txPktIndex(pktIdx)
            sessionEve = sessionNext;
            payloadPktEve = local_prepare_plain_packet_payload_local( ...
                payloadPktEve, txPktIndex(pktIdx), packetIndependentBitChaos, chaosEnabled, ...
                p.chaosEncrypt, chaosAssumptionEve, chaosApproxDeltaEve);
            txBits = txPayload;
            nCompare = min(numel(payloadPktEve), numel(txBits));
            if nCompare > 0
                nErrEve = nErrEve + sum(payloadPktEve(1:nCompare) ~= txBits(1:nCompare));
            end
            if numel(payloadPktEve) < numel(txBits)
                nErrEve = nErrEve + (numel(txBits) - numel(payloadPktEve));
            end
            nTotEve = nTotEve + numel(txBits);
            packetPayloadEve{pktIdx} = payloadPktEve;
            packetOkEveTx(pktIdx) = true;
        else
            nErrEve = nErrEve + numel(txPayload);
            nTotEve = nTotEve + numel(txPayload);
        end
    else
        nErrEve = nErrEve + numel(txPayload);
        nTotEve = nTotEve + numel(txPayload);
    end
end

[payloadFrameEve, packetOkEve, outerRsInfoEve] = outer_rs_recover_payload( ...
    packetPayloadEve, packetOkEveTx, txPackets, totalPayloadBitsTx, nominal_payload_bits_local(p), outerRsCfgEve);

metaEveUse = metaTx;
totalPayloadBitsEve = totalPayloadBitsTx;
if isfield(sessionEve, "known") && sessionEve.known
    metaEveUse = sessionEve.meta;
    totalPayloadBitsEve = sessionEve.totalPayloadBits;
end
rxLayoutEve = derive_packet_layout_local(totalPayloadBitsEve, p);

if packetIndependentBitChaos && chaosEnabled
    imgEveComm = payload_bits_to_image(payloadFrameEve, metaEveUse, p.payload);
elseif chaosEnabled && isfield(chaosEncInfoEve, "enabled") && chaosEncInfoEve.enabled
    if isfield(chaosEncInfoEve, "mode") && lower(string(chaosEncInfoEve.mode)) == "payload_bits"
        payloadBitsEveDec = chaos_decrypt_bits(payloadFrameEve, chaosEncInfoEve);
        imgEveComm = payload_bits_to_image(payloadBitsEveDec, metaEveUse, p.payload);
    else
        imgEveEnc = payload_bits_to_image(payloadFrameEve, metaEveUse, p.payload);
        imgEveComm = chaos_decrypt(imgEveEnc, chaosEncInfoEve);
    end
else
    imgEveComm = payload_bits_to_image(payloadFrameEve, metaEveUse, p.payload);
end

imgEveComp = imgEveComm;
if packetConcealActive
    imgEveComp = conceal_image_from_packets(imgEveComp, packetOkEve, rxLayoutEve, metaEveUse, p.payload, packetConcealMode);
end

[psnrNowCommEve, ssimNowCommEve, mseNowCommEve] = image_quality(imgTx, imgEveComm);
[psnrNowCompEve, ssimNowCompEve, mseNowCompEve] = image_quality(imgTx, imgEveComp);

eveRes.nErr = nErrEve;
eveRes.nTot = nTotEve;
eveRes.mseComm = mseNowCommEve;
eveRes.psnrComm = psnrNowCommEve;
eveRes.ssimComm = ssimNowCommEve;
eveRes.mseComp = mseNowCompEve;
eveRes.psnrComp = psnrNowCompEve;
eveRes.ssimComp = ssimNowCompEve;
eveRes.packetSuccessRate = mean(packetOkEve);
eveRes.rawPacketSuccessRate = outerRsInfoEve.rawDataPacketSuccessRate;
eveRes.outerRs = outerRsInfoEve;
eveRes.adaptiveFrontEnd = local_collect_adaptive_frontend_summary_local(eveNom, eveMitigation);
eveRes.thresholdCalibration = local_pack_threshold_calibration_state_local(calStateEve);
eveRes.example = [];
if captureExample
    eveRes.example = struct();
    eveRes.example.EbN0dB = EbN0dBEve;
    eveRes.example.frontEndSuccessRate = mean(double(eveNom.frontEndOk));
    eveRes.example.headerSuccessRate = mean(double(eveNom.headerOk));
    eveRes.example.sessionKnown = logical(sessionEve.known);
    eveRes.example.sessionFrameFrontEndSuccessRate = local_nominal_success_rate_local(eveNom.session);
    eveRes.example.packetSuccessRate = eveRes.packetSuccessRate;
    eveRes.example.rawPacketSuccessRate = eveRes.rawPacketSuccessRate;
    eveRes.example.imgRxComm = imgEveComm;
    eveRes.example.imgRxCompensated = imgEveComp;
    eveRes.example.imgRx = imgEveComp;
    eveRes.example.headerOk = all(eveNom.headerOk);
    eveRes.example.thresholdCalibration = eveRes.thresholdCalibration;
    eveRes.example.outerRs = outerRsInfoEve;
end
end

function state = local_init_threshold_calibration_state_local(methodName, mitigation)
state = struct( ...
    "enabled", false, ...
    "methodName", string(methodName), ...
    "modelKind", "", ...
    "model", struct(), ...
    "threshold", NaN, ...
    "baseThreshold", NaN, ...
    "minThreshold", NaN, ...
    "maxThreshold", NaN, ...
    "targetCleanPfa", NaN, ...
    "bufferMaxSamples", 0, ...
    "minBufferSamples", 0, ...
    "minPreambleTrustedSamples", 0, ...
    "minPacketTrustedSamples", 0, ...
    "preambleUpdateAlpha", 0, ...
    "packetUpdateAlpha", 0, ...
    "preambleResidualAlpha", 0, ...
    "packetResidualAlpha", 0, ...
    "scoreBuffer", zeros(0, 1), ...
    "preambleUpdates", 0, ...
    "packetUpdates", 0, ...
    "lastCandidateThreshold", NaN, ...
    "lastSource", "");

if ~isfield(mitigation, "thresholdCalibration") || ~isstruct(mitigation.thresholdCalibration)
    return;
end
cfg = mitigation.thresholdCalibration;
if ~(isfield(cfg, "enable") && logical(cfg.enable))
    return;
end

supportedMethods = ["ml_blanking" "ml_cnn" "ml_gru" "ml_cnn_hard" "ml_gru_hard"];
if isfield(cfg, "methods") && ~isempty(cfg.methods)
    supportedMethods = lower(string(cfg.methods(:).'));
end
methodName = lower(string(methodName));
if ~any(methodName == supportedMethods)
    return;
end

[model, modelKind] = local_threshold_calibration_model_local(methodName, mitigation);
baseThreshold = local_scalar_threshold_local(model.threshold);
targetCleanPfa = local_get_required_numeric_local(cfg, "targetCleanPfa");
if ~(targetCleanPfa > 0 && targetCleanPfa < 1)
    error("mitigation.thresholdCalibration.targetCleanPfa 必须在 (0,1) 内。");
end

minThreshold = max(local_get_required_numeric_local(cfg, "minThresholdAbs"), ...
    local_get_required_numeric_local(cfg, "thresholdMinScale") * baseThreshold);
maxThreshold = min(local_get_required_numeric_local(cfg, "maxThresholdAbs"), ...
    local_get_required_numeric_local(cfg, "thresholdMaxScale") * baseThreshold);
if ~(minThreshold < maxThreshold)
    error("在线阈值校准上下界无效：minThreshold=%.4f, maxThreshold=%.4f。", minThreshold, maxThreshold);
end

state.enabled = true;
state.methodName = methodName;
state.modelKind = modelKind;
state.model = model;
state.threshold = min(max(baseThreshold, minThreshold), maxThreshold);
state.baseThreshold = baseThreshold;
state.minThreshold = minThreshold;
state.maxThreshold = maxThreshold;
state.targetCleanPfa = targetCleanPfa;
state.bufferMaxSamples = local_get_required_integer_local(cfg, "bufferMaxSamples");
state.minBufferSamples = local_get_required_integer_local(cfg, "minBufferSamples");
state.minPreambleTrustedSamples = local_get_required_integer_local(cfg, "minPreambleTrustedSamples");
state.minPacketTrustedSamples = local_get_required_integer_local(cfg, "minPacketTrustedSamples");
state.preambleUpdateAlpha = local_get_required_numeric_local(cfg, "preambleUpdateAlpha");
state.packetUpdateAlpha = local_get_required_numeric_local(cfg, "packetUpdateAlpha");
state.preambleResidualAlpha = local_get_required_numeric_local(cfg, "preambleResidualAlpha");
state.packetResidualAlpha = local_get_required_numeric_local(cfg, "packetResidualAlpha");
end

function mitigationOut = local_apply_threshold_calibration_local(mitigationIn, state)
mitigationOut = mitigationIn;
if ~(isstruct(state) && isfield(state, "enabled") && state.enabled)
    return;
end

switch state.modelKind
    case "lr"
        mitigationOut.ml.threshold = state.threshold;
    case "cnn"
        mitigationOut.mlCnn.threshold = state.threshold;
    case "gru"
        mitigationOut.mlGru.threshold = state.threshold;
    otherwise
        error("未知的阈值校准模型类型: %s", state.modelKind);
end
end

function state = local_update_threshold_from_preamble_local(state, rxPre, refPre)
if ~(isstruct(state) && isfield(state, "enabled") && state.enabled)
    return;
end
scores = local_ml_score_vector_local(state, rxPre);
trusted = local_reference_trust_mask_local(rxPre, refPre, state.preambleResidualAlpha, state.minPreambleTrustedSamples);
state = local_absorb_clean_scores_local(state, scores(trusted), state.preambleUpdateAlpha, "preamble");
end

function state = local_update_threshold_from_packet_local(state, rxData, packetDataBits, scrambleCfg, rxState, p)
if ~(isstruct(state) && isfield(state, "enabled") && state.enabled)
    return;
end
refSym = local_reencode_packet_symbols_local(packetDataBits, scrambleCfg, rxState, p);
scores = local_ml_score_vector_local(state, rxData);
trusted = local_reference_trust_mask_local(rxData, refSym, state.packetResidualAlpha, state.minPacketTrustedSamples);
state = local_absorb_clean_scores_local(state, scores(trusted), state.packetUpdateAlpha, "packet");
end

function summary = local_pack_threshold_calibration_state_local(state)
summary = struct( ...
    "enabled", false, ...
    "methodName", string(state.methodName), ...
    "modelKind", "", ...
    "baseThreshold", NaN, ...
    "finalThreshold", NaN, ...
    "minThreshold", NaN, ...
    "maxThreshold", NaN, ...
    "bufferedSamples", 0, ...
    "preambleUpdates", 0, ...
    "packetUpdates", 0, ...
    "lastCandidateThreshold", NaN, ...
    "lastSource", "");
if ~(isstruct(state) && isfield(state, "enabled") && state.enabled)
    return;
end
summary.enabled = true;
summary.methodName = string(state.methodName);
summary.modelKind = string(state.modelKind);
summary.baseThreshold = state.baseThreshold;
summary.finalThreshold = state.threshold;
summary.minThreshold = state.minThreshold;
summary.maxThreshold = state.maxThreshold;
summary.bufferedSamples = numel(state.scoreBuffer);
summary.preambleUpdates = state.preambleUpdates;
summary.packetUpdates = state.packetUpdates;
summary.lastCandidateThreshold = state.lastCandidateThreshold;
summary.lastSource = string(state.lastSource);
end

function [model, modelKind] = local_threshold_calibration_model_local(methodName, mitigation)
methodName = lower(string(methodName));
switch methodName
    case "ml_blanking"
        model = mitigation.ml;
        modelKind = "lr";
    case {"ml_cnn", "ml_cnn_hard"}
        model = mitigation.mlCnn;
        modelKind = "cnn";
    case {"ml_gru", "ml_gru_hard"}
        model = mitigation.mlGru;
        modelKind = "gru";
    otherwise
        error("方法 %s 不支持在线阈值校准。", methodName);
end
end

function scores = local_ml_score_vector_local(state, r)
r = r(:);
if isempty(r)
    scores = zeros(0, 1);
    return;
end

switch state.modelKind
    case "lr"
        model = state.model;
        model.threshold = state.threshold;
        [~, scores] = ml_impulse_detect(r, model);
    case "cnn"
        model = state.model;
        model.threshold = state.threshold;
        [~, ~, ~, scores] = ml_cnn_impulse_detect(r, model);
    case "gru"
        model = state.model;
        model.threshold = state.threshold;
        [~, ~, ~, scores] = ml_gru_impulse_detect(r, model);
    otherwise
        error("未知的阈值校准模型类型: %s", state.modelKind);
end

scores = double(gather(scores(:)));
scores = max(min(scores, 1), 0);
end

function state = local_absorb_clean_scores_local(state, scoresTrusted, updateAlpha, sourceName)
scoresTrusted = double(scoresTrusted(:));
scoresTrusted = scoresTrusted(isfinite(scoresTrusted));
scoresTrusted = max(min(scoresTrusted, 1), 0);
if isempty(scoresTrusted)
    return;
end

state.scoreBuffer = [state.scoreBuffer; scoresTrusted];
if numel(state.scoreBuffer) > state.bufferMaxSamples
    state.scoreBuffer = state.scoreBuffer(end - state.bufferMaxSamples + 1:end);
end
if numel(state.scoreBuffer) < state.minBufferSamples
    return;
end

candidate = local_quantile_local(state.scoreBuffer, 1 - state.targetCleanPfa);
candidate = min(max(candidate, state.minThreshold), state.maxThreshold);
state.threshold = min(max((1 - updateAlpha) * state.threshold + updateAlpha * candidate, ...
    state.minThreshold), state.maxThreshold);
state.lastCandidateThreshold = candidate;
state.lastSource = string(sourceName);
switch lower(string(sourceName))
    case "preamble"
        state.preambleUpdates = state.preambleUpdates + 1;
    case "packet"
        state.packetUpdates = state.packetUpdates + 1;
    otherwise
        error("未知的阈值校准来源: %s", string(sourceName));
end
end

function trusted = local_reference_trust_mask_local(rx, ref, residualAlpha, minTrustedSamples)
rx = rx(:);
ref = ref(:);
n = min(numel(rx), numel(ref));
trusted = false(n, 1);
if n <= 0
    return;
end
rx = rx(1:n);
ref = ref(1:n);
den = sum(abs(ref).^2);
if den > eps
    hHat = (ref' * rx) / den;
else
    hHat = 1;
end
refAligned = hHat * ref;
residual = abs(rx - refAligned);
medResidual = median(residual);
residualMad = median(abs(residual - medResidual));
thr = medResidual + residualAlpha * max(residualMad, 1e-8);
trusted = residual <= thr;
if nnz(trusted) < minTrustedSamples && n >= minTrustedSamples
    [~, order] = sort(residual, "ascend");
    trusted(order(1:minTrustedSamples)) = true;
end
end

function refSym = local_reencode_packet_symbols_local(packetDataBits, scrambleCfg, rxState, p)
packetDataBits = uint8(packetDataBits(:) ~= 0);
bitsScr = scramble_bits(packetDataBits, scrambleCfg);
codedBits = fec_encode(bitsScr, p.fec);
[codedBitsInt, ~] = interleave_bits(codedBits, p.interleaver);
[refSym, ~] = modulate_bits(codedBitsInt, p.mod, p.fec);
refSym = fit_complex_length_local(refSym, local_rx_demod_symbol_count_local(rxState));
end

function value = local_scalar_threshold_local(rawValue)
rawValue = double(gather(rawValue));
if isempty(rawValue) || ~isfinite(rawValue(1))
    error("模型threshold无效，无法初始化在线阈值校准。");
end
value = rawValue(1);
if value < 0 || value > 1
    error("模型threshold=%.4f 超出 [0,1] 范围。", value);
end
end

function value = local_get_required_numeric_local(s, fieldName)
if ~isfield(s, fieldName) || isempty(s.(fieldName))
    error("配置缺少字段: %s。", fieldName);
end
value = double(s.(fieldName));
if ~isscalar(value) || ~isfinite(value)
    error("配置字段 %s 必须是有限标量。", fieldName);
end
end

function value = local_get_required_integer_local(s, fieldName)
value = local_get_required_numeric_local(s, fieldName);
if abs(value - round(value)) > 1e-12 || value < 1
    error("配置字段 %s 必须是正整数。", fieldName);
end
value = round(value);
end

function q = local_quantile_local(x, qLevel)
x = sort(double(x(:)));
if isempty(x)
    q = NaN;
    return;
end
qLevel = min(max(double(qLevel), 0), 1);
if numel(x) == 1
    q = x;
    return;
end
pos = 1 + (numel(x) - 1) * qLevel;
lo = floor(pos);
hi = ceil(pos);
if lo == hi
    q = x(lo);
else
    w = pos - lo;
    q = (1 - w) * x(lo) + w * x(hi);
end
end

function tf = local_has_parallel_pool_local()
tf = false;
if exist("gcp", "file") ~= 2
    return;
end
try
    tf = ~isempty(gcp("nocreate"));
catch
    tf = false;
end
end

function tf = local_multipath_eq_enabled_local(channelCfg, rxSyncCfg)
tf = false;
if ~isstruct(rxSyncCfg) || ~isfield(rxSyncCfg, "multipathEq") ...
        || ~isstruct(rxSyncCfg.multipathEq) || ~isfield(rxSyncCfg.multipathEq, "enable") || ~rxSyncCfg.multipathEq.enable
    return;
end
if ~isstruct(channelCfg) || ~isfield(channelCfg, "multipath") || ~isstruct(channelCfg.multipath) ...
        || ~isfield(channelCfg.multipath, "enable") || ~channelCfg.multipath.enable
    return;
end
tf = true;
end

function Lh = local_multipath_channel_len_symbols_local(channelCfg, waveform)
Lh = 1;
if ~isfield(channelCfg, "multipath") || ~isstruct(channelCfg.multipath) ...
        || ~isfield(channelCfg.multipath, "enable") || ~channelCfg.multipath.enable
    return;
end

if isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)
    dly = double(channelCfg.multipath.pathDelaysSymbols(:));
    if ~isempty(dly)
        Lh = max(1, round(max(dly)) + 1);
    end
    return;
end

if isfield(channelCfg.multipath, "pathDelays") && ~isempty(channelCfg.multipath.pathDelays)
    dlySamp = double(channelCfg.multipath.pathDelays(:));
    if isempty(dlySamp)
        Lh = 1;
        return;
    end
    if isstruct(waveform) && isfield(waveform, "sps") && waveform.sps > 0
        dlySym = dlySamp / double(waveform.sps);
        Lh = max(1, round(max(dlySym)) + 1);
    else
        Lh = max(1, round(max(dlySamp)) + 1);
    end
end
end

function yEq = local_apply_equalizer_block_local(y, eq)
y = y(:);
if isempty(y)
    yEq = y;
    return;
end
if ~isstruct(eq) || ~isfield(eq, "enabled") || ~eq.enabled || ~isfield(eq, "g") || isempty(eq.g)
    yEq = y;
    return;
end

d = 0;
if isfield(eq, "delay") && ~isempty(eq.delay)
    d = max(0, round(double(eq.delay)));
end
g = eq.g(:);
N = numel(y);

% Pad zeros so the delay-compensated slice exists.
z = conv([y; zeros(d, 1)], g);
needLen = d + N;
if numel(z) < needLen
    z = [z; complex(zeros(needLen - numel(z), 1))];
end
yEq = z(d+1:d+N);
end

function [yPrep, relPrep] = local_prepare_data_symbols_local(rData, rawReliability, rxState, hopInfoUsed, modCfg, rxSyncCfg, fhEnabled, actionName, mitigation)
% Prepare per-packet data symbols (dehop -> targeted mitigation -> carrier PLL).
%
% Multipath equalization has already been applied on the full [preamble; PHY; data]
% block. Here we only process the payload region.
r = fit_complex_length_local(rData, rxState.nDataSym);
rawReliability = local_fit_reliability_length_local(rawReliability, rxState.nDataSym);

if fhEnabled
    r = fh_demodulate(r, hopInfoUsed);
end

[r, relPrep] = local_apply_data_action_local(r, actionName, mitigation, hopInfoUsed, fhEnabled);
relPrep = local_fit_reliability_length_local(relPrep, rxState.nDataSym);
if all(relPrep >= 0.999999)
    relPrep = rawReliability;
else
    relPrep = min(relPrep, rawReliability);
end

if isfield(rxState, "dsssCfg") && isstruct(rxState.dsssCfg)
    [r, relPrep] = dsss_despread(r, rxState.dsssCfg, relPrep);
end

if isfield(rxSyncCfg, "carrierPll") && isfield(rxSyncCfg.carrierPll, "enable") ...
        && rxSyncCfg.carrierPll.enable
    r = carrier_pll_sync(r, modCfg, rxSyncCfg.carrierPll);
end

yPrep = r;
relPrep = local_fit_reliability_length_local(relPrep, local_rx_demod_symbol_count_local(rxState));
end

function [rOut, reliability] = local_apply_data_action_local(rIn, actionName, mitigation, hopInfoUsed, fhEnabled)
r = rIn(:);
actionName = string(actionName);
reliability = ones(numel(r), 1);
if actionName == "none"
    rOut = r;
    return;
end

if local_action_prefers_per_hop_local(actionName) && fhEnabled ...
        && isstruct(hopInfoUsed) && isfield(hopInfoUsed, "enable") && hopInfoUsed.enable ...
        && isfield(hopInfoUsed, "hopLen") && double(hopInfoUsed.hopLen) > 0
    [rOut, reliability] = local_apply_action_per_hop_local(r, actionName, mitigation, round(double(hopInfoUsed.hopLen)));
    return;
end

[rOut, reliability] = mitigate_impulses(r, actionName, mitigation);
end

function [rOut, reliability] = local_apply_action_per_hop_local(rIn, actionName, mitigation, hopLen)
r = rIn(:);
hopLen = max(1, round(double(hopLen)));
rOut = complex(zeros(size(r)));
reliability = zeros(numel(r), 1);

for startIdx = 1:hopLen:numel(r)
    stopIdx = min(numel(r), startIdx + hopLen - 1);
    [segOut, segRel] = mitigate_impulses(r(startIdx:stopIdx), actionName, mitigation);
    rOut(startIdx:stopIdx) = segOut;
    reliability(startIdx:stopIdx) = local_fit_reliability_length_local(segRel, stopIdx - startIdx + 1);
end
end

function tf = local_action_prefers_per_hop_local(actionName)
actionName = lower(string(actionName));
tf = any(actionName == ["fft_notch" "fft_bandstop" "adaptive_notch" "stft_notch" "ml_narrowband"]);
end

function relPrep = local_fit_reliability_length_local(reliability, targetLen)
reliability = double(reliability(:));
reliability(~isfinite(reliability)) = 0;
reliability = max(min(reliability, 1), 0);
targetLen = max(0, round(double(targetLen)));
if numel(reliability) >= targetLen
    relPrep = reliability(1:targetLen);
else
    relPrep = [reliability; ones(targetLen - numel(reliability), 1)];
end
end

function relBlk = local_extract_reliability_block_local(reliability, startPos, nSamp)
reliability = double(reliability(:));
if nSamp <= 0 || isempty(reliability)
    relBlk = zeros(0, 1);
    return;
end
idx = (1:numel(reliability)).';
t = startPos + (0:nSamp-1).';
relBlk = interp1(idx, reliability, t, "linear", 0);
relBlk(~isfinite(relBlk)) = 0;
relBlk = max(min(relBlk, 1), 0);
end

function front = local_capture_synced_block_local(rxSampleRaw, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg)
if nargin < 9
    bootstrapChain = strings(1, 0);
end
if nargin < 10 || isempty(fhCaptureCfg)
    fhCaptureCfg = struct("enable", false);
end
front = capture_synced_block_from_samples( ...
    rxSampleRaw, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg);
end

function fhCaptureCfg = local_packet_fast_fh_capture_cfg_local(txPacket, fhAssumption)
fhCaptureCfg = struct("enable", false);
if nargin < 2 || strlength(string(fhAssumption)) == 0
    fhAssumption = "known";
end

headerFhCfg = struct("enable", false);
if isfield(txPacket, "phyHeaderFhCfg") && isstruct(txPacket.phyHeaderFhCfg)
    headerFhCfg = local_assumed_packet_fh_cfg_local(txPacket.phyHeaderFhCfg, fhAssumption);
end

dataFhCfg = struct("enable", false);
if isfield(txPacket, "fhCfg") && isstruct(txPacket.fhCfg)
    dataFhCfg = local_assumed_packet_fh_cfg_local(txPacket.fhCfg, fhAssumption);
end

headerFast = isfield(headerFhCfg, "enable") && headerFhCfg.enable && fh_is_fast(headerFhCfg);
dataFast = isfield(dataFhCfg, "enable") && dataFhCfg.enable && fh_is_fast(dataFhCfg);
if ~(headerFast || dataFast)
    return;
end

fhCaptureCfg = struct( ...
    "enable", true, ...
    "syncSymbols", double(numel(txPacket.syncSym)), ...
    "headerSymbols", double(numel(txPacket.phyHeaderSym)), ...
    "headerFhCfg", headerFhCfg, ...
    "dataFhCfg", dataFhCfg);
end

function fhCaptureCfg = local_session_fast_fh_capture_cfg_local(sessionFrame, fhAssumption)
fhCaptureCfg = struct("enable", false);
if nargin < 2 || strlength(string(fhAssumption)) == 0
    fhAssumption = "known";
end

dataFhCfg = struct("enable", false);
if isfield(sessionFrame, "fhCfg") && isstruct(sessionFrame.fhCfg)
    dataFhCfg = local_assumed_packet_fh_cfg_local(sessionFrame.fhCfg, fhAssumption);
end

if ~(isfield(dataFhCfg, "enable") && dataFhCfg.enable && fh_is_fast(dataFhCfg))
    return;
end

fhCaptureCfg = struct( ...
    "enable", true, ...
    "syncSymbols", double(numel(sessionFrame.syncSym)), ...
    "headerSymbols", 0, ...
    "headerFhCfg", struct("enable", false), ...
    "dataFhCfg", dataFhCfg);
end

function fhCfgOut = local_assumed_packet_fh_cfg_local(fhCfgIn, assumption)
fhCfgOut = fhCfgIn;
if ~(isstruct(fhCfgOut) && isfield(fhCfgOut, "enable") && fhCfgOut.enable)
    fhCfgOut = struct("enable", false);
    return;
end

switch lower(string(assumption))
    case "known"
        return;
    case "none"
        fhCfgOut.enable = false;
    case "partial"
        fhCfgOut = make_partial_fh_config(fhCfgOut);
    otherwise
        error("Unknown fast-FH assumption: %s", string(assumption));
end
end

function [rxStage, relStage] = local_sync_stage_observation_from_samples_local(rxSample, waveform, sampleAction, mitigation, stageSps)
rxSample = rxSample(:);
sampleAction = string(sampleAction);
relSample = ones(numel(rxSample), 1);
if sampleAction == "none"
    rxPrep = rxSample;
else
    [rxPrep, relSample] = mitigate_impulses(rxSample, sampleAction, mitigation);
end

rxMf = local_matched_filter_samples_local(rxPrep, waveform);
relMf = local_matched_filter_reliability_samples_local(relSample, waveform);
[rxStage, relStage] = local_decimate_stage_branch_local(rxMf, relMf, waveform, stageSps);
relStage = local_fit_reliability_length_local(relStage, numel(rxStage));
end

function yMf = local_matched_filter_samples_local(ySample, waveform)
ySample = ySample(:);
if ~waveform.enable
    yMf = ySample;
    return;
end
if waveform.rxMatchedFilter
    yMf = filter(waveform.rrcTaps(:), 1, ySample);
    totalGd = 2 * waveform.groupDelaySamples;
    if numel(yMf) <= totalGd
        yMf = complex(zeros(0, 1));
        return;
    end
    yMf = yMf(totalGd+1:end);
else
    yMf = ySample;
end
end

function relMf = local_matched_filter_reliability_samples_local(relSample, waveform)
relSample = double(relSample(:));
relSample(~isfinite(relSample)) = 0;
relSample = max(min(relSample, 1), 0);
if ~waveform.enable
    relMf = relSample;
    return;
end

if waveform.rxMatchedFilter
    taps = abs(double(waveform.rrcTaps(:)));
    if ~any(taps > 0)
        taps = ones(size(taps));
    end
    taps = taps / sum(taps);
    relMf = filter(taps, 1, relSample);
    totalGd = 2 * waveform.groupDelaySamples;
    if numel(relMf) <= totalGd
        relMf = zeros(0, 1);
        return;
    end
    relMf = relMf(totalGd+1:end);
else
    relMf = relSample;
end
relMf = max(min(relMf, 1), 0);
end

function [yStage, relStage] = local_decimate_stage_branch_local(yMf, relMf, waveform, stageSps)
yMf = yMf(:);
relMf = relMf(:);
if ~waveform.enable
    if stageSps ~= 1
        error("未启用波形成型时，接收同步级采样率只能为1 sps。");
    end
    yStage = yMf;
    relStage = relMf;
    return;
end

stageSps = max(1, round(double(stageSps)));
if mod(double(waveform.sps), double(stageSps)) ~= 0
    error("waveform.sps=%d 不能整数降采样到 %d sps。", waveform.sps, stageSps);
end
decim = round(double(waveform.sps) / double(stageSps));
yStage = yMf(1:decim:end);
relStage = relMf(1:decim:end);
relStage = max(min(relStage, 1), 0);
end

function stageSps = local_sync_stage_sps_local(waveform)
stageSps = 1;
if ~isstruct(waveform)
    return;
end
if ~(isfield(waveform, "enable") && waveform.enable && isfield(waveform, "sps"))
    return;
end
if double(waveform.sps) < 2
    return;
end
if mod(double(waveform.sps), 2) ~= 0
    error("接收链重构要求 waveform.sps 能够整数降采样到 2 sps，当前 waveform.sps=%d。", waveform.sps);
end
stageSps = 2;
end

function nStage = local_stage_symbol_sequence_length_local(nSym, stageSps)
nSym = max(0, round(double(nSym)));
stageSps = max(1, round(double(stageSps)));
if nSym == 0
    nStage = 0;
    return;
end
if stageSps == 1
    nStage = nSym;
    return;
end
nStage = (nSym - 1) * stageSps + 1;
end

function syncRefStage = local_sync_reference_stage_local(syncSymRef, waveform, stageSps)
syncSymRef = syncSymRef(:);
stageSps = max(1, round(double(stageSps)));
if stageSps == 1 || ~waveform.enable
    syncRefStage = syncSymRef;
    return;
end

txSyncSample = pulse_tx_from_symbol_rate(syncSymRef, waveform);
syncMf = local_matched_filter_samples_local(txSyncSample, waveform);
[syncRefStage, ~] = local_decimate_stage_branch_local(syncMf, ones(numel(syncMf), 1), waveform, stageSps);
syncRefStage = fit_complex_length_local(syncRefStage, local_stage_symbol_sequence_length_local(numel(syncSymRef), stageSps));
syncRefPower = mean(abs(syncRefStage).^2);
if syncRefPower > 0
    syncRefStage = syncRefStage / sqrt(syncRefPower);
end
end

function syncCfgStage = local_sync_cfg_for_stage_local(syncCfgUse, stageSps)
syncCfgStage = syncCfgUse;
stageSps = max(1, round(double(stageSps)));
if stageSps <= 1
    return;
end

if isfield(syncCfgStage, "fineSearchRadius") && ~isempty(syncCfgStage.fineSearchRadius)
    syncCfgStage.fineSearchRadius = round(double(syncCfgStage.fineSearchRadius) * stageSps);
end
if isfield(syncCfgStage, "corrExclusionRadius") && ~isempty(syncCfgStage.corrExclusionRadius)
    syncCfgStage.corrExclusionRadius = round(double(syncCfgStage.corrExclusionRadius) * stageSps);
end
if isfield(syncCfgStage, "minSearchIndex") && isfinite(double(syncCfgStage.minSearchIndex))
    syncCfgStage.minSearchIndex = double(syncCfgStage.minSearchIndex) * stageSps;
end
if isfield(syncCfgStage, "maxSearchIndex") && isfinite(double(syncCfgStage.maxSearchIndex))
    syncCfgStage.maxSearchIndex = double(syncCfgStage.maxSearchIndex) * stageSps;
end
syncCfgStage.enableFractionalTiming = false;
syncCfgStage.compensateCarrier = false;
syncCfgStage.equalizeAmplitude = false;
syncCfgStage.estimateCfo = false;
if isfield(syncCfgStage, "fractionalRange")
    syncCfgStage.fractionalRange = 0;
end
if isfield(syncCfgStage, "fractionalStep")
    syncCfgStage.fractionalStep = 0;
end
if isfield(syncCfgStage, "timingDll") && isstruct(syncCfgStage.timingDll) ...
        && isfield(syncCfgStage.timingDll, "enable")
    syncCfgStage.timingDll.enable = false;
end
end

function cfgOut = local_symbol_extract_sync_cfg_local(syncCfgUse)
cfgOut = syncCfgUse;
cfgOut.enableFractionalTiming = false;
if isfield(cfgOut, "fractionalRange")
    cfgOut.fractionalRange = 0;
end
if isfield(cfgOut, "fractionalStep")
    cfgOut.fractionalStep = 0;
end
end

function [startIdxStage, syncInfo] = local_refine_stage_capture_local(rxStage, syncRefStage, startHintStage, syncCfgStage, searchRadiusStage)
rxStage = rxStage(:);
searchRadiusStage = max(0, round(double(searchRadiusStage)));
syncInfo = struct();
startIdxStage = [];
if isempty(rxStage) || isempty(syncRefStage)
    return;
end

cfg = syncCfgStage;
maxIdx = max(1, numel(rxStage) - numel(syncRefStage) + 1);
cfg.minSearchIndex = max(1, floor(double(startHintStage) - searchRadiusStage));
cfg.maxSearchIndex = min(maxIdx, ceil(double(startHintStage) + searchRadiusStage));
[startIdxStage, ~, syncInfo] = frame_sync(rxStage, syncRefStage, cfg);
end

function [startIdxStage, timingInfo] = local_estimate_symbol_timing_from_stage_local(rxStage, startHintStage, syncSymRef, syncCfgUse, modCfg, stageSps)
rxStage = rxStage(:);
syncSymRef = syncSymRef(:);
stageSps = max(1, round(double(stageSps)));
timingInfo = struct( ...
    "fractionalOffsetSymbols", 0, ...
    "corrPeak", NaN, ...
    "timingCompensated", false);
startIdxStage = [];
if isempty(rxStage) || isempty(syncSymRef)
    return;
end

fracGrid = 0;
if isfield(syncCfgUse, "enableFractionalTiming") && logical(syncCfgUse.enableFractionalTiming)
    fracRange = 0.5;
    fracStep = 0.05;
    if isfield(syncCfgUse, "fractionalRange") && ~isempty(syncCfgUse.fractionalRange)
        fracRange = abs(double(syncCfgUse.fractionalRange));
    end
    if isfield(syncCfgUse, "fractionalStep") && ~isempty(syncCfgUse.fractionalStep)
        fracStep = abs(double(syncCfgUse.fractionalStep));
    end
    if fracRange > 0 && fracStep > 0
        fracGrid = -fracRange:fracStep:fracRange;
        if isempty(fracGrid) || ~any(abs(fracGrid) < 1e-12)
            fracGrid = unique([fracGrid 0]);
        end
    end
end

bestScore = -inf;
bestOffsetSym = 0;
for offsetSym = fracGrid
    startNow = double(startHintStage) + double(offsetSym) * double(stageSps);
    [seg, okSeg] = extract_fractional_block(rxStage, startNow, numel(syncSymRef), ...
        local_symbol_extract_sync_cfg_local(syncCfgUse), modCfg, stageSps);
    if ~okSeg
        continue;
    end

    if isfield(syncCfgUse, "estimateCfo") && logical(syncCfgUse.estimateCfo)
        symAxis = (0:numel(syncSymRef)-1).';
        [wTmp, phiTmp] = local_estimate_cfo_phase_local(seg, syncSymRef, symAxis);
        segUse = seg .* exp(-1j * (wTmp * symAxis + phiTmp));
    else
        segUse = seg;
    end
    score = abs(sum(segUse .* conj(syncSymRef)));
    if score <= bestScore
        continue;
    end

    bestScore = score;
    bestOffsetSym = double(offsetSym);
end

if ~isfinite(bestScore)
    return;
end

startIdxStage = double(startHintStage) + bestOffsetSym * double(stageSps);
timingInfo.fractionalOffsetSymbols = bestOffsetSym;
timingInfo.corrPeak = bestScore;
timingInfo.timingCompensated = abs(bestOffsetSym) > 1e-12;
end

function [rComp, compInfo] = local_apply_symbol_block_sync_compensation_local(rSym, syncSymRef, syncCfgUse)
rSym = rSym(:);
syncSymRef = syncSymRef(:);
rComp = rSym;
compInfo = struct( ...
    "compensated", false, ...
    "cfoRadPerSample", 0, ...
    "chanGainEstimate", complex(NaN, NaN), ...
    "phaseEstimateRad", NaN, ...
    "amplitudeEstimate", NaN);
if isempty(rSym) || isempty(syncSymRef)
    return;
end

if ~isfield(syncCfgUse, "compensateCarrier") || ~logical(syncCfgUse.compensateCarrier)
    return;
end

pre = rSym(1:min(numel(rSym), numel(syncSymRef)));
syncRefUse = syncSymRef(1:numel(pre));
if numel(pre) ~= numel(syncRefUse) || isempty(pre) || ~any(abs(pre) > 0)
    return;
end

denom = sum(abs(syncRefUse).^2);
if denom <= 0
    return;
end

cfoRad = 0;
phiHat = 0;
if isfield(syncCfgUse, "estimateCfo") && logical(syncCfgUse.estimateCfo)
    symAxis = (0:numel(pre)-1).';
    [cfoRad, phiHat] = local_estimate_cfo_phase_local(pre, syncRefUse, symAxis);
    rComp = rSym .* exp(-1j * (cfoRad * (0:numel(rSym)-1).' + phiHat));
end

preComp = rComp(1:numel(syncRefUse));
hHat = sum(preComp .* conj(syncRefUse)) / denom;
if abs(hHat) <= 1e-12
    return;
end

if ~isfield(syncCfgUse, "equalizeAmplitude") || logical(syncCfgUse.equalizeAmplitude)
    compGain = hHat;
else
    compGain = exp(1j * angle(hHat));
end
rComp = rComp ./ compGain;

compInfo.compensated = true;
compInfo.cfoRadPerSample = double(cfoRad);
compInfo.chanGainEstimate = hHat;
compInfo.phaseEstimateRad = angle(hHat);
compInfo.amplitudeEstimate = abs(hHat);
end

function syncInfo = local_merge_stage_sync_info_local(syncInfoStage, timingInfo, compInfo, coarseStartIdxStage, symbolStartIdxStage, stageSps)
syncInfo = syncInfoStage;
syncInfo.coarseStageStartIdx = double(coarseStartIdxStage);
syncInfo.stageStartIdx = double(symbolStartIdxStage);
syncInfo.stageSps = double(stageSps);
syncInfo.fineIdx = floor(double(symbolStartIdxStage));
syncInfo.fineFrac = double(symbolStartIdxStage) - floor(double(symbolStartIdxStage));
syncInfo.timingOffsetSymbols = double(timingInfo.fractionalOffsetSymbols);
syncInfo.timingCorrPeak = double(timingInfo.corrPeak);
syncInfo.timingCompensated = logical(timingInfo.timingCompensated);
syncInfo.cfoRadPerSample = double(compInfo.cfoRadPerSample);
syncInfo.chanGainEstimate = compInfo.chanGainEstimate;
syncInfo.phaseEstimateRad = double(compInfo.phaseEstimateRad);
syncInfo.amplitudeEstimate = double(compInfo.amplitudeEstimate);
syncInfo.compensated = logical(compInfo.compensated);
end

function [wHat, phiHat] = local_estimate_cfo_phase_local(seg, pre, nAbs)
z = seg(:) .* conj(pre(:));
z(abs(z) < 1e-12) = 1e-12;
phaseVec = unwrap(angle(z));
coef = polyfit(nAbs(:), phaseVec, 1);
wHat = coef(1);
phiHat = coef(2);
end

function relOut = local_extract_reliability_from_sample_times_local(reliabilityTrack, sampleTimes)
reliabilityTrack = double(reliabilityTrack(:));
sampleTimes = double(sampleTimes(:));
if isempty(reliabilityTrack) || isempty(sampleTimes)
    relOut = zeros(0, 1);
    return;
end
reliabilityTrack(~isfinite(reliabilityTrack)) = 0;
reliabilityTrack = max(min(reliabilityTrack, 1), 0);
idx = (1:numel(reliabilityTrack)).';
relOut = interp1(idx, reliabilityTrack, sampleTimes, "linear", 0);
relOut(~isfinite(relOut)) = 0;
relOut = max(min(relOut, 1), 0);
end

function decision = local_select_frontend_action_local(methodName, adaptiveEnabled, rFull, syncSymRef, syncInfo, bootstrapPath, mitigation, channelCfg, waveform, N0)
featureCount = numel(ml_interference_selector_feature_names());
decision = struct( ...
    "selectedClass", "", ...
    "selectedAction", "", ...
    "sampleAction", "none", ...
    "symbolAction", "none", ...
    "confidence", NaN, ...
    "classProbabilities", zeros(0, 1), ...
    "featureRow", zeros(1, featureCount), ...
    "bootstrapPath", string(bootstrapPath));

methodName = string(methodName);
if local_is_adaptive_frontend_method_local(methodName) && logical(adaptiveEnabled)
    selectorModel = local_require_selector_model_local(mitigation);
    captureDiag = struct( ...
        "ok", true, ...
        "rFull", rFull(:), ...
        "syncInfo", syncInfo);
    channelLenSymbols = local_multipath_channel_len_symbols_local(channelCfg, waveform);
    [featureRow, featureInfo] = adaptive_frontend_extract_features(captureDiag, syncSymRef, N0, ...
        "channelLenSymbols", channelLenSymbols);
    [className, confidence, classProbabilities] = ml_predict_interference_class(featureRow, selectorModel);
    actionName = local_map_class_to_action_local(mitigation, className);
    probeObs = rFull(min(numel(syncSymRef) + 1, numel(rFull)):end);
    if numel(probeObs) < 32
        probeObs = rFull(:);
    end
    [className, actionName] = local_apply_narrowband_guard_local(mitigation, className, actionName, featureInfo, probeObs);
    [sampleAction, symbolAction] = local_split_mitigation_action_local(actionName);

    decision.selectedClass = string(className);
    decision.selectedAction = string(actionName);
    decision.sampleAction = sampleAction;
    decision.symbolAction = symbolAction;
    decision.confidence = double(confidence);
    decision.classProbabilities = classProbabilities;
    decision.featureRow = featureRow;
    return;
end

decision.selectedAction = local_effective_presync_method_name_local(methodName, adaptiveEnabled);
[decision.sampleAction, decision.symbolAction] = local_split_mitigation_action_local(decision.selectedAction);
end

function sampleAction = local_initial_sample_action_hint_local(methodName, adaptiveEnabled)
methodName = string(methodName);
if local_is_adaptive_frontend_method_local(methodName) && logical(adaptiveEnabled)
    sampleAction = "none";
    return;
end
actionName = local_effective_presync_method_name_local(methodName, adaptiveEnabled);
[sampleAction, ~] = local_split_mitigation_action_local(actionName);
end

function bootstrapChain = local_capture_bootstrap_chain_for_method_local(methodName, adaptiveEnabled)
methodName = string(methodName);
if local_is_adaptive_frontend_method_local(methodName) && logical(adaptiveEnabled)
    bootstrapChain = strings(1, 0);
    return;
end
bootstrapChain = "raw";
end

function [sampleAction, symbolAction] = local_split_mitigation_action_local(actionName)
actionName = lower(string(actionName));
sampleAction = "none";
symbolAction = "none";
if any(actionName == ["none" "adaptive_ml_frontend"])
    return;
end

sampleActions = ["blanking" "clipping" "ml_blanking" "ml_cnn" "ml_gru" "ml_cnn_hard" "ml_gru_hard"];
symbolActions = ["fft_notch" "fft_bandstop" "adaptive_notch" "stft_notch" "ml_narrowband"];
if any(actionName == sampleActions)
    sampleAction = actionName;
    return;
end
if any(actionName == symbolActions)
    symbolAction = actionName;
    return;
end
error("接收链分层不支持方法: %s", char(actionName));
end

function model = local_require_selector_model_local(mitigation)
if ~isfield(mitigation, "selector") || isempty(mitigation.selector)
    error("mitigation.selector is required for adaptive_ml_frontend.");
end
model = mitigation.selector;
if ~(isfield(model, "trained") && logical(model.trained))
    error("adaptive_ml_frontend requires a trained selector model.");
end
end

function actionName = local_map_class_to_action_local(mitigation, className)
if ~(isfield(mitigation, "adaptiveFrontend") && isstruct(mitigation.adaptiveFrontend))
    error("mitigation.adaptiveFrontend is required for adaptive_ml_frontend.");
end
cfg = mitigation.adaptiveFrontend;
if ~(isfield(cfg, "classToAction") && isstruct(cfg.classToAction))
    error("mitigation.adaptiveFrontend.classToAction is required.");
end
fieldName = matlab.lang.makeValidName(char(string(className)));
if ~isfield(cfg.classToAction, fieldName)
    error("Missing adaptive front-end action mapping for class %s.", char(string(className)));
end
actionName = string(cfg.classToAction.(fieldName));
if strlength(actionName) == 0
    error("Adaptive front-end action mapping for class %s must not be empty.", char(string(className)));
end
end

function [className, actionName] = local_apply_narrowband_guard_local(mitigation, className, actionName, featureInfo, obs)
if ~(isfield(mitigation, "adaptiveFrontend") && isstruct(mitigation.adaptiveFrontend) ...
        && isfield(mitigation.adaptiveFrontend, "narrowbandGuard") ...
        && isstruct(mitigation.adaptiveFrontend.narrowbandGuard))
    return;
end

guard = mitigation.adaptiveFrontend.narrowbandGuard;
if ~(isfield(guard, "enable") && logical(guard.enable))
    return;
end

obs = obs(:);
if numel(obs) < 32
    return;
end

probeCfg = mitigation.fftBandstop;
if isfield(guard, "probePeakRatio") && ~isempty(guard.probePeakRatio)
    probeCfg.peakRatio = double(guard.probePeakRatio);
end
[~, probeInfo] = fft_bandstop_filter(obs, probeCfg);
if ~(isfield(probeInfo, "applied") && probeInfo.applied && ~isempty(probeInfo.selectedBandwidthFrac))
    return;
end

bwFrac = max(double(probeInfo.selectedBandwidthFrac));
metrics = struct();
if isfield(featureInfo, "metrics") && isstruct(featureInfo.metrics)
    metrics = featureInfo.metrics;
end

overrideClasses = ["clean" "multipath"];
if isfield(guard, "overrideClasses") && ~isempty(guard.overrideClasses)
    overrideClasses = string(guard.overrideClasses(:).');
end

minBw = local_guard_scalar_local(guard, "minBandwidthFrac", 0.025);
maxBw = local_guard_scalar_local(guard, "maxBandwidthFrac", 0.22);
toneBw = local_guard_scalar_local(guard, "toneBandwidthFrac", 0.025);
minFftPeakRatio = local_guard_scalar_local(guard, "minFftPeakRatio", 6.0);
fftPeakRatio = max(local_metric_scalar_local(metrics, "fftPeakRatio"), max(double(probeInfo.peakRatios)));
narrowbandLike = bwFrac >= minBw && bwFrac <= maxBw ...
    && fftPeakRatio >= minFftPeakRatio;

if className == "tone" && bwFrac >= toneBw
    className = "narrowband";
    actionName = "fft_bandstop";
    return;
end

if any(className == overrideClasses) && narrowbandLike
    className = "narrowband";
    actionName = "fft_bandstop";
end
end

function value = local_guard_scalar_local(cfg, fieldName, defaultValue)
value = double(defaultValue);
if isfield(cfg, fieldName) && ~isempty(cfg.(fieldName))
    value = double(cfg.(fieldName));
end
if ~(isscalar(value) && isfinite(value))
    error("adaptiveFrontend.narrowbandGuard.%s must be a finite scalar.", fieldName);
end
end

function value = local_metric_scalar_local(metrics, fieldName)
value = 0;
if isfield(metrics, fieldName) && ~isempty(metrics.(fieldName))
    value = double(metrics.(fieldName));
end
if ~(isscalar(value) && isfinite(value))
    value = 0;
end
end

function hdrSymPrep = local_prepare_header_symbols_local(hdrSym, actionName, mitigation, headerActionCtx)
hdrSym = hdrSym(:);
actionName = string(actionName);
if nargin < 4 || isempty(headerActionCtx)
    headerActionCtx = local_empty_header_action_ctx_local();
end
if actionName == "none"
    hdrSymPrep = hdrSym;
    return;
end

if logical(headerActionCtx.usePerHop) && double(headerActionCtx.hopLen) > 0 ...
        && local_action_prefers_per_hop_local(actionName)
    mitigationUse = mitigation;
    if actionName == "fft_bandstop" && logical(headerActionCtx.useCustomBandstop)
        mitigationUse.fftBandstop = headerActionCtx.bandstopCfg;
    end
    [hdrSymPrep, ~] = local_apply_action_per_hop_local(hdrSym, actionName, mitigationUse, headerActionCtx.hopLen);
    return;
end

if actionName == "fft_bandstop" && logical(headerActionCtx.useCustomBandstop)
    [hdrSymPrep, ~] = fft_bandstop_filter(hdrSym, headerActionCtx.bandstopCfg);
    return;
end

[hdrSymPrep, ~] = mitigate_impulses(hdrSym, actionName, mitigation);
end

function headerActionCtx = local_empty_header_action_ctx_local()
headerActionCtx = struct( ...
    "useCustomBandstop", false, ...
    "bandstopCfg", struct(), ...
    "usePerHop", false, ...
    "hopLen", 0);
end

function headerActionCtx = local_build_header_action_ctx_local(rFull, preLen, hdrLen, actionName, mitigation)
headerActionCtx = local_empty_header_action_ctx_local();
actionName = string(actionName);
if actionName ~= "fft_bandstop"
    return;
end
if ~(isfield(mitigation, "headerBandstop") && isstruct(mitigation.headerBandstop))
    return;
end
cfg = mitigation.headerBandstop;
if ~(isfield(cfg, "enable") && logical(cfg.enable))
    return;
end
headerBandstopCfg = local_header_bandstop_cfg_local(mitigation);
headerActionCtx.useCustomBandstop = true;
headerActionCtx.bandstopCfg = headerBandstopCfg;

rFull = rFull(:);
obsStart = max(1, round(double(preLen)) + 1);
if obsStart > numel(rFull)
    return;
end
obsTargetLen = local_header_bandstop_scalar_local(cfg, "observationSymbols", 512);
obsTargetLen = max(round(double(hdrLen)), obsTargetLen);
obsStop = min(numel(rFull), obsStart + obsTargetLen - 1);
obs = rFull(obsStart:obsStop);
minObsLen = local_header_bandstop_scalar_local(cfg, "minObservationSymbols", 192);
if numel(obs) < minObsLen
    return;
end

probeCfg = mitigation.fftBandstop;
probeCfg.forcedFreqBounds = zeros(0, 2);
[~, probeInfo] = fft_bandstop_filter(obs, probeCfg);
if ~(isfield(probeInfo, "applied") && probeInfo.applied ...
        && isfield(probeInfo, "selectedFreqBounds") && ~isempty(probeInfo.selectedFreqBounds))
    return;
end

headerActionCtx.bandstopCfg.forcedFreqBounds = double(probeInfo.selectedFreqBounds);
end

function value = local_header_bandstop_scalar_local(cfg, fieldName, defaultValue)
value = double(defaultValue);
if isfield(cfg, fieldName) && ~isempty(cfg.(fieldName))
    value = double(cfg.(fieldName));
end
if ~(isscalar(value) && isfinite(value))
    error("mitigation.headerBandstop.%s must be a finite scalar.", fieldName);
end
end

function cfgOut = local_header_bandstop_cfg_local(mitigation)
if ~(isfield(mitigation, "fftBandstop") && isstruct(mitigation.fftBandstop))
    error("mitigation.fftBandstop is required for header bandstop.");
end
cfgOut = mitigation.fftBandstop;
cfgOut.forcedFreqBounds = zeros(0, 2);
if ~(isfield(mitigation, "headerBandstop") && isstruct(mitigation.headerBandstop))
    return;
end
headerCfg = mitigation.headerBandstop;
overrideFields = ["peakRatio" "edgeRatio" "maxBands" "mergeGapBins" "padBins" ...
    "minBandBins" "smoothSpanBins" "fftOversample" "maxBandwidthFrac" ...
    "minFreqAbs" "suppressToFloor"];
for k = 1:numel(overrideFields)
    fieldName = overrideFields(k);
    if isfield(headerCfg, fieldName) && ~isempty(headerCfg.(fieldName))
        cfgOut.(fieldName) = headerCfg.(fieldName);
    end
end
end

function actions = local_header_action_candidates_local(primaryAction, mitigation)
actions = string(primaryAction);
if ~(isfield(mitigation, "headerDecodeDiversity") && isstruct(mitigation.headerDecodeDiversity))
    return;
end
cfg = mitigation.headerDecodeDiversity;
if ~(isfield(cfg, "enable") && logical(cfg.enable))
    return;
end
if ~(isfield(cfg, "actions") && ~isempty(cfg.actions))
    error("mitigation.headerDecodeDiversity.actions must not be empty when enabled.");
end
extraActions = string(cfg.actions(:).');
if any(extraActions == "adaptive_ml_frontend")
    error("mitigation.headerDecodeDiversity does not support adaptive_ml_frontend.");
end
actions = unique([string(primaryAction) extraActions], "stable");
end

function [phy, headerOk] = local_try_decode_header_local(rFull, preLen, hdrLen, primaryAction, mitigation, frameCfg, fhCfgBase, fecCfg, softCfg)
phy = struct();
headerOk = false;
rFull = rFull(:);
hdrRaw = rFull(preLen+1:preLen+hdrLen);
[hdrRaw, headerHopInfo] = local_header_known_fh_demod_local(hdrRaw, frameCfg, fhCfgBase);
actions = local_header_action_candidates_local(primaryAction, mitigation);
for actionName = actions
    headerBlock = [complex(zeros(preLen, 1)); hdrRaw];
    headerActionCtx = local_build_header_action_ctx_local(headerBlock, preLen, hdrLen, actionName, mitigation);
    if isstruct(headerHopInfo) && isfield(headerHopInfo, "enable") && headerHopInfo.enable ...
            && isfield(headerHopInfo, "hopLen") && double(headerHopInfo.hopLen) > 0
        headerActionCtx.usePerHop = true;
        headerActionCtx.hopLen = round(double(headerHopInfo.hopLen));
        if isfield(headerActionCtx, "bandstopCfg") && isstruct(headerActionCtx.bandstopCfg)
            headerActionCtx.bandstopCfg.forcedFreqBounds = zeros(0, 2);
        end
    end
    hdrSym = local_prepare_header_symbols_local(hdrRaw, actionName, mitigation, headerActionCtx);
    hdrBits = decode_phy_header_symbols(hdrSym, frameCfg, fecCfg, softCfg);
    [phyNow, okNow] = parse_phy_header_bits(hdrBits, frameCfg);
    if okNow
        phy = phyNow;
        headerOk = true;
        return;
    end
end
end

function [hdrRaw, hopInfo] = local_header_known_fh_demod_local(hdrRaw, frameCfg, fhCfgBase)
hdrRaw = hdrRaw(:);
fhCfg = phy_header_fh_cfg(frameCfg, fhCfgBase);
hopInfo = struct('enable', false);
if ~fhCfg.enable
    return;
end
if fh_is_fast(fhCfg)
    return;
end
hopInfo = hop_info_from_fh_cfg_local(fhCfg, numel(hdrRaw));
hdrRaw = fh_demodulate(hdrRaw, hopInfo);
end

function raw = local_init_raw_capture_local(nPackets, nSessionFrames)
raw = struct();
raw.rxPackets = cell(nPackets, 1);
raw.sessionRx = cell(nSessionFrames, 1);
end

function nom = local_init_packet_nominal_local(nPackets, nSessionFrames)
nom = struct();
nom.frontEndOk = false(nPackets, 1);
nom.ok = false(nPackets, 1);
nom.headerOk = false(nPackets, 1);
nom.phy = repmat(empty_phy_header_local(), nPackets, 1);
nom.rxState = cell(nPackets, 1);
nom.preambleRx = cell(nPackets, 1);
nom.preambleRef = cell(nPackets, 1);
nom.rDataPrepared = cell(nPackets, 1);
nom.rDataReliability = cell(nPackets, 1);
nom.adaptiveClass = strings(nPackets, 1);
nom.adaptiveAction = strings(nPackets, 1);
nom.adaptiveBootstrapPath = strings(nPackets, 1);
nom.adaptiveConfidence = nan(nPackets, 1);
nom.session = local_init_session_nominal_local(nSessionFrames);
end

function nom = local_init_session_nominal_local(nFrames)
nom = struct();
nom.ok = false(nFrames, 1);
nom.rDataPrepared = cell(nFrames, 1);
nom.rDataReliability = cell(nFrames, 1);
nom.symbolAction = strings(nFrames, 1);
nom.preambleRx = cell(nFrames, 1);
nom.preambleRef = cell(nFrames, 1);
nom.adaptiveClass = strings(nFrames, 1);
nom.adaptiveAction = strings(nFrames, 1);
nom.adaptiveBootstrapPath = strings(nFrames, 1);
nom.adaptiveConfidence = nan(nFrames, 1);
end

function sessionRx = local_capture_session_frames_raw_local(sessionFrames, rxAmplitudeScale, N0, channelSample, frameDelay, waveform)
sessionRx = cell(numel(sessionFrames), 1);
if isempty(sessionFrames)
    return;
end

for frameIdx = 1:numel(sessionFrames)
    sessionFrame = sessionFrames(frameIdx);
    tx = [zeros(frameDelay, 1); rxAmplitudeScale * sessionFrame.txSymForChannel];
    rx = channel_bg_impulsive(tx, N0, channelSample);
    sessionRx{frameIdx} = rx;
end
end

function nom = local_build_packet_nominal_local(rawCapture, txPackets, sessionFrames, methodName, mitigation, syncCfgUse, rxSyncCfg, p, waveform, N0, fhEnabled, fhAssumption, adaptiveEnabled)
nPackets = numel(txPackets);
nom = local_init_packet_nominal_local(nPackets, numel(sessionFrames));
nom.session = local_build_session_nominal_local( ...
    rawCapture.sessionRx, sessionFrames, methodName, mitigation, syncCfgUse, rxSyncCfg, p, waveform, N0, adaptiveEnabled, fhAssumption);

for pktIdx = 1:nPackets
    if numel(rawCapture.rxPackets) < pktIdx || isempty(rawCapture.rxPackets{pktIdx})
        continue;
    end
    rxRaw = rawCapture.rxPackets{pktIdx};
    syncSymRef = txPackets(pktIdx).syncSym(:);
    preLen = numel(syncSymRef);
    hdrLen = numel(txPackets(pktIdx).phyHeaderSym);
    dataLen = numel(txPackets(pktIdx).dataSymTx);
    totalLen = preLen + hdrLen + dataLen;
    sampleActionHint = local_initial_sample_action_hint_local(methodName, adaptiveEnabled);
    bootstrapChain = local_capture_bootstrap_chain_for_method_local(methodName, adaptiveEnabled);
    fhCaptureCfg = local_packet_fast_fh_capture_cfg_local(txPackets(pktIdx), fhAssumption);
    front = local_capture_synced_block_local( ...
        rxRaw, syncSymRef, totalLen, syncCfgUse, mitigation, p.mod, waveform, sampleActionHint, bootstrapChain, fhCaptureCfg);
    if ~front.ok
        continue;
    end

    rFull = front.rFull;
    reliabilityFull = front.reliabilityFull;
    decision = local_select_frontend_action_local( ...
        methodName, adaptiveEnabled, rFull, syncSymRef, front.syncInfo, front.bootstrapPath, ...
        mitigation, p.channel, waveform, N0);
    if local_is_adaptive_frontend_method_local(methodName) && string(decision.sampleAction) ~= sampleActionHint
        front = local_capture_synced_block_local( ...
            rxRaw, syncSymRef, totalLen, syncCfgUse, mitigation, p.mod, waveform, ...
            decision.sampleAction, local_capture_bootstrap_chain_for_method_local(methodName, adaptiveEnabled), fhCaptureCfg);
        if ~front.ok
            continue;
        end
        rFull = front.rFull;
        reliabilityFull = front.reliabilityFull;
    end
    nom.adaptiveClass(pktIdx) = string(decision.selectedClass);
    nom.adaptiveAction(pktIdx) = string(decision.selectedAction);
    nom.adaptiveBootstrapPath(pktIdx) = string(front.bootstrapPath);
    nom.adaptiveConfidence(pktIdx) = double(decision.confidence);

    if local_multipath_eq_enabled_local(p.channel, rxSyncCfg)
        chLenSymbols = local_multipath_channel_len_symbols_local(p.channel, waveform);
        eqCfg = rxSyncCfg.multipathEq;
        [eq, eqOk] = multipath_equalizer_from_preamble(syncSymRef, rFull(1:preLen), eqCfg, N0, chLenSymbols);
        if eqOk
            rFull = local_apply_equalizer_block_local(rFull, eq);
        end
    end

    nom.frontEndOk(pktIdx) = true;
    nom.preambleRx{pktIdx} = fit_complex_length_local(rFull(1:preLen), preLen);
    nom.preambleRef{pktIdx} = syncSymRef;

    actionName = string(decision.symbolAction);
    [phy, headerOk] = local_try_decode_header_local(rFull, preLen, hdrLen, actionName, mitigation, p.frame, p.fh, p.fec, p.softMetric);
    nom.headerOk(pktIdx) = headerOk;
    if ~headerOk
        continue;
    end

    rxState = derive_rx_packet_state_local( ...
        p, double(phy.packetIndex), local_packet_data_bits_len_from_header_local(p, double(phy.packetIndex), phy));
    symbolFhEnabled = fhEnabled && ~fh_is_fast(rxState.fhCfg);
    if symbolFhEnabled
        hopInfoUsed = local_nominal_hop_info_local(rxState, fhAssumption);
    else
        hopInfoUsed = struct("enable", false);
    end

    rData = rFull(preLen+hdrLen+1:end);
    rDataRel = reliabilityFull(preLen+hdrLen+1:end);
    nom.phy(pktIdx) = phy;
    nom.rxState{pktIdx} = rxState;
    [nom.rDataPrepared{pktIdx}, nom.rDataReliability{pktIdx}] = local_prepare_data_symbols_local( ...
        rData, rDataRel, rxState, hopInfoUsed, p.mod, rxSyncCfg, symbolFhEnabled, actionName, mitigation);
    nom.ok(pktIdx) = true;
end
end

function nom = local_build_session_nominal_local(sessionRx, sessionFrames, methodName, mitigation, syncCfgUse, rxSyncCfg, p, waveform, N0, adaptiveEnabled, fhAssumption)
nom = local_init_session_nominal_local(numel(sessionFrames));
if isempty(sessionFrames)
    return;
end

for frameIdx = 1:numel(sessionFrames)
    if numel(sessionRx) < frameIdx || isempty(sessionRx{frameIdx})
        continue;
    end

    sessionFrame = sessionFrames(frameIdx);
    preLen = numel(sessionFrame.syncSym);
    totalLen = preLen + sessionFrame.nDataSym;
    sampleActionHint = local_initial_sample_action_hint_local(methodName, adaptiveEnabled);
    bootstrapChain = local_capture_bootstrap_chain_for_method_local(methodName, adaptiveEnabled);
    fhCaptureCfg = local_session_fast_fh_capture_cfg_local(sessionFrame, fhAssumption);
    front = local_capture_synced_block_local( ...
        sessionRx{frameIdx}, sessionFrame.syncSym(:), totalLen, syncCfgUse, mitigation, sessionFrame.modCfg, waveform, sampleActionHint, bootstrapChain, fhCaptureCfg);
    if ~front.ok
        continue;
    end

    rFull = front.rFull;
    reliabilityFull = front.reliabilityFull;
    decision = local_select_frontend_action_local( ...
        methodName, adaptiveEnabled, rFull, sessionFrame.syncSym(:), front.syncInfo, front.bootstrapPath, ...
        mitigation, p.channel, waveform, N0);
    if local_is_adaptive_frontend_method_local(methodName) && string(decision.sampleAction) ~= sampleActionHint
        front = local_capture_synced_block_local( ...
            sessionRx{frameIdx}, sessionFrame.syncSym(:), totalLen, syncCfgUse, mitigation, sessionFrame.modCfg, waveform, ...
            decision.sampleAction, local_capture_bootstrap_chain_for_method_local(methodName, adaptiveEnabled), fhCaptureCfg);
        if ~front.ok
            continue;
        end
        rFull = front.rFull;
        reliabilityFull = front.reliabilityFull;
    end
    nom.adaptiveClass(frameIdx) = string(decision.selectedClass);
    nom.adaptiveAction(frameIdx) = string(decision.selectedAction);
    nom.adaptiveBootstrapPath(frameIdx) = string(front.bootstrapPath);
    nom.adaptiveConfidence(frameIdx) = double(decision.confidence);

    if local_multipath_eq_enabled_local(p.channel, rxSyncCfg)
        chLenSymbols = local_multipath_channel_len_symbols_local(p.channel, waveform);
        eqCfg = rxSyncCfg.multipathEq;
        [eq, eqOk] = multipath_equalizer_from_preamble(sessionFrame.syncSym(:), rFull(1:preLen), eqCfg, N0, chLenSymbols);
        if eqOk
            rFull = local_apply_equalizer_block_local(rFull, eq);
        end
    end

    rxStateSession = local_session_rx_state_local(sessionFrame);
    nom.preambleRx{frameIdx} = fit_complex_length_local(rFull(1:preLen), preLen);
    nom.preambleRef{frameIdx} = sessionFrame.syncSym(:);
    actionName = string(decision.symbolAction);
    nom.symbolAction(frameIdx) = actionName;
    if string(sessionFrame.decodeKind) == "protected_header"
        [nom.rDataPrepared{frameIdx}, nom.rDataReliability{frameIdx}] = ...
            local_prepare_session_header_symbols_local(rFull, reliabilityFull, preLen, sessionFrame);
    else
        symbolFhEnabled = isfield(rxStateSession, "fhCfg") && isstruct(rxStateSession.fhCfg) ...
            && isfield(rxStateSession.fhCfg, "enable") && rxStateSession.fhCfg.enable ...
            && ~fh_is_fast(rxStateSession.fhCfg);
        if symbolFhEnabled
            hopInfoUsed = local_nominal_hop_info_local(rxStateSession, fhAssumption);
        else
            hopInfoUsed = struct("enable", false);
        end
        [nom.rDataPrepared{frameIdx}, nom.rDataReliability{frameIdx}] = local_prepare_data_symbols_local( ...
            rFull(preLen+1:end), reliabilityFull(preLen+1:end), rxStateSession, hopInfoUsed, sessionFrame.modCfg, rxSyncCfg, symbolFhEnabled, actionName, mitigation);
    end
    nom.ok(frameIdx) = true;
end
end

function rxStateSession = local_session_rx_state_local(sessionFrame)
rxStateSession = struct( ...
    "nDataSym", double(sessionFrame.nDataSym), ...
    "nDemodSym", double(local_session_demod_symbol_count_local(sessionFrame)), ...
    "dsssCfg", sessionFrame.dsssCfg, ...
    "fhCfg", sessionFrame.fhCfg, ...
    "hopInfo", sessionFrame.hopInfo);
end

function nSym = local_session_demod_symbol_count_local(sessionFrame)
nSym = double(sessionFrame.nDataSym);
if isfield(sessionFrame, "nDemodSym") && ~isempty(sessionFrame.nDemodSym)
    nSym = double(sessionFrame.nDemodSym);
end
nSym = max(0, round(nSym));
end

function [sessionOut, calState] = local_recover_session_from_nominal_local(sessionIn, sessionNom, sessionFrames, methodName, mitigation, p, calState)
sessionOut = sessionIn;
if sessionOut.known || isempty(sessionFrames)
    return;
end
if ~isfield(sessionNom, "ok") || isempty(sessionNom.ok)
    return;
end

rMitList = cell(0, 1);
for frameIdx = 1:min(numel(sessionFrames), numel(sessionNom.ok))
    if ~sessionNom.ok(frameIdx)
        continue;
    end
    if isempty(sessionNom.rDataPrepared{frameIdx})
        continue;
    end

    nDemodSym = local_session_demod_symbol_count_local(sessionFrames(frameIdx));
    rData = fit_complex_length_local(sessionNom.rDataPrepared{frameIdx}, nDemodSym);
    reliability = [];
    if isfield(sessionNom, "rDataReliability") && numel(sessionNom.rDataReliability) >= frameIdx ...
            && ~isempty(sessionNom.rDataReliability{frameIdx})
        reliability = local_fit_reliability_length_local(sessionNom.rDataReliability{frameIdx}, nDemodSym);
    end
    primaryAction = "none";
    if isfield(sessionNom, "symbolAction") && numel(sessionNom.symbolAction) >= frameIdx ...
            && strlength(string(sessionNom.symbolAction(frameIdx))) > 0
        primaryAction = string(sessionNom.symbolAction(frameIdx));
    end
    [metaSession, okFrame] = local_try_decode_session_frame_local( ...
        rData, reliability, sessionFrames(frameIdx), p, primaryAction, mitigation);
    if okFrame
        sessionOut = learn_rx_session_local(metaSession);
        return;
    end

    rMitList{end+1, 1} = fit_complex_length_local(rData, nDemodSym); %#ok<AGROW>
end

if numel(rMitList) >= 2
    rCombined = local_average_session_symbols_local(rMitList);
    primaryAction = "none";
    if isfield(sessionNom, "symbolAction") && ~isempty(sessionNom.symbolAction)
        firstIdx = find(strlength(sessionNom.symbolAction) > 0, 1, "first");
        if ~isempty(firstIdx)
            primaryAction = string(sessionNom.symbolAction(firstIdx));
        end
    end
    [metaSession, okFrame] = local_try_decode_session_frame_local( ...
        rCombined, [], sessionFrames(1), p, primaryAction, mitigation);
    if okFrame
        sessionOut = learn_rx_session_local(metaSession);
    end
end
end

function [metaSession, ok] = local_try_decode_session_frame_local(rData, reliability, sessionFrame, p, primaryAction, mitigation)
metaSession = struct();
ok = false;

switch string(sessionFrame.decodeKind)
    case "protected_header"
        actions = local_header_action_candidates_local(primaryAction, mitigation);
        for actionName = actions
            headerActionCtx = local_build_header_action_ctx_local(rData(:), 0, numel(rData), actionName, mitigation);
            if isfield(sessionFrame, "hopInfo") && isstruct(sessionFrame.hopInfo) ...
                    && isfield(sessionFrame.hopInfo, "enable") && sessionFrame.hopInfo.enable ...
                    && isfield(sessionFrame.hopInfo, "hopLen") && double(sessionFrame.hopInfo.hopLen) > 0
                headerActionCtx.usePerHop = true;
                headerActionCtx.hopLen = round(double(sessionFrame.hopInfo.hopLen));
                if isfield(headerActionCtx, "bandstopCfg") && isstruct(headerActionCtx.bandstopCfg)
                    headerActionCtx.bandstopCfg.forcedFreqBounds = zeros(0, 2);
                end
            end
            rUse = local_prepare_header_symbols_local(rData, actionName, mitigation, headerActionCtx);
            symbolRepeat = 1;
            if isfield(sessionFrame, "symbolRepeat") && ~isempty(sessionFrame.symbolRepeat)
                symbolRepeat = max(1, round(double(sessionFrame.symbolRepeat)));
            end
            if symbolRepeat > 1
                rUse = local_repeat_combine_symbols_local(rUse, symbolRepeat);
            end
            sessionBits = decode_protected_header_symbols(rUse, sessionFrame.infoBitsLen, p.frame, p.fec, p.softMetric);
            [metaSession, ~, ok] = parse_session_header_bits(sessionBits, p.frame);
            if ok
                return;
            end
        end
    case "payload_like"
        demodSoft = demodulate_to_softbits(rData, sessionFrame.modCfg, sessionFrame.fecCfg, p.softMetric, reliability);
        demodDeint = deinterleave_bits(demodSoft, sessionFrame.intState, p.interleaver);
        sessionBits = fec_decode(demodDeint, sessionFrame.fecCfg);
    case "strong_bpsk"
        rComb = local_repeat_combine_symbols_local(rData, sessionFrame.bitRepeat);
        reliabilityComb = local_repeat_combine_reliability_local(reliability, sessionFrame.bitRepeat);
        demodSoft = demodulate_to_softbits(rComb, sessionFrame.modCfg, sessionFrame.fecCfg, p.softMetric, reliabilityComb);
        sessionBits = fec_decode(demodSoft, sessionFrame.fecCfg);
    otherwise
        error("Unsupported session frame decodeKind: %s", string(sessionFrame.decodeKind));
end

if exist("sessionBits", "var")
    sessionBits = fit_bits_length(sessionBits, sessionFrame.infoBitsLen);
    [metaSession, ~, ok] = parse_session_header_bits(sessionBits, p.frame);
end
end

function y = local_repeat_combine_symbols_local(x, repeat)
if repeat <= 1
    y = x(:);
    return;
end

nGroups = floor(numel(x) / repeat);
if nGroups <= 0
    y = complex(zeros(0, 1));
    return;
end
x = reshape(x(1:nGroups * repeat), repeat, nGroups);
y = sum(x, 1).';
end

function y = local_repeat_combine_reliability_local(x, repeat)
if isempty(x)
    y = [];
    return;
end
if repeat <= 1
    y = x(:);
    return;
end

nGroups = floor(numel(x) / repeat);
if nGroups <= 0
    y = [];
    return;
end
x = reshape(double(x(1:nGroups * repeat)), repeat, nGroups);
y = mean(x, 1).';
end

function y = local_average_session_symbols_local(parts)
if isempty(parts)
    y = complex(zeros(0, 1));
    return;
end

nSym = min(cellfun(@numel, parts));
if nSym <= 0
    y = complex(zeros(0, 1));
    return;
end

mat = complex(zeros(nSym, numel(parts)));
for k = 1:numel(parts)
    mat(:, k) = parts{k}(1:nSym);
end
y = mean(mat, 2);
end

function [hdrRaw, reliability] = local_prepare_session_header_symbols_local(rFull, reliabilityFull, preLen, sessionFrame)
hdrLen = double(sessionFrame.nDataSym);
hdrRaw = fit_complex_length_local(rFull(preLen+1:end), hdrLen);
reliability = local_fit_reliability_length_local(reliabilityFull(preLen+1:end), hdrLen);
if ~(isfield(sessionFrame, "fhCfg") && isstruct(sessionFrame.fhCfg) ...
        && isfield(sessionFrame.fhCfg, "enable") && sessionFrame.fhCfg.enable)
    return;
end
if fh_is_fast(sessionFrame.fhCfg)
    return;
end
hopInfo = hop_info_from_fh_cfg_local(sessionFrame.fhCfg, numel(hdrRaw));
hdrRaw = fh_demodulate(hdrRaw, hopInfo);
end

function rate = local_nominal_success_rate_local(nom)
rate = 0;
if isfield(nom, "ok") && ~isempty(nom.ok)
    rate = mean(double(nom.ok));
end
end

function tf = local_is_adaptive_frontend_method_local(methodName)
tf = string(methodName) == "adaptive_ml_frontend";
end

function methodNameUse = local_effective_presync_method_name_local(methodName, adaptiveEnabled)
methodNameUse = string(methodName);
if local_is_adaptive_frontend_method_local(methodNameUse) && ~logical(adaptiveEnabled)
    methodNameUse = "none";
end
end

function diagCfg = local_adaptive_frontend_catalog_local(mitigationCfg)
if ~isstruct(mitigationCfg) || ~isscalar(mitigationCfg)
    error("mitigation 配置必须是标量struct。");
end
if ~isfield(mitigationCfg, "adaptiveFrontend") || ~isstruct(mitigationCfg.adaptiveFrontend)
    error("mitigation.adaptiveFrontend 缺失。");
end
cfg = mitigationCfg.adaptiveFrontend;
local_require_struct_fields_local(cfg, ...
    ["bootstrapSyncChain", "classNames", "classToAction", "diagnostics"], ...
    "mitigation.adaptiveFrontend");

    classNames = string(cfg.classNames(:).');
    bootstrapPaths = string(cfg.bootstrapSyncChain(:).');
    if isempty(classNames)
        error("mitigation.adaptiveFrontend.classNames 不能为空。");
    end
    if isempty(bootstrapPaths)
        error("mitigation.adaptiveFrontend.bootstrapSyncChain 不能为空。");
    end
    if ~isstruct(cfg.classToAction) || ~isscalar(cfg.classToAction)
        error("mitigation.adaptiveFrontend.classToAction 必须是标量struct。");
    end

    actionNames = strings(1, 0);
    for k = 1:numel(classNames)
        fieldName = matlab.lang.makeValidName(char(classNames(k)));
        if ~isfield(cfg.classToAction, fieldName)
            error("mitigation.adaptiveFrontend.classToAction 缺少类别 %s 的映射。", char(classNames(k)));
        end
        actionName = string(cfg.classToAction.(fieldName));
        if strlength(actionName) == 0
            error("mitigation.adaptiveFrontend.classToAction.%s 不能为空。", fieldName);
        end
        if ~any(actionNames == actionName)
            actionNames(end+1) = actionName; %#ok<AGROW>
        end
    end

    diagCfg = struct( ...
        "classNames", classNames, ...
        "actionNames", actionNames, ...
        "bootstrapPaths", bootstrapPaths);
end

function summary = local_collect_adaptive_frontend_summary_local(nom, mitigationCfg)
diagCfg = local_adaptive_frontend_catalog_local(mitigationCfg);
summary = struct( ...
    "classCounts", zeros(numel(diagCfg.classNames), 1), ...
    "actionCounts", zeros(numel(diagCfg.actionNames), 1), ...
    "pathCounts", zeros(numel(diagCfg.bootstrapPaths), 1), ...
    "confidenceSum", 0, ...
    "decisionCount", 0);

summary = local_accumulate_adaptive_frontend_summary_local(summary, nom, diagCfg);
if isstruct(nom) && isfield(nom, "session") && isstruct(nom.session)
    summary = local_accumulate_adaptive_frontend_summary_local(summary, nom.session, diagCfg);
end
end

function summary = local_accumulate_adaptive_frontend_summary_local(summary, nomPart, diagCfg)
if ~isstruct(nomPart) || ~isscalar(nomPart)
    return;
end
requiredFields = ["adaptiveClass", "adaptiveAction", "adaptiveBootstrapPath", "adaptiveConfidence"];
for k = 1:numel(requiredFields)
    if ~isfield(nomPart, requiredFields(k))
        return;
    end
end

classList = string(nomPart.adaptiveClass(:));
actionList = string(nomPart.adaptiveAction(:));
pathList = string(nomPart.adaptiveBootstrapPath(:));
confidenceList = double(nomPart.adaptiveConfidence(:));
decisionMask = strlength(classList) > 0 & strlength(actionList) > 0 & strlength(pathList) > 0 ...
    & isfinite(confidenceList);

for idx = find(decisionMask(:)).'
    classIdx = local_adaptive_frontend_lookup_index_local(classList(idx), diagCfg.classNames, "class");
    actionIdx = local_adaptive_frontend_lookup_index_local(actionList(idx), diagCfg.actionNames, "action");
    pathIdx = local_adaptive_frontend_lookup_index_local(pathList(idx), diagCfg.bootstrapPaths, "bootstrapPath");
    summary.classCounts(classIdx) = summary.classCounts(classIdx) + 1;
    summary.actionCounts(actionIdx) = summary.actionCounts(actionIdx) + 1;
    summary.pathCounts(pathIdx) = summary.pathCounts(pathIdx) + 1;
    summary.confidenceSum = summary.confidenceSum + confidenceList(idx);
    summary.decisionCount = summary.decisionCount + 1;
end
end

function idx = local_adaptive_frontend_lookup_index_local(name, catalog, catalogName)
idx = find(catalog == string(name), 1, "first");
if isempty(idx)
    error("Adaptive front-end %s %s is not registered in the catalog.", catalogName, char(string(name)));
end
end

function session = rx_session_empty_local()
session = struct();
session.known = false;
session.totalPayloadBits = NaN;
session.totalPackets = NaN;
session.totalDataPackets = NaN;
session.meta = struct();
end

function session = local_init_rx_session_local(p, metaTx, nPackets)
session = rx_session_empty_local();
if ~session_header_enabled(p.frame)
    session = learn_rx_session_local(local_preshared_session_meta_local(metaTx, nPackets));
end
end

function session = learn_rx_session_local(metaRx)
session = rx_session_empty_local();
session.known = true;
session.totalPayloadBits = double(metaRx.totalPayloadBytes) * 8;
session.totalPackets = double(metaRx.totalPackets);
session.totalDataPackets = double(metaRx.totalDataPackets);
session.meta = metaRx;
end

function metaOut = local_preshared_session_meta_local(metaTx, nPackets)
metaOut = metaTx;
metaOut.totalPayloadBytes = uint32(metaTx.payloadBytes);
if ~isfield(metaOut, "totalDataPackets")
    metaOut.totalDataPackets = uint16(nPackets);
end
if ~isfield(metaOut, "totalPackets")
    metaOut.totalPackets = uint16(nPackets);
end
if ~isfield(metaOut, "rsDataPacketsPerBlock")
    metaOut.rsDataPacketsPerBlock = metaOut.totalDataPackets;
end
if ~isfield(metaOut, "rsParityPacketsPerBlock")
    metaOut.rsParityPacketsPerBlock = uint16(0);
end
end

function state = derive_rx_packet_state_local(p, pktIdx, packetDataBitsLen)
if nargin < 3 || isempty(packetDataBitsLen) || ~isfinite(packetDataBitsLen)
    packetDataBitsLen = local_fixed_packet_data_bits_len_local(p, pktIdx);
end
packetDataBitsLen = max(0, round(double(packetDataBitsLen)));
bitsPerSym = bits_per_symbol_local(p.mod);
fecCodedBitsLen = coded_bits_length_local(packetDataBitsLen, p.fec);
[codedBitsInt, intState] = interleave_bits(zeros(fecCodedBitsLen, 1, "uint8"), p.interleaver);
nDemodSym = ceil(numel(codedBitsInt) / bitsPerSym);
offsets = derive_packet_state_offsets(p, pktIdx);
dsssCfg = derive_packet_dsss_cfg(p.dsss, pktIdx, offsets.dsssOffsetChips, nDemodSym);
nDataSym = dsss_symbol_count(nDemodSym, dsssCfg);

state = struct();
state.packetIndex = pktIdx;
state.packetDataBitsLen = packetDataBitsLen;
state.packetDataBytes = ceil(packetDataBitsLen / 8);
state.fecCodedBitsLen = fecCodedBitsLen;
state.codedBitsLen = numel(codedBitsInt);
state.nDemodSym = nDemodSym;
state.nDataSym = nDataSym;
state.intState = intState;
state.stateOffsets = offsets;
state.scrambleCfg = derive_packet_scramble_cfg(p.scramble, pktIdx, offsets.scrambleOffsetBits);
state.dsssCfg = dsssCfg;
state.fhCfg = derive_packet_fh_cfg(p.fh, pktIdx, offsets.fhOffsetHops, nDataSym);
state.hopInfo = hop_info_from_fh_cfg_local(state.fhCfg, nDataSym);
end

function [payloadPktRx, sessionOut, packetInfo, ok] = recover_payload_packet_local(packetDataBitsRx, phyHeader, sessionIn, p)
payloadPktRx = uint8([]);
sessionOut = sessionIn;
packetInfo = struct();
packetInfo.packetIndex = double(phyHeader.packetIndex);
packetInfo.sourcePacketIndex = 0;
packetInfo.isDataPacket = false;
packetInfo.isParityPacket = false;
packetInfo.range = struct('startBit', 1, 'endBit', 0, 'nBits', 0);

packetDataBitsLen = local_packet_data_bits_len_from_header_local(p, double(phyHeader.packetIndex), phyHeader);
packetDataBitsRx = fit_bits_length(packetDataBitsRx, packetDataBitsLen);
ok = packet_data_crc_valid_local(packetDataBitsRx, phyHeader, p);
if ~ok
    return;
end

packetIndex = double(phyHeader.packetIndex);
if phyHeader.hasSessionHeader
    [metaSession, payloadPktRx, okSession] = parse_session_header_bits(packetDataBitsRx, p.frame);
    allowSessionRefresh = packet_has_session_header(p.frame, packetIndex);
    ok = ok && okSession && allowSessionRefresh;
    if ok && isfield(sessionIn, "known") && sessionIn.known
        ok = session_meta_compatible_local(sessionIn.meta, metaSession);
    end
    if ~ok
        return;
    end
    sessionOut = learn_rx_session_local(metaSession);
else
    if ~(isfield(sessionIn, "known") && sessionIn.known)
        ok = false;
        return;
    end
    payloadPktRx = packetDataBitsRx;
end

ok = ok && packet_index_valid_local(packetIndex, sessionOut);
if ~ok
    return;
end

packetRole = packet_role_from_session_meta(sessionOut.meta, packetIndex);
packetInfo.packetIndex = packetIndex;
packetInfo.sourcePacketIndex = double(packetRole.sourcePacketIndex);
packetInfo.isDataPacket = logical(packetRole.isDataPacket);
packetInfo.isParityPacket = logical(packetRole.isParityPacket);
if packetRole.isDataPacket
    packetInfo.range = derive_packet_range_from_meta_local(sessionOut.meta, double(packetRole.sourcePacketIndex), p);
    if packetInfo.range.nBits <= 0
        ok = false;
        return;
    end
    payloadPktRx = fit_bits_length(payloadPktRx, packetInfo.range.nBits);
end
end

function ok = packet_data_crc_valid_local(packetDataBitsRx, phyHeader, p)
needBits = local_packet_data_bits_len_from_header_local(p, double(phyHeader.packetIndex), phyHeader);
if numel(packetDataBitsRx) < needBits
    ok = false;
    return;
end
crcNow = crc16_ccitt_bits(packetDataBitsRx(1:needBits));
ok = uint16(phyHeader.packetDataCrc16) == uint16(crcNow);
end

function nBits = local_packet_data_bits_len_from_header_local(p, pktIdx, phyHeader)
if isfield(phyHeader, "packetDataBytes") && double(phyHeader.packetDataBytes) > 0
    nBits = double(phyHeader.packetDataBytes) * 8;
else
    nBits = local_fixed_packet_data_bits_len_local(p, pktIdx);
end
end

function nBits = local_fixed_packet_data_bits_len_local(p, pktIdx)
offsets = derive_packet_state_offsets(p, pktIdx);
nBits = double(offsets.nominalPayloadBits);
if offsets.hasSessionHeader
    nBits = nBits + double(offsets.sessionHeaderLenBits);
end
end

function ok = packet_index_valid_local(packetIndex, session)
ok = packetIndex >= 1;
if ok && isfield(session, "known") && session.known
    ok = packetIndex <= double(session.totalPackets);
end
end

function ok = session_meta_compatible_local(metaA, metaB)
fields = ["rows", "cols", "channels", "bitsPerPixel", ...
    "totalPayloadBytes", "totalDataPackets", "totalPackets", ...
    "rsDataPacketsPerBlock", "rsParityPacketsPerBlock"];
ok = true;
for k = 1:numel(fields)
    if ~isfield(metaA, fields(k)) || ~isfield(metaB, fields(k))
        ok = false;
        return;
    end
    ok = ok && double(metaA.(fields(k))) == double(metaB.(fields(k)));
end
end

function range = derive_packet_range_from_meta_local(metaRx, pktIdx, p)
nominalPayloadBits = nominal_payload_bits_local(p);
totalPackets = double(metaRx.totalDataPackets);
totalPayloadBits = double(metaRx.totalPayloadBytes) * 8;

range = struct();
if totalPackets <= 1 || nominalPayloadBits <= 0
    range.startBit = 1;
    range.nBits = totalPayloadBits;
else
    range.startBit = (pktIdx - 1) * nominalPayloadBits + 1;
    if pktIdx < totalPackets
        range.nBits = nominalPayloadBits;
    else
        range.nBits = totalPayloadBits - nominalPayloadBits * (totalPackets - 1);
    end
end
range.nBits = max(0, round(double(range.nBits)));
range.endBit = range.startBit + range.nBits - 1;
end

function layout = derive_packet_layout_local(totalPayloadBits, p)
totalPayloadBits = max(0, round(double(totalPayloadBits)));
nominalPayloadBits = nominal_payload_bits_local(p);
if totalPayloadBits <= 0
    layout = struct('startBit', 1, 'endBit', 0);
    return;
end
if nominalPayloadBits <= 0
    layout = struct('startBit', 1, 'endBit', totalPayloadBits);
    return;
end

nPacketsLocal = max(1, ceil(totalPayloadBits / nominalPayloadBits));
layout = repmat(struct('startBit', 1, 'endBit', 0), nPacketsLocal, 1);
for pktIdx = 1:nPacketsLocal
    startBit = (pktIdx - 1) * nominalPayloadBits + 1;
    endBit = min(pktIdx * nominalPayloadBits, totalPayloadBits);
    layout(pktIdx).startBit = startBit;
    layout(pktIdx).endBit = endBit;
end
end

function payloadBitsOut = local_prepare_plain_packet_payload_local( ...
    payloadBitsIn, pktIdx, packetIndependentBitChaos, chaosEnabled, chaosEncBase, assumption, approxDelta)
payloadBitsOut = uint8(payloadBitsIn(:) ~= 0);
if ~(packetIndependentBitChaos && chaosEnabled)
    return;
end

assumption = lower(string(assumption));
if assumption == "none"
    return;
end

infoUse = local_tx_packet_chaos_info_local(chaosEncBase, pktIdx, numel(payloadBitsOut));
if assumption == "wrong_key"
    infoUse = perturb_chaos_enc_info(infoUse, local_wrong_key_delta_local(pktIdx));
elseif assumption == "approximate"
    infoUse = perturb_chaos_enc_info(infoUse, approxDelta);
elseif assumption ~= "known"
    error("Unknown packet chaos assumption: %s", assumption);
end

payloadBitsOut = chaos_decrypt_bits(payloadBitsOut, infoUse);
end

function infoUse = local_tx_packet_chaos_info_local(encBase, pktIdx, nValidBits)
encPkt = derive_packet_chaos_cfg(encBase, pktIdx);
infoUse = struct();
infoUse.enabled = true;
infoUse.mode = "payload_bits";
infoUse.chaosMethod = string(encPkt.chaosMethod);
infoUse.chaosParams = encPkt.chaosParams;
infoUse.diffusionRounds = encPkt.diffusionRounds;
infoUse.nBytes = uint32(ceil(double(nValidBits) / 8));
infoUse.nValidBits = uint32(nValidBits);
end

function payloadBitsOut = decrypt_payload_packets_rx_local(payloadBitsIn, packetOk, p, totalPayloadBits, assumption, approxDelta)
payloadBitsOut = uint8(payloadBitsIn(:) ~= 0);
layout = derive_packet_layout_local(totalPayloadBits, p);
ok = normalize_packet_ok(packetOk, numel(layout));
assumption = lower(string(assumption));

for pktIdx = 1:numel(layout)
    if ~ok(pktIdx)
        continue;
    end
    if assumption == "none"
        continue;
    end

    seg = payloadBitsOut(layout(pktIdx).startBit:layout(pktIdx).endBit);
    infoUse = packet_chaos_info_local(p.chaosEncrypt, pktIdx, numel(seg));
    if assumption == "wrong_key"
        infoUse = perturb_chaos_enc_info(infoUse, local_wrong_key_delta_local(pktIdx));
    elseif assumption == "approximate"
        infoUse = perturb_chaos_enc_info(infoUse, approxDelta);
    elseif assumption ~= "known"
        error("Unknown chaos assumption: %s", assumption);
    end
    segDec = chaos_decrypt_bits(seg, infoUse);
    payloadBitsOut(layout(pktIdx).startBit:layout(pktIdx).endBit) = fit_bits_length(segDec, numel(seg));
end
end

function infoUse = packet_chaos_info_local(encBase, pktIdx, nValidBits)
encPkt = derive_packet_chaos_cfg(encBase, pktIdx);
infoUse = struct();
infoUse.enabled = true;
infoUse.mode = "payload_bits";
infoUse.chaosMethod = string(encPkt.chaosMethod);
infoUse.chaosParams = encPkt.chaosParams;
infoUse.diffusionRounds = encPkt.diffusionRounds;
infoUse.nBytes = uint32(ceil(double(nValidBits) / 8));
infoUse.nValidBits = uint32(nValidBits);
end

function delta = local_wrong_key_delta_local(pktIdx)
delta = 7e-10 * (double(pktIdx) + 1);
end

function scrambleCfg = eve_scramble_cfg_local(scrambleBase, assumption)
scrambleCfg = scrambleBase;
switch lower(string(assumption))
    case "known"
    case "none"
        scrambleCfg.enable = false;
    case "wrong_key"
        if isfield(scrambleCfg, "enable") && scrambleCfg.enable && isfield(scrambleCfg, "pnInit") && ~isempty(scrambleCfg.pnInit)
            scrambleCfg.pnInit = circshift(scrambleCfg.pnInit, 1);
            if all(scrambleCfg.pnInit == 0)
                scrambleCfg.pnInit(end) = 1;
            end
        else
            scrambleCfg.enable = false;
        end
    otherwise
        error("Unknown eve scramble assumption: %s", string(assumption));
end
end

function hopInfo = hop_info_from_fh_cfg_local(fhCfg, nSym)
if ~isfield(fhCfg, "enable") || ~fhCfg.enable
    hopInfo = struct('enable', false);
    return;
end
if fh_is_fast(fhCfg)
    hopInfo = struct('enable', false);
    return;
end
[~, hopInfo] = fh_modulate(complex(zeros(nSym, 1)), fhCfg);
end

function hopInfo = eve_hop_info_local(rxState, assumption)
switch lower(string(assumption))
    case "known"
        hopInfo = rxState.hopInfo;
    case "none"
        hopInfo = struct('enable', false);
    case "partial"
        fhEve = make_partial_fh_config(rxState.fhCfg);
        hopInfo = hop_info_from_fh_cfg_local(fhEve, rxState.nDataSym);
    otherwise
        error("Unknown eve fh assumption: %s", string(assumption));
end
end

function hopInfo = local_nominal_hop_info_local(rxState, fhAssumption)
fhAssumption = lower(string(fhAssumption));
switch fhAssumption
    case "known"
        hopInfo = rxState.hopInfo;
    case {"none", "partial"}
        hopInfo = eve_hop_info_local(rxState, fhAssumption);
    otherwise
        error("Unknown nominal fh assumption: %s", string(fhAssumption));
end
end

function y = fit_complex_length_local(x, targetLen)
x = x(:);
targetLen = max(0, round(double(targetLen)));
if numel(x) >= targetLen
    y = x(1:targetLen);
else
    y = [x; complex(zeros(targetLen - numel(x), 1))];
end
end

function nBits = nominal_payload_bits_local(p)
if isfield(p, "packet") && isstruct(p.packet) && isfield(p.packet, "enable") && p.packet.enable
    if isfield(p.packet, "payloadBitsPerPacket") && ~isempty(p.packet.payloadBitsPerPacket)
        nBits = max(8, round(double(p.packet.payloadBitsPerPacket)));
    else
        nBits = 4096;
    end
    nBits = 8 * floor(nBits / 8);
else
    nBits = 0;
end
end

function ctrl = init_packet_sync_ctrl_local()
ctrl = struct();
ctrl.forceLongSearch = true;
ctrl.shortSyncMisses = 0;
end

function chOut = local_freeze_channel_realization_local(chIn)
% Freeze one packet-independent channel realization per simulated frame.
%
% default_params documents Rayleigh taps as "每帧随机". The main packet loop
% calls channel_bg_impulsive once per packet, so we explicitly materialize the
% random multipath coefficients here to avoid re-randomizing them on every
% packet within the same frame.
chOut = chIn;

if ~isfield(chOut, "multipath") || ~isstruct(chOut.multipath) ...
        || ~isfield(chOut.multipath, "enable") || ~chOut.multipath.enable
    return;
end
if ~isfield(chOut.multipath, "pathGainsDb") || isempty(chOut.multipath.pathGainsDb)
    error("multipath启用时需提供pathGainsDb。");
end

gDb = double(chOut.multipath.pathGainsDb(:));
amp = 10.^(gDb / 20);
if isfield(chOut.multipath, "rayleigh") && chOut.multipath.rayleigh
    cplxAmp = amp .* (randn(size(amp)) + 1j * randn(size(amp))) / sqrt(2);
    chOut.multipath.pathGainsDb = 20 * log10(max(abs(cplxAmp), 1e-12));
    chOut.multipath.pathPhasesRad = angle(cplxAmp);
    chOut.multipath.rayleigh = false;
elseif ~isfield(chOut.multipath, "pathPhasesRad") || isempty(chOut.multipath.pathPhasesRad)
    chOut.multipath.pathPhasesRad = 2 * pi * rand(size(amp));
end
end

function [startIdx, rxSync, syncSymUse, ctrl, ok] = acquire_packet_sync_local(rx, syncCfgUse, p, pktIdx, firstSyncSym, shortSyncSym, ctrl)
startIdx = [];
rxSync = rx;
syncSymUse = firstSyncSym;
ok = false;
if nargin < 7 || isempty(ctrl)
    ctrl = init_packet_sync_ctrl_local();
end

isLongPkt = is_long_sync_packet(p.frame, pktIdx);
if ctrl.forceLongSearch
    candidateKinds = "long";
elseif isLongPkt
    candidateKinds = "long";
else
    candidateKinds = "short";
end

for k = 1:numel(candidateKinds)
    kind = candidateKinds(k);
    if kind == "long"
        syncTry = firstSyncSym;
    else
        syncTry = shortSyncSym;
    end
    [startTry, rxTry] = frame_sync(rx, syncTry, syncCfgUse);
    if ~isempty(startTry)
        startIdx = startTry;
        rxSync = rxTry;
        syncSymUse = syncTry(:);
        ok = true;
        ctrl.shortSyncMisses = 0;
        if kind == "long"
            ctrl.forceLongSearch = false;
        end
        return;
    end
end

if isLongPkt
    ctrl.forceLongSearch = true;
    ctrl.shortSyncMisses = 0;
else
    ctrl.shortSyncMisses = ctrl.shortSyncMisses + 1;
    if ctrl.shortSyncMisses >= max_short_sync_misses_local(syncCfgUse)
        ctrl.forceLongSearch = true;
    end
end
end

function n = max_short_sync_misses_local(rxSync)
n = 2;
if isfield(rxSync, "maxShortSyncMisses") && ~isempty(rxSync.maxShortSyncMisses)
    n = max(1, round(double(rxSync.maxShortSyncMisses)));
end
end

function nBits = coded_bits_length_local(nInfoBits, fec)
nBits = fec_coded_bits_length(nInfoBits, fec);
end

function nSym = local_rx_demod_symbol_count_local(rxState)
nSym = double(rxState.nDataSym);
if isfield(rxState, "nDemodSym") && ~isempty(rxState.nDemodSym)
    nSym = double(rxState.nDemodSym);
end
nSym = max(0, round(nSym));
end

function bitsPerSym = bits_per_symbol_local(mod)
switch upper(string(mod.type))
    case "BPSK"
        bitsPerSym = 1;
    case "QPSK"
        bitsPerSym = 2;
    case "MSK"
        bitsPerSym = 1;
    otherwise
        error("Unsupported modulation for receiver state derivation: %s", mod.type);
end
end

function budgetOut = local_offset_budget_from_base_local(baseBudget, offsetDb)
offsetDb = double(offsetDb);
if ~isscalar(offsetDb) || ~isfinite(offsetDb)
    error("链路增益偏移必须是有限标量。");
end

gainScaleLin = 10 .^ (offsetDb / 10);
budgetOut = struct( ...
    "txPowerDb", baseBudget.txPowerDb, ...
    "txPowerLin", baseBudget.txPowerLin, ...
    "linkGainDb", baseBudget.linkGainDb + offsetDb, ...
    "linkGainLin", baseBudget.linkGainLin .* gainScaleLin, ...
    "rxAmplitudeScale", baseBudget.rxAmplitudeScale .* sqrt(gainScaleLin), ...
    "rxPowerLin", baseBudget.rxPowerLin .* gainScaleLin, ...
    "noisePsdLin", baseBudget.noisePsdLin, ...
    "ebN0Lin", baseBudget.ebN0Lin .* gainScaleLin, ...
    "ebN0dB", baseBudget.ebN0dB + offsetDb, ...
    "jsrDb", baseBudget.jsrDb, ...
    "snrIndex", baseBudget.snrIndex, ...
    "jsrIndex", baseBudget.jsrIndex);
end

function tf = local_channel_has_enabled_jammer_local(channelCfg)
if ~isstruct(channelCfg)
    error("channel 配置必须是标量struct。");
end
[totalWeight, ~] = local_channel_weight_budget_local(channelCfg);
tf = totalWeight > 0;
end

function channelOut = local_scale_channel_for_jsr_local(channelCfg, signalPowerLin, N0, jsrDb, waveformCfg)
signalPowerLin = double(signalPowerLin);
N0 = double(N0);
jsrDb = double(jsrDb);
if ~isscalar(signalPowerLin) || ~isfinite(signalPowerLin) || signalPowerLin <= 0
    error("signalPowerLin 必须是正有限标量。");
end
if ~isscalar(N0) || ~isfinite(N0) || N0 <= 0
    error("N0 必须是正有限标量。");
end
if ~isscalar(jsrDb) || ~isfinite(jsrDb)
    error("jsrDb 必须是有限标量。");
end
if ~(isstruct(waveformCfg) && isfield(waveformCfg, "sps"))
    error("waveformCfg 必须提供有效的sps字段。");
end

channelOut = channelCfg;
targetJammerPower = signalPowerLin * 10 .^ (jsrDb / 10);
[totalWeight, detail] = local_channel_weight_budget_local(channelCfg);
if totalWeight <= 0
    error("启用JSR扫描时，至少需要一个启用且权重大于0的干扰源。");
end

if detail.impulseActive
    avgImpulsePower = targetJammerPower * detail.impulseWeight / totalWeight;
    impulseProbSample = local_impulse_probability_for_power_budget_local(channelCfg, waveformCfg);
    if ~(isfinite(impulseProbSample) && impulseProbSample > 0)
        error("impulseWeight>0 时，channel.impulseProb 必须为正有限数。");
    end
    channelOut.impulseToBgRatio = avgImpulsePower / max(impulseProbSample * N0, eps);
else
    channelOut.impulseToBgRatio = 0;
end

sourceNames = ["singleTone" "narrowband" "sweep"];
for k = 1:numel(sourceNames)
    sourceName = sourceNames(k);
    if ~detail.(sourceName + "Active")
        continue;
    end
    channelOut.(sourceName).power = targetJammerPower * detail.(sourceName + "Weight") / totalWeight;
end
end

function impulseProbSample = local_impulse_probability_for_power_budget_local(channelCfg, waveformCfg)
if ~isfield(channelCfg, "impulseProb") || isempty(channelCfg.impulseProb)
    error("channel.impulseProb 缺失。");
end
impulseProbSym = double(channelCfg.impulseProb);
if ~(isscalar(impulseProbSym) && isfinite(impulseProbSym) && impulseProbSym > 0 && impulseProbSym <= 1)
    error("channel.impulseProb 必须是 (0, 1] 范围内的有限标量。");
end

sps = double(waveformCfg.sps);
if ~(isscalar(sps) && isfinite(sps) && sps >= 1 && abs(sps - round(sps)) < 1e-12)
    error("waveform.sps 必须是正整数。");
end
sps = round(sps);

impulseProbSample = 1 - (1 - impulseProbSym) .^ (1 / sps);
if ~(isfinite(impulseProbSample) && impulseProbSample > 0 && impulseProbSample <= 1)
    error("由channel.impulseProb和waveform.sps推导出的采样级脉冲概率无效。");
end
end

function [totalWeight, detail] = local_channel_weight_budget_local(channelCfg)
detail = struct( ...
    "impulseActive", false, ...
    "singleToneActive", false, ...
    "narrowbandActive", false, ...
    "sweepActive", false, ...
    "impulseWeight", 0, ...
    "singleToneWeight", 0, ...
    "narrowbandWeight", 0, ...
    "sweepWeight", 0);

totalWeight = 0;

impulseProb = 0;
if isfield(channelCfg, "impulseProb") && ~isempty(channelCfg.impulseProb)
    impulseProb = max(double(channelCfg.impulseProb), 0);
end
impulseWeight = 0;
if isfield(channelCfg, "impulseWeight") && ~isempty(channelCfg.impulseWeight)
    impulseWeight = max(double(channelCfg.impulseWeight), 0);
end
if impulseWeight > 0
    if impulseProb <= 0
        error("channel.impulseWeight>0 时，channel.impulseProb 必须为正。");
    end
    detail.impulseActive = true;
    detail.impulseWeight = impulseWeight;
    totalWeight = totalWeight + impulseWeight;
end

sourceNames = ["singleTone" "narrowband" "sweep"];
for k = 1:numel(sourceNames)
    sourceName = sourceNames(k);
    if ~isfield(channelCfg, sourceName) || ~isstruct(channelCfg.(sourceName))
        continue;
    end
    cfg = channelCfg.(sourceName);
    enableNow = isfield(cfg, "enable") && cfg.enable;
    weightNow = local_interference_weight_local(cfg, "channel." + sourceName);
    if enableNow
        if weightNow <= 0
            error("%s.enable=true 时，%s.weight 必须为正。", sourceName, sourceName);
        end
        detail.(sourceName + "Active") = true;
        detail.(sourceName + "Weight") = weightNow;
        totalWeight = totalWeight + weightNow;
    end
end
end

function weight = local_interference_weight_local(cfg, cfgName)
weight = 0;
if ~isfield(cfg, "weight") || isempty(cfg.weight)
    return;
end
weight = double(cfg.weight);
if ~isscalar(weight) || ~isfinite(weight) || weight < 0
    error("%s.weight 必须是非负有限标量。", char(string(cfgName)));
end
end

function [wardenBudget, referenceLink] = local_resolve_warden_budget_local(bobBudget, eveBudget, eveEnabled, wardenCfg)
referenceLink = "bob";
if isfield(wardenCfg, "referenceLink")
    referenceLink = lower(string(wardenCfg.referenceLink));
end

switch referenceLink
    case "bob"
        wardenBudget = bobBudget;
    case "eve"
        if eveEnabled && ~isempty(fieldnames(eveBudget))
            wardenBudget = eveBudget;
        else
            referenceLink = "bob";
            wardenBudget = bobBudget;
        end
    case "independent"
        local_require_struct_field_local(wardenCfg, "linkGainOffsetDb", "covert.warden");
        wardenBudget = local_offset_budget_from_base_local(bobBudget, double(wardenCfg.linkGainOffsetDb));
    otherwise
        error("Unknown covert.warden.referenceLink: %s", string(wardenCfg.referenceLink));
end
end

function w = local_pack_warden_results(detCells, bobEbN0dBList, wardenEbN0dBList, referenceLink)
firstIdx = find(~cellfun(@isempty, detCells), 1, 'first');
if isempty(firstIdx)
    error("Warden enabled but no detector outputs were collected.");
end

template = detCells{firstIdx};
w = struct();
w.primaryLayer = template.primaryLayer;
w.referenceLink = string(referenceLink);
w.pfaTarget = template.pfaTarget;
w.nObs = local_collect_scalar_series(detCells, "nObs");
w.nTrials = template.nTrials;
w.ebN0dB = bobEbN0dBList;
w.wardenEbN0dB = wardenEbN0dBList;
w.layers = struct();
w.layers.energyNp = local_collect_warden_layer(detCells, "energyNp");
w.layers.energyOpt = local_collect_warden_layer(detCells, "energyOpt");
w.layers.energyOptUncertain = local_collect_warden_layer(detCells, "energyOptUncertain");
w.layers.energyFhNarrow = local_collect_warden_layer(detCells, "energyFhNarrow");
w.layers.cyclostationaryOpt = local_collect_warden_layer(detCells, "cyclostationaryOpt");

np = w.layers.energyNp;
w.threshold = np.threshold;
w.pfaEst = np.pfa;
w.pdEst = np.pd;
w.pmdEst = np.pmd;
w.xiEst = np.xi;
w.peEst = np.pe;

opt = w.layers.energyOpt;
w.thresholdOpt = opt.threshold;
w.pfaOpt = opt.pfa;
w.pdOpt = opt.pd;
w.pmdOpt = opt.pmd;
w.xiOpt = opt.xi;
w.peOpt = opt.pe;

unc = w.layers.energyOptUncertain;
w.thresholdUncertain = unc.threshold;
w.pfaUncertain = unc.pfa;
w.pdUncertain = unc.pd;
w.pmdUncertain = unc.pmd;
w.xiUncertain = unc.xi;
w.peUncertain = unc.pe;
end

function values = local_collect_scalar_series(detCells, fieldName)
values = nan(1, numel(detCells));
for i = 1:numel(detCells)
    values(i) = detCells{i}.(fieldName);
end
end

function layer = local_collect_warden_layer(detCells, layerName)
layerName = char(string(layerName));
template = detCells{find(~cellfun(@isempty, detCells), 1, 'first')}.layers.(layerName);
nPoints = numel(detCells);

layer = struct();
layer.name = template.name;
layer.criterion = template.criterion;
layer.referenceLink = template.referenceLink;
layer.noiseUncertaintyDb = template.noiseUncertaintyDb;
layer.pfaTarget = template.pfaTarget;
layer.nObs = nan(1, nPoints);
layer.delayMaxSamples = nan(1, nPoints);
layer.thresholdScanCount = nan(1, nPoints);
layer.threshold = nan(1, nPoints);
layer.pfa = nan(1, nPoints);
layer.pd = nan(1, nPoints);
layer.pmd = nan(1, nPoints);
layer.xi = nan(1, nPoints);
layer.pe = nan(1, nPoints);

for i = 1:nPoints
    point = detCells{i}.layers.(layerName);
    layer.nObs(i) = point.nObs;
    layer.delayMaxSamples(i) = point.delayMaxSamples;
    layer.thresholdScanCount(i) = point.thresholdScanCount;
    layer.threshold(i) = point.threshold;
    layer.pfa(i) = point.pfa;
    layer.pd(i) = point.pd;
    layer.pmd(i) = point.pmd;
    layer.xi(i) = point.xi;
    layer.pe(i) = point.pe;
end
end

function tf = local_sync_enabled_local(rxSyncCfg)
dllEnabled = isfield(rxSyncCfg, "timingDll") && isfield(rxSyncCfg.timingDll, "enable") ...
    && rxSyncCfg.timingDll.enable;
tf = rxSyncCfg.compensateCarrier || rxSyncCfg.fineSearchRadius > 0 || ...
    rxSyncCfg.enableFractionalTiming || rxSyncCfg.carrierPll.enable || dllEnabled;
end

function eveCfg = local_validate_eve_config_local(eveCfg, methodsMain, channelCfg)
local_require_struct_field_local(eveCfg, "linkGainOffsetDb", "eve");
local_require_struct_field_local(eveCfg, "scrambleAssumption", "eve");
local_require_struct_field_local(eveCfg, "fhAssumption", "eve");
local_require_struct_field_local(eveCfg, "chaosAssumption", "eve");
local_require_struct_field_local(eveCfg, "chaosApproxDelta", "eve");
local_require_struct_field_local(eveCfg, "rxSync", "eve");
local_require_struct_field_local(eveCfg, "mitigation", "eve");

if ~isscalar(double(eveCfg.linkGainOffsetDb)) || ~isfinite(double(eveCfg.linkGainOffsetDb))
    error("eve.linkGainOffsetDb 必须是有限标量。");
end
if ~isscalar(double(eveCfg.chaosApproxDelta)) || ~isfinite(double(eveCfg.chaosApproxDelta)) || double(eveCfg.chaosApproxDelta) < 0
    error("eve.chaosApproxDelta 必须是非负有限标量。");
end
if lower(string(eveCfg.chaosAssumption)) == "approximate" && double(eveCfg.chaosApproxDelta) <= 0
    error("当 eve.chaosAssumption=""approximate"" 时，eve.chaosApproxDelta 必须大于 0。");
end
if ~isstruct(eveCfg.rxSync) || ~isscalar(eveCfg.rxSync)
    error("eve.rxSync 必须是标量struct。");
end
if ~isstruct(eveCfg.mitigation) || ~isscalar(eveCfg.mitigation)
    error("eve.mitigation 必须是标量struct。");
end

local_require_struct_fields_local(eveCfg.rxSync, [ ...
    "fineSearchRadius", "compensateCarrier", "equalizeAmplitude", ...
    "enableFractionalTiming", "fractionalRange", "fractionalStep", ...
    "estimateCfo", "minCorrPeakToMedian", "minCorrPeakToSecond", ...
    "corrExclusionRadius", "maxShortSyncMisses", "carrierPll", ...
    "multipathEq", "timingDll"], "eve.rxSync");
local_require_struct_fields_local(eveCfg.rxSync.carrierPll, ...
    ["enable", "alpha", "beta", "maxFreq"], "eve.rxSync.carrierPll");
local_require_struct_fields_local(eveCfg.rxSync.multipathEq, ...
    ["enable", "method", "nTaps", "lambdaFactor"], "eve.rxSync.multipathEq");
local_require_struct_fields_local(eveCfg.rxSync.timingDll, ...
    ["enable", "earlyLateSpacing", "alpha", "beta", "maxOffset", "decisionDirected"], "eve.rxSync.timingDll");

local_require_struct_fields_local(eveCfg.mitigation, [ ...
    "methods", "thresholdStrategy", "thresholdAlpha", "thresholdFixed", ...
    "fftNotch", "fftBandstop", "adaptiveNotch", "stftNotch", ...
    "adaptiveFrontend", "binding", "thresholdCalibration", "selector", ...
    "strictModelLoad", "requireTrainedModels", "ml", "mlCnn", "mlGru"], "eve.mitigation");
local_require_struct_fields_local(eveCfg.mitigation.thresholdCalibration, [ ...
    "enable", "methods", "targetCleanPfa", "thresholdMinScale", ...
    "thresholdMaxScale", "minThresholdAbs", "maxThresholdAbs", ...
    "bufferMaxSamples", "minBufferSamples", "minPreambleTrustedSamples", ...
    "minPacketTrustedSamples", "preambleUpdateAlpha", "packetUpdateAlpha", ...
    "preambleResidualAlpha", "packetResidualAlpha"], "eve.mitigation.thresholdCalibration");
local_require_struct_fields_local(eveCfg.mitigation.adaptiveFrontend, [ ...
    "bootstrapSyncChain", "classNames", "classToAction", "diagnostics"], ...
    "eve.mitigation.adaptiveFrontend");

methodsEve = resolve_mitigation_methods(eveCfg.mitigation, channelCfg);
if ~isequal(methodsEve, methodsMain)
    error("eve.mitigation.methods 必须与 p.mitigation.methods 完全一致。");
end
eveCfg.mitigation.methods = methodsEve;
end

function local_require_presync_mitigation_cfg_local(mitigationCfg, ownerName)
if ~isfield(mitigationCfg, "thresholdCalibration") || ~isstruct(mitigationCfg.thresholdCalibration)
    error("%s.thresholdCalibration 缺失。", ownerName);
end
if isfield(mitigationCfg.thresholdCalibration, "enable") && mitigationCfg.thresholdCalibration.enable
    error("%s.thresholdCalibration.enable 必须为 false。抑制模块前移到同步前后，不支持在线阈值校准。", ownerName);
end
end

function local_require_struct_field_local(s, fieldName, ownerName)
if ~isstruct(s) || ~isfield(s, fieldName)
    error("%s 缺少字段 %s。", ownerName, fieldName);
end
end

function local_require_struct_fields_local(s, fieldNames, ownerName)
if ~isstruct(s) || ~isscalar(s)
    error("%s 必须是标量struct。", ownerName);
end
for k = 1:numel(fieldNames)
    if ~isfield(s, fieldNames(k))
        error("%s 缺少字段 %s。", ownerName, fieldNames(k));
    end
end
end

function summary = local_pack_rx_sync_summary_local(rxSyncCfg)
summary = struct( ...
    "fineSearchRadius", double(rxSyncCfg.fineSearchRadius), ...
    "compensateCarrier", logical(rxSyncCfg.compensateCarrier), ...
    "equalizeAmplitude", logical(rxSyncCfg.equalizeAmplitude), ...
    "enableFractionalTiming", logical(rxSyncCfg.enableFractionalTiming), ...
    "estimateCfo", logical(rxSyncCfg.estimateCfo), ...
    "maxShortSyncMisses", double(rxSyncCfg.maxShortSyncMisses), ...
    "carrierPllEnable", logical(rxSyncCfg.carrierPll.enable), ...
    "multipathEqEnable", logical(rxSyncCfg.multipathEq.enable), ...
    "timingDllEnable", logical(rxSyncCfg.timingDll.enable));
end

function summary = local_pack_mitigation_summary_local(mitigationCfg)
summary = struct( ...
    "methods", string(mitigationCfg.methods(:).'), ...
    "thresholdStrategy", string(mitigationCfg.thresholdStrategy), ...
    "thresholdAlpha", double(mitigationCfg.thresholdAlpha), ...
    "thresholdFixed", double(mitigationCfg.thresholdFixed), ...
    "thresholdCalibrationEnable", logical(mitigationCfg.thresholdCalibration.enable), ...
    "requireTrainedModels", logical(mitigationCfg.requireTrainedModels));
end
