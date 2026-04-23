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
[mitigationMethods, activeInterferenceTypes, allowedMethods] = resolve_mitigation_methods(bobMitigation, p.channel);
bobMitigation.methods = mitigationMethods;
p.mitigation.methods = mitigationMethods;
receiverMethodPlan = local_build_receiver_method_plan_local(mitigationMethods, p.channel, bobRxSync);
methods = receiverMethodPlan.labels;
methodActions = receiverMethodPlan.mitigationMethods;
methodEqualizers = receiverMethodPlan.equalizerMethods;

%% 发送端（TRANSMITTER）

[imgTx, imgTxOriginal] = load_source_image(p.source);

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
mseResizedCommVals = nan(numel(methods), numel(EbN0dBList)); % 接收图与缩小尺寸参考图的通信态MSE
psnrResizedCommVals = nan(numel(methods), numel(EbN0dBList));
ssimResizedCommVals = nan(numel(methods), numel(EbN0dBList));
mseResizedCompVals = nan(numel(methods), numel(EbN0dBList)); % 接收图与缩小尺寸参考图的补偿态MSE
psnrResizedCompVals = nan(numel(methods), numel(EbN0dBList));
ssimResizedCompVals = nan(numel(methods), numel(EbN0dBList));
mseOriginalCommVals = nan(numel(methods), numel(EbN0dBList)); % 接收图恢复原尺寸后与原图的通信态MSE
psnrOriginalCommVals = nan(numel(methods), numel(EbN0dBList));
ssimOriginalCommVals = nan(numel(methods), numel(EbN0dBList));
mseOriginalCompVals = nan(numel(methods), numel(EbN0dBList)); % 接收图恢复原尺寸后与原图的补偿态MSE
psnrOriginalCompVals = nan(numel(methods), numel(EbN0dBList));
ssimOriginalCompVals = nan(numel(methods), numel(EbN0dBList));
klSigVsNoise = nan(1, numel(EbN0dBList)); % KL(P_signal || P_noise)
klNoiseVsSig = nan(1, numel(EbN0dBList)); % KL(P_noise || P_signal)
klSym = nan(1, numel(EbN0dBList)); % 对称KL


example = repmat(struct("EbN0dB", NaN, "methods", struct()), 1, numel(EbN0dBList));

bobRxDiversity = local_validate_rx_diversity_cfg_local(p.rxDiversity, "p.rxDiversity");
eveEnabled = isfield(p, "eve") && isfield(p.eve, "enable") && p.eve.enable;
scrambleAssumptionEve = "";
fhAssumptionEve = "";
chaosAssumptionEve = "";
chaosApproxDeltaEve = NaN;
chaosEncInfoEve = struct('enabled', false, 'mode', "none");
eveEbN0dBList = [];
eveRxSync = struct();
eveRxDiversity = local_disabled_rx_diversity_cfg_local();
eveMitigation = struct();
eveBudget = struct();
if eveEnabled
    eveCfg = local_validate_eve_config_local(p.eve, mitigationMethods, p.channel);
    eveRxSync = eveCfg.rxSync;
    eveRxDiversity = eveCfg.rxDiversity;
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
    mseResizedCommEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrResizedCommEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimResizedCommEveVals = nan(numel(methods), numel(EbN0dBList));
    mseResizedCompEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrResizedCompEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimResizedCompEveVals = nan(numel(methods), numel(EbN0dBList));
    mseOriginalCommEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrOriginalCommEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimOriginalCommEveVals = nan(numel(methods), numel(EbN0dBList));
    mseOriginalCompEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrOriginalCompEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimOriginalCompEveVals = nan(numel(methods), numel(EbN0dBList));
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
    fprintf('[SIM] NOTE: impulse/tone/narrowband/sweep all disabled. Most mitigation methods will behave like ""none"".\n');
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
scFdeEnabled = isfield(p, "scFde") && isstruct(p.scFde) ...
    && isfield(p.scFde, "enable") && logical(p.scFde.enable);
if scFdeEnabled
    scFdeCfgLog = sc_fde_payload_config(p);
    scFdeTxt = sprintf('ON(cp=%d,pilot=%d,data/hop=%d)', ...
        scFdeCfgLog.cpLen, scFdeCfgLog.pilotLength, scFdeCfgLog.dataSymbolsPerHop);
else
    scFdeTxt = 'OFF';
end
fprintf('[SIM] Eve=%s, Warden=%s, FH=%s, DSSS=%s, SC-FDE=%s, Chaos=%s, Pulse=%s, RxSync(B/E)=%s/%s, MP=%s\n', ...
    on_off_text(eveEnabled), on_off_text(wardenEnabled), on_off_text(fhEnabled), ...
    dsssTxt, scFdeTxt, on_off_text(chaosEnabled), pulseTxt, on_off_text(syncEnabledBob), on_off_text(syncEnabledEve), on_off_text(mpEnabled));
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
    metricAccResizedComm = init_image_metric_acc_local(numel(methods));
    metricAccResizedComp = init_image_metric_acc_local(numel(methods));
    metricAccOriginalComm = init_image_metric_acc_local(numel(methods));
    metricAccOriginalComp = init_image_metric_acc_local(numel(methods));
    exampleCandidates = init_example_candidate_bank_local(numel(methods), p.sim.nFramesPerPoint);


    if eveEnabled
        nErrEve = zeros(numel(methods), 1);
        nTotEve = zeros(numel(methods), 1);
        packetFrontEndEveAcc = zeros(numel(methods), 1);
        packetHeaderEveAcc = zeros(numel(methods), 1);
        packetSuccessEveAcc = zeros(numel(methods), 1);
        rawPacketSuccessEveAcc = zeros(numel(methods), 1);
        metricAccResizedCommEve = init_image_metric_acc_local(numel(methods));
        metricAccResizedCompEve = init_image_metric_acc_local(numel(methods));
        metricAccOriginalCommEve = init_image_metric_acc_local(numel(methods));
        metricAccOriginalCompEve = init_image_metric_acc_local(numel(methods));
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

    txPacketsWorker = local_compact_tx_packets_for_rx_local(txPackets);
    sessionFramesWorker = local_compact_session_frames_for_rx_local(sessionFrames);
    pWorker = local_compact_params_for_worker_local(p);
    if useParallelFrames
        fullTxPacketsBytes = local_variable_size_bytes_local(txPackets);
        workerTxPacketsBytes = local_variable_size_bytes_local(txPacketsWorker);
        fullSessionBytes = local_variable_size_bytes_local(sessionFrames);
        workerSessionBytes = local_variable_size_bytes_local(sessionFramesWorker);
        fullParamsBytes = local_variable_size_bytes_local(p);
        workerParamsBytes = local_variable_size_bytes_local(pWorker);
        fprintf('[SIM]     Worker上下文瘦身: txPackets %.2f -> %.2f MB, sessionFrames %.2f -> %.2f MB, params %.2f -> %.2f MB\n', ...
            fullTxPacketsBytes / 1024 / 1024, workerTxPacketsBytes / 1024 / 1024, ...
            fullSessionBytes / 1024 / 1024, workerSessionBytes / 1024 / 1024, ...
            fullParamsBytes / 1024 / 1024, workerParamsBytes / 1024 / 1024);
    end

    frameCtx = struct();
    frameCtx.p = pWorker;
    frameCtx.methods = methods;
    frameCtx.methodActions = methodActions;
    frameCtx.methodEqualizers = methodEqualizers;
    frameCtx.txPackets = txPacketsWorker;
    frameCtx.txPktIndex = txPktIndex;
    frameCtx.txPayloadBits = txPayloadBits;
    frameCtx.sessionFrames = sessionFramesWorker;
    frameCtx.waveform = waveform;
    frameCtx.channelSample = channelSample;
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
    frameCtx.packetConcealActive = packetConcealActive;
    frameCtx.packetConcealMode = packetConcealMode;
    frameCtx.imgTx = imgTx;
    frameCtx.imgTxOriginal = imgTxOriginal;
    frameCtx.meta = meta;
    frameCtx.totalPayloadBits = totalPayloadBits;
    frameCtx.bobRxSync = bobRxSync;
    frameCtx.bobRxDiversity = bobRxDiversity;
    frameCtx.bobMitigation = bobMitigation;
    frameCtx.eveRxSync = eveRxSync;
    frameCtx.eveRxDiversity = eveRxDiversity;
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
            metricAccResizedComm = accumulate_image_metric_acc_local(metricAccResizedComm, im, ...
                bobFrame.metricsResizedComm.mse(im), bobFrame.metricsResizedComm.psnr(im), bobFrame.metricsResizedComm.ssim(im));
            metricAccResizedComp = accumulate_image_metric_acc_local(metricAccResizedComp, im, ...
                bobFrame.metricsResizedComp.mse(im), bobFrame.metricsResizedComp.psnr(im), bobFrame.metricsResizedComp.ssim(im));
            metricAccOriginalComm = accumulate_image_metric_acc_local(metricAccOriginalComm, im, ...
                bobFrame.metricsOriginalComm.mse(im), bobFrame.metricsOriginalComm.psnr(im), bobFrame.metricsOriginalComm.ssim(im));
            metricAccOriginalComp = accumulate_image_metric_acc_local(metricAccOriginalComp, im, ...
                bobFrame.metricsOriginalComp.mse(im), bobFrame.metricsOriginalComp.psnr(im), bobFrame.metricsOriginalComp.ssim(im));
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
                metricAccResizedCommEve = accumulate_image_metric_acc_local(metricAccResizedCommEve, im, ...
                    eveFrame.metricsResizedComm.mse(im), eveFrame.metricsResizedComm.psnr(im), eveFrame.metricsResizedComm.ssim(im));
                metricAccResizedCompEve = accumulate_image_metric_acc_local(metricAccResizedCompEve, im, ...
                    eveFrame.metricsResizedComp.mse(im), eveFrame.metricsResizedComp.psnr(im), eveFrame.metricsResizedComp.ssim(im));
                metricAccOriginalCommEve = accumulate_image_metric_acc_local(metricAccOriginalCommEve, im, ...
                    eveFrame.metricsOriginalComm.mse(im), eveFrame.metricsOriginalComm.psnr(im), eveFrame.metricsOriginalComm.ssim(im));
                metricAccOriginalCompEve = accumulate_image_metric_acc_local(metricAccOriginalCompEve, im, ...
                    eveFrame.metricsOriginalComp.mse(im), eveFrame.metricsOriginalComp.psnr(im), eveFrame.metricsOriginalComp.ssim(im));
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

    [mseOutResizedComm, psnrOutResizedComm, ssimOutResizedComm] = finalize_image_metric_acc_local(metricAccResizedComm);
    [mseOutResizedComp, psnrOutResizedComp, ssimOutResizedComp] = finalize_image_metric_acc_local(metricAccResizedComp);
    [mseOutOriginalComm, psnrOutOriginalComm, ssimOutOriginalComm] = finalize_image_metric_acc_local(metricAccOriginalComm);
    [mseOutOriginalComp, psnrOutOriginalComp, ssimOutOriginalComp] = finalize_image_metric_acc_local(metricAccOriginalComp);
    mseResizedCommVals(:, ie) = mseOutResizedComm;
    psnrResizedCommVals(:, ie) = psnrOutResizedComm;
    ssimResizedCommVals(:, ie) = ssimOutResizedComm;
    mseResizedCompVals(:, ie) = mseOutResizedComp;
    psnrResizedCompVals(:, ie) = psnrOutResizedComp;
    ssimResizedCompVals(:, ie) = ssimOutResizedComp;
    mseOriginalCommVals(:, ie) = mseOutOriginalComm;
    psnrOriginalCommVals(:, ie) = psnrOutOriginalComm;
    ssimOriginalCommVals(:, ie) = ssimOutOriginalComm;
    mseOriginalCompVals(:, ie) = mseOutOriginalComp;
    psnrOriginalCompVals(:, ie) = psnrOutOriginalComp;
    ssimOriginalCompVals(:, ie) = ssimOutOriginalComp;
    example(ie) = select_example_point_nearest_mean_local( ...
        EbN0dB, methods, exampleCandidates, ...
        struct("mse", mseOutResizedComm, "psnr", psnrOutResizedComm, "ssim", ssimOutResizedComm), ...
        struct("mse", mseOutResizedComp, "psnr", psnrOutResizedComp, "ssim", ssimOutResizedComp), ...
        struct("mse", mseOutOriginalComm, "psnr", psnrOutOriginalComm, "ssim", ssimOutOriginalComm), ...
        struct("mse", mseOutOriginalComp, "psnr", psnrOutOriginalComp, "ssim", ssimOutOriginalComp), ...
        packetConcealActive, "Bob");


    if eveEnabled
        berEve(:, ie) = nErrEve ./ max(nTotEve, 1);
        packetFrontEndEveMethodVals(:, ie) = packetFrontEndEveAcc / p.sim.nFramesPerPoint;
        packetHeaderEveMethodVals(:, ie) = packetHeaderEveAcc / p.sim.nFramesPerPoint;
        packetFrontEndEveVals(ie) = mean(packetFrontEndEveMethodVals(:, ie));
        packetHeaderEveVals(ie) = mean(packetHeaderEveMethodVals(:, ie));
        packetSuccessEveVals(:, ie) = packetSuccessEveAcc / p.sim.nFramesPerPoint;
        rawPacketSuccessEveVals(:, ie) = rawPacketSuccessEveAcc / p.sim.nFramesPerPoint;

        [mseOutResizedCommEve, psnrOutResizedCommEve, ssimOutResizedCommEve] = finalize_image_metric_acc_local(metricAccResizedCommEve);
        [mseOutResizedCompEve, psnrOutResizedCompEve, ssimOutResizedCompEve] = finalize_image_metric_acc_local(metricAccResizedCompEve);
        [mseOutOriginalCommEve, psnrOutOriginalCommEve, ssimOutOriginalCommEve] = finalize_image_metric_acc_local(metricAccOriginalCommEve);
        [mseOutOriginalCompEve, psnrOutOriginalCompEve, ssimOutOriginalCompEve] = finalize_image_metric_acc_local(metricAccOriginalCompEve);
        mseResizedCommEveVals(:, ie) = mseOutResizedCommEve;
        psnrResizedCommEveVals(:, ie) = psnrOutResizedCommEve;
        ssimResizedCommEveVals(:, ie) = ssimOutResizedCommEve;
        mseResizedCompEveVals(:, ie) = mseOutResizedCompEve;
        psnrResizedCompEveVals(:, ie) = psnrOutResizedCompEve;
        ssimResizedCompEveVals(:, ie) = ssimOutResizedCompEve;
        mseOriginalCommEveVals(:, ie) = mseOutOriginalCommEve;
        psnrOriginalCommEveVals(:, ie) = psnrOutOriginalCommEve;
        ssimOriginalCommEveVals(:, ie) = ssimOutOriginalCommEve;
        mseOriginalCompEveVals(:, ie) = mseOutOriginalCompEve;
        psnrOriginalCompEveVals(:, ie) = psnrOutOriginalCompEve;
        ssimOriginalCompEveVals(:, ie) = ssimOutOriginalCompEve;
        exampleEve(ie) = select_example_point_nearest_mean_local( ...
            EbN0dBEve, methods, exampleCandidatesEve, ...
            struct("mse", mseOutResizedCommEve, "psnr", psnrOutResizedCommEve, "ssim", ssimOutResizedCommEve), ...
            struct("mse", mseOutResizedCompEve, "psnr", psnrOutResizedCompEve, "ssim", ssimOutResizedCompEve), ...
            struct("mse", mseOutOriginalCommEve, "psnr", psnrOutOriginalCommEve, "ssim", ssimOutOriginalCommEve), ...
            struct("mse", mseOutOriginalCompEve, "psnr", psnrOutOriginalCompEve, "ssim", ssimOutOriginalCompEve), ...
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
results.receiverMethodPlan = receiverMethodPlan;
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
results.sourceImages = struct("resized", imgTx, "original", imgTxOriginal);
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
results.receiver = struct( ...
    "rxSync", local_pack_rx_sync_summary_local(bobRxSync), ...
    "rxDiversity", local_pack_rx_diversity_summary_local(bobRxDiversity), ...
    "mitigation", local_pack_mitigation_summary_local(bobMitigation));
results.packetConceal = struct("configured", packetConcealEnable, "active", packetConcealActive, "mode", packetConcealMode);
results.imageMetrics = struct( ...
    "resized", struct( ...
        "communication", struct("mse", mseResizedCommVals, "psnr", psnrResizedCommVals, "ssim", ssimResizedCommVals), ...
        "compensated", struct("mse", mseResizedCompVals, "psnr", psnrResizedCompVals, "ssim", ssimResizedCompVals)), ...
    "original", struct( ...
        "communication", struct("mse", mseOriginalCommVals, "psnr", psnrOriginalCommVals, "ssim", ssimOriginalCommVals), ...
        "compensated", struct("mse", mseOriginalCompVals, "psnr", psnrOriginalCompVals, "ssim", ssimOriginalCompVals)));
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
        "rxDiversity", local_pack_rx_diversity_summary_local(eveRxDiversity), ...
        "mitigation", local_pack_mitigation_summary_local(eveMitigation));
    results.eve.imageMetrics = struct( ...
        "resized", struct( ...
            "communication", struct("mse", mseResizedCommEveVals, "psnr", psnrResizedCommEveVals, "ssim", ssimResizedCommEveVals), ...
            "compensated", struct("mse", mseResizedCompEveVals, "psnr", psnrResizedCompEveVals, "ssim", ssimResizedCompEveVals)), ...
        "original", struct( ...
            "communication", struct("mse", mseOriginalCommEveVals, "psnr", psnrOriginalCommEveVals, "ssim", ssimOriginalCommEveVals), ...
            "compensated", struct("mse", mseOriginalCompEveVals, "psnr", psnrOriginalCompEveVals, "ssim", ssimOriginalCompEveVals)));
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
    save_figures(outDir, results);
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

function imgOut = local_resize_to_reference_local(imgIn, refImg)
imgIn = im2uint8(imgIn);
refImg = im2uint8(refImg);

if size(imgIn, 3) ~= size(refImg, 3)
    error("接收图像与参考图像通道数不一致，无法恢复到参考尺寸。");
end

targetRows = size(refImg, 1);
targetCols = size(refImg, 2);
if size(imgIn, 1) == targetRows && size(imgIn, 2) == targetCols
    imgOut = imgIn;
    return;
end

imgOut = imresize(imgIn, [targetRows, targetCols], "bicubic");
end

function bank = init_example_candidate_bank_local(nMethods, nFrames)
bank = struct();
bank.examples = cell(nMethods, nFrames);
bank.resizedComm = struct( ...
    "mse", nan(nMethods, nFrames), ...
    "psnr", nan(nMethods, nFrames), ...
    "ssim", nan(nMethods, nFrames));
bank.resizedComp = struct( ...
    "mse", nan(nMethods, nFrames), ...
    "psnr", nan(nMethods, nFrames), ...
    "ssim", nan(nMethods, nFrames));
bank.originalComm = struct( ...
    "mse", nan(nMethods, nFrames), ...
    "psnr", nan(nMethods, nFrames), ...
    "ssim", nan(nMethods, nFrames));
bank.originalComp = struct( ...
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

bank.resizedComm.mse(:, frameIdx) = frameResult.metricsResizedComm.mse;
bank.resizedComm.psnr(:, frameIdx) = frameResult.metricsResizedComm.psnr;
bank.resizedComm.ssim(:, frameIdx) = frameResult.metricsResizedComm.ssim;
bank.resizedComp.mse(:, frameIdx) = frameResult.metricsResizedComp.mse;
bank.resizedComp.psnr(:, frameIdx) = frameResult.metricsResizedComp.psnr;
bank.resizedComp.ssim(:, frameIdx) = frameResult.metricsResizedComp.ssim;
bank.originalComm.mse(:, frameIdx) = frameResult.metricsOriginalComm.mse;
bank.originalComm.psnr(:, frameIdx) = frameResult.metricsOriginalComm.psnr;
bank.originalComm.ssim(:, frameIdx) = frameResult.metricsOriginalComm.ssim;
bank.originalComp.mse(:, frameIdx) = frameResult.metricsOriginalComp.mse;
bank.originalComp.psnr(:, frameIdx) = frameResult.metricsOriginalComp.psnr;
bank.originalComp.ssim(:, frameIdx) = frameResult.metricsOriginalComp.ssim;

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
    ebN0Val, methods, bank, avgResizedComm, avgResizedComp, avgOriginalComm, avgOriginalComp, packetConcealActive, roleName)
examplePoint = struct("EbN0dB", ebN0Val, "methods", struct());
for methodIdx = 1:numel(methods)
    methodName = char(methods(methodIdx));
    [exampleEntry, bestFrameIdx, bestDistance] = local_select_nearest_example_candidate_local( ...
        methodName, bank, avgResizedComm, avgResizedComp, avgOriginalComm, avgOriginalComp, methodIdx, packetConcealActive, roleName);
    exampleEntry.selectedFrameIdx = bestFrameIdx;
    exampleEntry.selectionDistanceToMean = bestDistance;
    exampleEntry.selectionRule = "nearest_mean_metrics";
    examplePoint.methods.(methodName) = exampleEntry;
end
end

function [exampleEntry, bestFrameIdx, bestDistance] = local_select_nearest_example_candidate_local( ...
    methodName, bank, avgResizedComm, avgResizedComp, avgOriginalComm, avgOriginalComp, methodIdx, packetConcealActive, roleName)
metricMatrix = [ ...
    bank.originalComm.mse(methodIdx, :).', ...
    bank.originalComm.psnr(methodIdx, :).', ...
    bank.originalComm.ssim(methodIdx, :).', ...
    bank.resizedComm.mse(methodIdx, :).', ...
    bank.resizedComm.psnr(methodIdx, :).', ...
    bank.resizedComm.ssim(methodIdx, :).'];
targetVector = [ ...
    avgOriginalComm.mse(methodIdx), avgOriginalComm.psnr(methodIdx), avgOriginalComm.ssim(methodIdx), ...
    avgResizedComm.mse(methodIdx), avgResizedComm.psnr(methodIdx), avgResizedComm.ssim(methodIdx)];
if packetConcealActive
    metricMatrix = [metricMatrix, ...
        bank.originalComp.mse(methodIdx, :).', ...
        bank.originalComp.psnr(methodIdx, :).', ...
        bank.originalComp.ssim(methodIdx, :).', ...
        bank.resizedComp.mse(methodIdx, :).', ...
        bank.resizedComp.psnr(methodIdx, :).', ...
        bank.resizedComp.ssim(methodIdx, :).'];
    targetVector = [targetVector, ...
        avgOriginalComp.mse(methodIdx), avgOriginalComp.psnr(methodIdx), avgOriginalComp.ssim(methodIdx), ...
        avgResizedComp.mse(methodIdx), avgResizedComp.psnr(methodIdx), avgResizedComp.ssim(methodIdx)];
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
for colIdx = 1:3:size(values, 2)
    if colIdx > size(values, 2)
        continue;
    end
    for rowIdx = 1:size(values, 1)
        values(rowIdx, colIdx) = local_transform_mse_metric_local(values(rowIdx, colIdx), methodName, roleName);
    end
end
end

function values = local_transform_metric_vector_local(values, methodName, roleName)
for colIdx = 1:3:numel(values)
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
bobRaw = local_init_raw_capture_local(nPackets, numel(frameCtx.sessionFrames), frameCtx.bobRxDiversity);
eveRaw = struct();
if eveEnabled
    eveRaw = local_init_raw_capture_local(nPackets, numel(frameCtx.sessionFrames), frameCtx.eveRxDiversity);
end

frameDelaySym = randi([0, p.channel.maxDelaySymbols], 1, 1);
frameDelay = round(double(frameDelaySym) * waveform.sps);
bobChannelBank = local_freeze_rx_diversity_channel_bank_local(frameCtx.channelSample, frameCtx.bobRxDiversity);
if eveEnabled
    eveChannelBank = local_freeze_rx_diversity_channel_bank_local(frameCtx.channelSample, frameCtx.eveRxDiversity);
end

if ~isempty(frameCtx.sessionFrames)
    bobRaw.sessionRx = local_capture_session_frames_raw_local( ...
        frameCtx.sessionFrames, frameCtx.linkBudgetBobRxAmplitudeScale, frameCtx.N0, bobChannelBank, frameDelay, ...
        waveform, frameCtx.bobRxDiversity);
    if eveEnabled
        eveRaw.sessionRx = local_capture_session_frames_raw_local( ...
            frameCtx.sessionFrames, frameCtx.eveRxAmplitudeScale, frameCtx.N0Eve, eveChannelBank, frameDelay, ...
            waveform, frameCtx.eveRxDiversity);
    end
end

for pktIdx = 1:nPackets
    pkt = txPackets(pktIdx);
    txPktChannel = local_rebuild_packet_channel_waveform_local(pkt, waveform);

    tx = [zeros(frameDelay, 1); frameCtx.linkBudgetBobRxAmplitudeScale * txPktChannel];
    bobRaw.rxPackets{pktIdx} = local_capture_rx_diversity_waveforms_local(tx, frameCtx.N0, bobChannelBank, frameCtx.bobRxDiversity);

    if eveEnabled
        txEve = [zeros(frameDelay, 1); frameCtx.eveRxAmplitudeScale * txPktChannel];
        eveRaw.rxPackets{pktIdx} = local_capture_rx_diversity_waveforms_local(txEve, frameCtx.N0Eve, eveChannelBank, frameCtx.eveRxDiversity);
    end
end

[bobFrame, eveFrame] = local_decode_frame_methods_local( ...
    frameCtx.methods, frameCtx.methodActions, frameCtx.methodEqualizers, ...
    txPackets, frameCtx.txPktIndex, frameCtx.txPayloadBits, frameCtx.sessionFrames, bobRaw, eveRaw, p, waveform, frameCtx.N0, frameCtx.N0Eve, frameCtx.fhEnabled, ...
    frameCtx.packetIndependentBitChaos, frameCtx.chaosEnabled, frameCtx.chaosEncInfo, ...
    frameCtx.packetConcealActive, frameCtx.packetConcealMode, frameCtx.imgTx, frameCtx.imgTxOriginal, frameCtx.meta, frameCtx.totalPayloadBits, ...
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
    methods, methodActions, methodEqualizers, txPackets, txPktIndex, txPayloadBits, sessionFrames, bobRaw, eveRaw, p, waveform, N0Bob, N0Eve, fhEnabled, ...
    packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
    packetConcealActive, packetConcealMode, imgTx, imgTxOriginal, metaTx, totalPayloadBitsTx, ...
    syncCfgUseBob, syncCfgUseEve, bobRxSync, bobMitigation, eveRxSync, eveMitigation, ...
    eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosApproxDeltaEve, chaosEncInfoEve, ...
    captureExample, EbN0dB, EbN0dBEve, useParallelMethods)

nMethods = numel(methods);
methodActions = string(methodActions(:).');
methodEqualizers = string(methodEqualizers(:).');
if numel(methodActions) ~= nMethods || numel(methodEqualizers) ~= nMethods
    error("receiver method plan length mismatch.");
end
nPackets = numel(txPktIndex);

nErrBob = zeros(nMethods, 1);
nTotBob = zeros(nMethods, 1);
frontEndBob = zeros(nMethods, 1);
headerBob = zeros(nMethods, 1);
mseResizedCommBob = nan(nMethods, 1);
psnrResizedCommBob = nan(nMethods, 1);
ssimResizedCommBob = nan(nMethods, 1);
mseResizedCompBob = nan(nMethods, 1);
psnrResizedCompBob = nan(nMethods, 1);
ssimResizedCompBob = nan(nMethods, 1);
mseOriginalCommBob = nan(nMethods, 1);
psnrOriginalCommBob = nan(nMethods, 1);
ssimOriginalCommBob = nan(nMethods, 1);
mseOriginalCompBob = nan(nMethods, 1);
psnrOriginalCompBob = nan(nMethods, 1);
ssimOriginalCompBob = nan(nMethods, 1);
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
mseResizedCommEve = nan(nMethods, 1);
psnrResizedCommEve = nan(nMethods, 1);
ssimResizedCommEve = nan(nMethods, 1);
mseResizedCompEve = nan(nMethods, 1);
psnrResizedCompEve = nan(nMethods, 1);
ssimResizedCompEve = nan(nMethods, 1);
mseOriginalCommEve = nan(nMethods, 1);
psnrOriginalCommEve = nan(nMethods, 1);
ssimOriginalCommEve = nan(nMethods, 1);
mseOriginalCompEve = nan(nMethods, 1);
psnrOriginalCompEve = nan(nMethods, 1);
ssimOriginalCompEve = nan(nMethods, 1);
packetSuccessEve = zeros(nMethods, 1);
rawPacketSuccessEve = zeros(nMethods, 1);
exampleEve = cell(nMethods, 1);

useParfor = logical(useParallelMethods) && local_has_parallel_pool_local();
if useParfor
    try
        parfor im = 1:nMethods
            methodAction = methodActions(im);
            bobRxSyncNow = local_rxsync_for_equalizer_method_local(bobRxSync, methodEqualizers(im));
            bobNom = local_build_packet_nominal_local( ...
                bobRaw, txPackets, sessionFrames, methodAction, bobMitigation, ...
                syncCfgUseBob, bobRxSyncNow, p, waveform, N0Bob, fhEnabled, "known", true);
            eveNom = struct();
            eveRxSyncNow = struct();
            if eveEnabled
                eveRxSyncNow = local_rxsync_for_equalizer_method_local(eveRxSync, methodEqualizers(im));
                eveNom = local_build_packet_nominal_local( ...
                    eveRaw, txPackets, sessionFrames, methodAction, eveMitigation, ...
                    syncCfgUseEve, eveRxSyncNow, p, waveform, N0Eve, fhEnabled, fhAssumptionEve, false);
            end

            [bobRes, eveRes] = local_decode_single_method_local( ...
                methodAction, txPackets, txPktIndex, txPayloadBits, sessionFrames, bobNom, eveNom, p, fhEnabled, ...
                packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
                packetConcealActive, packetConcealMode, imgTx, imgTxOriginal, metaTx, totalPayloadBitsTx, ...
                bobRxSyncNow, bobMitigation, eveRxSyncNow, eveMitigation, ...
                eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosApproxDeltaEve, chaosEncInfoEve, ...
                captureExample, EbN0dB, EbN0dBEve, nPackets);

            nErrBob(im) = bobRes.nErr;
            nTotBob(im) = bobRes.nTot;
            frontEndBob(im) = mean(double(bobNom.frontEndOk));
            headerBob(im) = mean(double(bobNom.headerOk));
            mseResizedCommBob(im) = bobRes.mseResizedComm;
            psnrResizedCommBob(im) = bobRes.psnrResizedComm;
            ssimResizedCommBob(im) = bobRes.ssimResizedComm;
            mseResizedCompBob(im) = bobRes.mseResizedComp;
            psnrResizedCompBob(im) = bobRes.psnrResizedComp;
            ssimResizedCompBob(im) = bobRes.ssimResizedComp;
            mseOriginalCommBob(im) = bobRes.mseOriginalComm;
            psnrOriginalCommBob(im) = bobRes.psnrOriginalComm;
            ssimOriginalCommBob(im) = bobRes.ssimOriginalComm;
            mseOriginalCompBob(im) = bobRes.mseOriginalComp;
            psnrOriginalCompBob(im) = bobRes.psnrOriginalComp;
            ssimOriginalCompBob(im) = bobRes.ssimOriginalComp;
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
                mseResizedCommEve(im) = eveRes.mseResizedComm;
                psnrResizedCommEve(im) = eveRes.psnrResizedComm;
                ssimResizedCommEve(im) = eveRes.ssimResizedComm;
                mseResizedCompEve(im) = eveRes.mseResizedComp;
                psnrResizedCompEve(im) = eveRes.psnrResizedComp;
                ssimResizedCompEve(im) = eveRes.ssimResizedComp;
                mseOriginalCommEve(im) = eveRes.mseOriginalComm;
                psnrOriginalCommEve(im) = eveRes.psnrOriginalComm;
                ssimOriginalCommEve(im) = eveRes.ssimOriginalComm;
                mseOriginalCompEve(im) = eveRes.mseOriginalComp;
                psnrOriginalCompEve(im) = eveRes.psnrOriginalComp;
                ssimOriginalCompEve(im) = eveRes.ssimOriginalComp;
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
        mseResizedCommBob = nan(nMethods, 1);
        psnrResizedCommBob = nan(nMethods, 1);
        ssimResizedCommBob = nan(nMethods, 1);
        mseResizedCompBob = nan(nMethods, 1);
        psnrResizedCompBob = nan(nMethods, 1);
        ssimResizedCompBob = nan(nMethods, 1);
        mseOriginalCommBob = nan(nMethods, 1);
        psnrOriginalCommBob = nan(nMethods, 1);
        ssimOriginalCommBob = nan(nMethods, 1);
        mseOriginalCompBob = nan(nMethods, 1);
        psnrOriginalCompBob = nan(nMethods, 1);
        ssimOriginalCompBob = nan(nMethods, 1);
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
        mseResizedCommEve = nan(nMethods, 1);
        psnrResizedCommEve = nan(nMethods, 1);
        ssimResizedCommEve = nan(nMethods, 1);
        mseResizedCompEve = nan(nMethods, 1);
        psnrResizedCompEve = nan(nMethods, 1);
        ssimResizedCompEve = nan(nMethods, 1);
        mseOriginalCommEve = nan(nMethods, 1);
        psnrOriginalCommEve = nan(nMethods, 1);
        ssimOriginalCommEve = nan(nMethods, 1);
        mseOriginalCompEve = nan(nMethods, 1);
        psnrOriginalCompEve = nan(nMethods, 1);
        ssimOriginalCompEve = nan(nMethods, 1);
        packetSuccessEve = zeros(nMethods, 1);
        rawPacketSuccessEve = zeros(nMethods, 1);
        exampleEve = cell(nMethods, 1);
    end
end

if ~useParfor
    for im = 1:nMethods
        methodAction = methodActions(im);
        bobRxSyncNow = local_rxsync_for_equalizer_method_local(bobRxSync, methodEqualizers(im));
        bobNom = local_build_packet_nominal_local( ...
            bobRaw, txPackets, sessionFrames, methodAction, bobMitigation, ...
            syncCfgUseBob, bobRxSyncNow, p, waveform, N0Bob, fhEnabled, "known", true);
        eveNom = struct();
        eveRxSyncNow = struct();
        if eveEnabled
            eveRxSyncNow = local_rxsync_for_equalizer_method_local(eveRxSync, methodEqualizers(im));
            eveNom = local_build_packet_nominal_local( ...
                eveRaw, txPackets, sessionFrames, methodAction, eveMitigation, ...
                syncCfgUseEve, eveRxSyncNow, p, waveform, N0Eve, fhEnabled, fhAssumptionEve, false);
        end

        [bobRes, eveRes] = local_decode_single_method_local( ...
            methodAction, txPackets, txPktIndex, txPayloadBits, sessionFrames, bobNom, eveNom, p, fhEnabled, ...
            packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
            packetConcealActive, packetConcealMode, imgTx, imgTxOriginal, metaTx, totalPayloadBitsTx, ...
            bobRxSyncNow, bobMitigation, eveRxSyncNow, eveMitigation, ...
            eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosApproxDeltaEve, chaosEncInfoEve, ...
            captureExample, EbN0dB, EbN0dBEve, nPackets);

        nErrBob(im) = bobRes.nErr;
        nTotBob(im) = bobRes.nTot;
        frontEndBob(im) = mean(double(bobNom.frontEndOk));
        headerBob(im) = mean(double(bobNom.headerOk));
        mseResizedCommBob(im) = bobRes.mseResizedComm;
        psnrResizedCommBob(im) = bobRes.psnrResizedComm;
        ssimResizedCommBob(im) = bobRes.ssimResizedComm;
        mseResizedCompBob(im) = bobRes.mseResizedComp;
        psnrResizedCompBob(im) = bobRes.psnrResizedComp;
        ssimResizedCompBob(im) = bobRes.ssimResizedComp;
        mseOriginalCommBob(im) = bobRes.mseOriginalComm;
        psnrOriginalCommBob(im) = bobRes.psnrOriginalComm;
        ssimOriginalCommBob(im) = bobRes.ssimOriginalComm;
        mseOriginalCompBob(im) = bobRes.mseOriginalComp;
        psnrOriginalCompBob(im) = bobRes.psnrOriginalComp;
        ssimOriginalCompBob(im) = bobRes.ssimOriginalComp;
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
            mseResizedCommEve(im) = eveRes.mseResizedComm;
            psnrResizedCommEve(im) = eveRes.psnrResizedComm;
            ssimResizedCommEve(im) = eveRes.ssimResizedComm;
            mseResizedCompEve(im) = eveRes.mseResizedComp;
            psnrResizedCompEve(im) = eveRes.psnrResizedComp;
            ssimResizedCompEve(im) = eveRes.ssimResizedComp;
            mseOriginalCommEve(im) = eveRes.mseOriginalComm;
            psnrOriginalCommEve(im) = eveRes.psnrOriginalComm;
            ssimOriginalCommEve(im) = eveRes.ssimOriginalComm;
            mseOriginalCompEve(im) = eveRes.mseOriginalComp;
            psnrOriginalCompEve(im) = eveRes.psnrOriginalComp;
            ssimOriginalCompEve(im) = eveRes.ssimOriginalComp;
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
bobFrame.metricsResizedComm = struct("mse", mseResizedCommBob, "psnr", psnrResizedCommBob, "ssim", ssimResizedCommBob);
bobFrame.metricsResizedComp = struct("mse", mseResizedCompBob, "psnr", psnrResizedCompBob, "ssim", ssimResizedCompBob);
bobFrame.metricsOriginalComm = struct("mse", mseOriginalCommBob, "psnr", psnrOriginalCommBob, "ssim", ssimOriginalCommBob);
bobFrame.metricsOriginalComp = struct("mse", mseOriginalCompBob, "psnr", psnrOriginalCompBob, "ssim", ssimOriginalCompBob);
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
    eveFrame.metricsResizedComm = struct("mse", mseResizedCommEve, "psnr", psnrResizedCommEve, "ssim", ssimResizedCommEve);
    eveFrame.metricsResizedComp = struct("mse", mseResizedCompEve, "psnr", psnrResizedCompEve, "ssim", ssimResizedCompEve);
    eveFrame.metricsOriginalComm = struct("mse", mseOriginalCommEve, "psnr", psnrOriginalCommEve, "ssim", ssimOriginalCommEve);
    eveFrame.metricsOriginalComp = struct("mse", mseOriginalCompEve, "psnr", psnrOriginalCompEve, "ssim", ssimOriginalCompEve);
    eveFrame.example = exampleEve;
end
end

function [bobRes, eveRes] = local_decode_single_method_local( ...
    methodName, txPackets, txPktIndex, txPayloadBits, sessionFrames, bobNom, eveNom, p, fhEnabled, ...
    packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
    packetConcealActive, packetConcealMode, imgTx, imgTxOriginal, metaTx, totalPayloadBitsTx, ...
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
    imgRxCommResized = payload_bits_to_image(payloadFrameBob, metaBobUse, p.payload);
elseif chaosEnabled && isfield(chaosEncInfo, "enabled") && chaosEncInfo.enabled
    if isfield(chaosEncInfo, "mode") && lower(string(chaosEncInfo.mode)) == "payload_bits"
        payloadBitsRxDec = chaos_decrypt_bits(payloadFrameBob, chaosEncInfo);
        imgRxCommResized = payload_bits_to_image(payloadBitsRxDec, metaBobUse, p.payload);
    else
        imgRxEnc = payload_bits_to_image(payloadFrameBob, metaBobUse, p.payload);
        imgRxCommResized = chaos_decrypt(imgRxEnc, chaosEncInfo);
    end
else
    imgRxCommResized = payload_bits_to_image(payloadFrameBob, metaBobUse, p.payload);
end

imgRxCompResized = imgRxCommResized;
if packetConcealActive
    imgRxCompResized = conceal_image_from_packets(imgRxCompResized, packetOkBob, rxLayoutBob, metaBobUse, p.payload, packetConcealMode);
end

[psnrNowResizedComm, ssimNowResizedComm, mseNowResizedComm] = image_quality(imgTx, imgRxCommResized);
[psnrNowResizedComp, ssimNowResizedComp, mseNowResizedComp] = image_quality(imgTx, imgRxCompResized);
imgRxComm = local_resize_to_reference_local(imgRxCommResized, imgTxOriginal);
imgRxComp = local_resize_to_reference_local(imgRxCompResized, imgTxOriginal);
[psnrNowOriginalComm, ssimNowOriginalComm, mseNowOriginalComm] = image_quality(imgTxOriginal, imgRxComm);
[psnrNowOriginalComp, ssimNowOriginalComp, mseNowOriginalComp] = image_quality(imgTxOriginal, imgRxComp);

bobRes = struct();
bobRes.nErr = nErrBob;
bobRes.nTot = nTotBob;
bobRes.mseResizedComm = mseNowResizedComm;
bobRes.psnrResizedComm = psnrNowResizedComm;
bobRes.ssimResizedComm = ssimNowResizedComm;
bobRes.mseResizedComp = mseNowResizedComp;
bobRes.psnrResizedComp = psnrNowResizedComp;
bobRes.ssimResizedComp = ssimNowResizedComp;
bobRes.mseOriginalComm = mseNowOriginalComm;
bobRes.psnrOriginalComm = psnrNowOriginalComm;
bobRes.ssimOriginalComm = ssimNowOriginalComm;
bobRes.mseOriginalComp = mseNowOriginalComp;
bobRes.psnrOriginalComp = psnrNowOriginalComp;
bobRes.ssimOriginalComp = ssimNowOriginalComp;
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
    bobRes.example.imgRxCommResized = imgRxCommResized;
    bobRes.example.imgRxCompensatedResized = imgRxCompResized;
    bobRes.example.imgRxResized = imgRxCompResized;
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
    imgEveCommResized = payload_bits_to_image(payloadFrameEve, metaEveUse, p.payload);
elseif chaosEnabled && isfield(chaosEncInfoEve, "enabled") && chaosEncInfoEve.enabled
    if isfield(chaosEncInfoEve, "mode") && lower(string(chaosEncInfoEve.mode)) == "payload_bits"
        payloadBitsEveDec = chaos_decrypt_bits(payloadFrameEve, chaosEncInfoEve);
        imgEveCommResized = payload_bits_to_image(payloadBitsEveDec, metaEveUse, p.payload);
    else
        imgEveEnc = payload_bits_to_image(payloadFrameEve, metaEveUse, p.payload);
        imgEveCommResized = chaos_decrypt(imgEveEnc, chaosEncInfoEve);
    end
else
    imgEveCommResized = payload_bits_to_image(payloadFrameEve, metaEveUse, p.payload);
end

imgEveCompResized = imgEveCommResized;
if packetConcealActive
    imgEveCompResized = conceal_image_from_packets(imgEveCompResized, packetOkEve, rxLayoutEve, metaEveUse, p.payload, packetConcealMode);
end

[psnrNowResizedCommEve, ssimNowResizedCommEve, mseNowResizedCommEve] = image_quality(imgTx, imgEveCommResized);
[psnrNowResizedCompEve, ssimNowResizedCompEve, mseNowResizedCompEve] = image_quality(imgTx, imgEveCompResized);
imgEveComm = local_resize_to_reference_local(imgEveCommResized, imgTxOriginal);
imgEveComp = local_resize_to_reference_local(imgEveCompResized, imgTxOriginal);
[psnrNowOriginalCommEve, ssimNowOriginalCommEve, mseNowOriginalCommEve] = image_quality(imgTxOriginal, imgEveComm);
[psnrNowOriginalCompEve, ssimNowOriginalCompEve, mseNowOriginalCompEve] = image_quality(imgTxOriginal, imgEveComp);

eveRes.nErr = nErrEve;
eveRes.nTot = nTotEve;
eveRes.mseResizedComm = mseNowResizedCommEve;
eveRes.psnrResizedComm = psnrNowResizedCommEve;
eveRes.ssimResizedComm = ssimNowResizedCommEve;
eveRes.mseResizedComp = mseNowResizedCompEve;
eveRes.psnrResizedComp = psnrNowResizedCompEve;
eveRes.ssimResizedComp = ssimNowResizedCompEve;
eveRes.mseOriginalComm = mseNowOriginalCommEve;
eveRes.psnrOriginalComm = psnrNowOriginalCommEve;
eveRes.ssimOriginalComm = ssimNowOriginalCommEve;
eveRes.mseOriginalComp = mseNowOriginalCompEve;
eveRes.psnrOriginalComp = psnrNowOriginalCompEve;
eveRes.ssimOriginalComp = ssimNowOriginalCompEve;
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
    eveRes.example.imgRxCommResized = imgEveCommResized;
    eveRes.example.imgRxCompensatedResized = imgEveCompResized;
    eveRes.example.imgRxResized = imgEveCompResized;
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

function txPacketsOut = local_compact_tx_packets_for_rx_local(txPacketsIn)
txPacketsIn = txPacketsIn(:);
nPackets = numel(txPacketsIn);
txPacketsOut = repmat(struct( ...
    "syncSym", complex(zeros(0, 1)), ...
    "phyHeaderSymTx", complex(zeros(0, 1)), ...
    "dataSymHop", complex(zeros(0, 1)), ...
    "isDataPacket", false, ...
    "sourcePacketIndex", 0, ...
    "blockIndex", 0, ...
    "blockDataCount", 0, ...
    "blockParityCount", 0, ...
    "startBit", 0, ...
    "endBit", 0, ...
    "preambleFhCfg", struct("enable", false), ...
    "phyHeaderFhCfg", struct("enable", false), ...
    "fhCfg", struct("enable", false)), nPackets, 1);
for pktIdx = 1:nPackets
    pkt = txPacketsIn(pktIdx);
    txPacketsOut(pktIdx).syncSym = pkt.syncSym;
    txPacketsOut(pktIdx).phyHeaderSymTx = pkt.phyHeaderSymTx;
    txPacketsOut(pktIdx).dataSymHop = pkt.dataSymHop;
    txPacketsOut(pktIdx).isDataPacket = pkt.isDataPacket;
    txPacketsOut(pktIdx).sourcePacketIndex = pkt.sourcePacketIndex;
    txPacketsOut(pktIdx).blockIndex = pkt.blockIndex;
    txPacketsOut(pktIdx).blockDataCount = pkt.blockDataCount;
    txPacketsOut(pktIdx).blockParityCount = pkt.blockParityCount;
    txPacketsOut(pktIdx).startBit = pkt.startBit;
    txPacketsOut(pktIdx).endBit = pkt.endBit;
    if isfield(pkt, "preambleFhCfg") && isstruct(pkt.preambleFhCfg)
        txPacketsOut(pktIdx).preambleFhCfg = pkt.preambleFhCfg;
    end
    txPacketsOut(pktIdx).phyHeaderFhCfg = pkt.phyHeaderFhCfg;
    txPacketsOut(pktIdx).fhCfg = pkt.fhCfg;
end
end

function sessionFramesOut = local_compact_session_frames_for_rx_local(sessionFramesIn)
sessionFramesIn = sessionFramesIn(:);
nFrames = numel(sessionFramesIn);
sessionFramesOut = repmat(struct( ...
    "txSymForChannel", complex(zeros(0, 1)), ...
    "syncSym", complex(zeros(0, 1)), ...
    "nDataSym", 0, ...
    "nDemodSym", 0, ...
    "modCfg", struct(), ...
    "decodeKind", "", ...
    "hopInfo", struct("enable", false), ...
    "fhCfg", struct("enable", false), ...
    "preambleFhCfg", struct("enable", false), ...
    "dsssCfg", struct("enable", false), ...
    "symbolRepeat", 1, ...
    "infoBitsLen", 0, ...
    "bodyDiversityCopies", 1, ...
    "bodyDiversityCopyLen", 0, ...
    "bitRepeat", 1, ...
    "fecCfg", struct(), ...
    "intState", struct()), nFrames, 1);
for frameIdx = 1:nFrames
    frame = sessionFramesIn(frameIdx);
    sessionFramesOut(frameIdx).txSymForChannel = frame.txSymForChannel;
    sessionFramesOut(frameIdx).syncSym = frame.syncSym;
    sessionFramesOut(frameIdx).nDataSym = frame.nDataSym;
    if isfield(frame, "nDemodSym") && ~isempty(frame.nDemodSym)
        sessionFramesOut(frameIdx).nDemodSym = frame.nDemodSym;
    else
        sessionFramesOut(frameIdx).nDemodSym = frame.nDataSym;
    end
    sessionFramesOut(frameIdx).modCfg = frame.modCfg;
    sessionFramesOut(frameIdx).decodeKind = frame.decodeKind;
    sessionFramesOut(frameIdx).hopInfo = frame.hopInfo;
    sessionFramesOut(frameIdx).fhCfg = frame.fhCfg;
    if isfield(frame, "preambleFhCfg") && isstruct(frame.preambleFhCfg)
        sessionFramesOut(frameIdx).preambleFhCfg = frame.preambleFhCfg;
    end
    sessionFramesOut(frameIdx).dsssCfg = frame.dsssCfg;
    if isfield(frame, "symbolRepeat") && ~isempty(frame.symbolRepeat)
        sessionFramesOut(frameIdx).symbolRepeat = frame.symbolRepeat;
    end
    if isfield(frame, "infoBitsLen") && ~isempty(frame.infoBitsLen)
        sessionFramesOut(frameIdx).infoBitsLen = frame.infoBitsLen;
    end
    if isfield(frame, "bodyDiversityCopies") && ~isempty(frame.bodyDiversityCopies)
        sessionFramesOut(frameIdx).bodyDiversityCopies = frame.bodyDiversityCopies;
    end
    if isfield(frame, "bodyDiversityCopyLen") && ~isempty(frame.bodyDiversityCopyLen)
        sessionFramesOut(frameIdx).bodyDiversityCopyLen = frame.bodyDiversityCopyLen;
    end
    if isfield(frame, "bitRepeat") && ~isempty(frame.bitRepeat)
        sessionFramesOut(frameIdx).bitRepeat = frame.bitRepeat;
    end
    if isfield(frame, "fecCfg") && ~isempty(frame.fecCfg)
        sessionFramesOut(frameIdx).fecCfg = frame.fecCfg;
    end
    if isfield(frame, "intState") && ~isempty(frame.intState)
        sessionFramesOut(frameIdx).intState = frame.intState;
    end
end
end

function nBytes = local_variable_size_bytes_local(x)
tmp = x; %#ok<NASGU>
s = whos("tmp");
nBytes = double(s.bytes);
end

function pOut = local_compact_params_for_worker_local(p)
%LOCAL_COMPACT_PARAMS_FOR_WORKER_LOCAL  仅保留worker帧处理路径所需的p子字段。
%
% 删除的大体积字段：
%   p.mitigation（含全部ML模型权重）— 已作为 bobMitigation/eveMitigation 单独传入
%   p.rxSync — 已作为 bobRxSync/eveRxSync 单独传入
%   p.sim, p.source, p.linkBudget, p.tx — 仅外层循环使用
%   p.eve, p.covert — 已解析提取为独立字段
%   p.rngSeed — 已转换为 frameSeedBase
pOut = struct();
pOut.channel = p.channel;
pOut.mod = p.mod;
pOut.fec = p.fec;
pOut.softMetric = p.softMetric;
pOut.frame = p.frame;
pOut.fh = p.fh;
pOut.interleaver = p.interleaver;
pOut.scramble = p.scramble;
pOut.payload = p.payload;
pOut.packet = p.packet;
pOut.outerRs = p.outerRs;
pOut.chaosEncrypt = p.chaosEncrypt;
pOut.scFde = p.scFde;
if isfield(p, 'dsss')
    pOut.dsss = p.dsss;
end
if isfield(p, 'waveform')
    pOut.waveform = p.waveform;
end
end

function txSymForChannel = local_rebuild_packet_channel_waveform_local(txPacket, waveform)
if ~(isstruct(txPacket) && isfield(txPacket, "syncSym") && isfield(txPacket, "phyHeaderSymTx") ...
        && isfield(txPacket, "dataSymHop") && isfield(txPacket, "phyHeaderFhCfg") && isfield(txPacket, "fhCfg"))
    error("Worker packet context is missing waveform reconstruction fields.");
end
txSymPkt = [txPacket.syncSym(:); txPacket.phyHeaderSymTx(:); txPacket.dataSymHop(:)];
txSymForChannel = pulse_tx_from_symbol_rate(txSymPkt, waveform);
preambleFhCfg = struct("enable", false);
if isfield(txPacket, "preambleFhCfg") && isstruct(txPacket.preambleFhCfg)
    preambleFhCfg = txPacket.preambleFhCfg;
end
headerFhCfg = txPacket.phyHeaderFhCfg;
dataFhCfg = txPacket.fhCfg;
if (isstruct(preambleFhCfg) && isfield(preambleFhCfg, "enable") && preambleFhCfg.enable) ...
        || (isstruct(headerFhCfg) && isfield(headerFhCfg, "enable") && headerFhCfg.enable) ...
        || (isstruct(dataFhCfg) && isfield(dataFhCfg, "enable") && dataFhCfg.enable)
    txSymForChannel = local_apply_fh_segments_to_packet_samples_local( ...
        txSymForChannel, numel(txPacket.syncSym), numel(txPacket.phyHeaderSymTx), preambleFhCfg, headerFhCfg, dataFhCfg, waveform);
end
end

function txOut = local_apply_fh_segments_to_packet_samples_local(txIn, nSyncSym, nHeaderSym, preambleFhCfg, headerFhCfg, dataFhCfg, waveform)
txOut = txIn(:);
headerStart = local_symbol_boundary_sample_index_rx_local(nSyncSym, waveform);
dataStart = local_symbol_boundary_sample_index_rx_local(nSyncSym + nHeaderSym, waveform);

if isstruct(preambleFhCfg) && isfield(preambleFhCfg, "enable") && preambleFhCfg.enable
    preambleStop = min(numel(txOut), headerStart - 1);
    if 1 <= preambleStop
        [segOut, ~] = fh_modulate_samples(txOut(1:preambleStop), preambleFhCfg, waveform);
        txOut(1:preambleStop) = segOut;
    end
end

if isstruct(headerFhCfg) && isfield(headerFhCfg, "enable") && headerFhCfg.enable
    headerStop = min(numel(txOut), dataStart - 1);
    if headerStart <= headerStop
        [segOut, ~] = fh_modulate_samples(txOut(headerStart:headerStop), headerFhCfg, waveform);
        txOut(headerStart:headerStop) = segOut;
    end
end

if isstruct(dataFhCfg) && isfield(dataFhCfg, "enable") && dataFhCfg.enable
    dataStart = min(max(1, dataStart), numel(txOut) + 1);
    if dataStart <= numel(txOut)
        [segOut, ~] = fh_modulate_samples(txOut(dataStart:end), dataFhCfg, waveform);
        txOut(dataStart:end) = segOut;
    end
end
end

function sampleIdx = local_symbol_boundary_sample_index_rx_local(nLeadingSym, waveform)
nLeadingSym = max(0, round(double(nLeadingSym)));
sampleIdx = nLeadingSym * round(double(waveform.sps)) + 1;
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

function plan = local_build_receiver_method_plan_local(mitigationMethods, channelCfg, rxSyncCfg)
baseMethods = string(mitigationMethods(:).');
if isempty(baseMethods) || any(strlength(baseMethods) == 0)
    error("receiver method plan requires non-empty mitigation methods.");
end

compareEq = local_multipath_eq_compare_enabled_local(channelCfg, rxSyncCfg);
if compareEq
    eqMethods = local_validate_equalizer_compare_methods_local(rxSyncCfg.multipathEq.compareMethods);
else
    eqMethods = "none";
end

labels = strings(1, 0);
actions = strings(1, 0);
equalizers = strings(1, 0);
nBase = numel(baseMethods);

for ib = 1:nBase
    eqForBase = local_equalizer_methods_for_action_compare_local(baseMethods(ib), eqMethods, compareEq);
    for ieq = 1:numel(eqForBase)
        actions(end + 1) = baseMethods(ib); %#ok<AGROW>
        equalizers(end + 1) = eqForBase(ieq); %#ok<AGROW>
        if compareEq
            labels(end + 1) = baseMethods(ib) + "_eq_" + eqForBase(ieq); %#ok<AGROW>
        else
            labels(end + 1) = baseMethods(ib); %#ok<AGROW>
        end
    end
end

plan = struct( ...
    "labels", labels, ...
    "mitigationMethods", actions, ...
    "equalizerMethods", equalizers, ...
    "baseMethods", baseMethods, ...
    "equalizerCompareEnabled", compareEq, ...
    "equalizerCompareMethods", eqMethods);
end

function eqMethods = local_equalizer_methods_for_action_compare_local(~, compareEqMethods, compareEq)
if ~logical(compareEq)
    eqMethods = "none";
    return;
end
eqMethods = compareEqMethods;
end

function tf = local_multipath_eq_compare_enabled_local(channelCfg, rxSyncCfg)
tf = false;
if ~isstruct(channelCfg) || ~isfield(channelCfg, "multipath") || ~isstruct(channelCfg.multipath) ...
        || ~isfield(channelCfg.multipath, "enable") || ~channelCfg.multipath.enable
    return;
end
if ~isstruct(rxSyncCfg) || ~isfield(rxSyncCfg, "multipathEq") || ~isstruct(rxSyncCfg.multipathEq)
    error("rxSync.multipathEq is required when channel.multipath.enable=true.");
end
if ~isfield(rxSyncCfg.multipathEq, "compareMethods") || isempty(rxSyncCfg.multipathEq.compareMethods)
    error("rxSync.multipathEq.compareMethods is required when channel.multipath.enable=true.");
end
local_validate_equalizer_compare_methods_local(rxSyncCfg.multipathEq.compareMethods);
tf = true;
end

function methods = local_validate_equalizer_compare_methods_local(rawMethods)
methods = lower(string(rawMethods(:).'));
if isempty(methods) || any(strlength(methods) == 0)
    error("rxSync.multipathEq.compareMethods must be a non-empty string vector.");
end
validMethods = ["none" "mmse" "zf" "ml_ridge" "ml_mlp" "sc_fde_mmse"];
invalid = setdiff(methods, validMethods);
if ~isempty(invalid)
    error("Unsupported multipath equalizer compareMethods: %s.", strjoin(cellstr(invalid), ", "));
end
if numel(unique(methods, "stable")) ~= numel(methods)
    error("rxSync.multipathEq.compareMethods must not contain duplicates.");
end
end

function rxSyncOut = local_rxsync_for_equalizer_method_local(rxSyncIn, equalizerMethod)
rxSyncOut = rxSyncIn;
equalizerMethod = lower(string(equalizerMethod));
if ~isstruct(rxSyncOut) || ~isfield(rxSyncOut, "multipathEq") || ~isstruct(rxSyncOut.multipathEq)
    error("rxSync.multipathEq is required for equalizer method %s.", equalizerMethod);
end
switch equalizerMethod
    case "none"
        rxSyncOut.multipathEq.enable = false;
        rxSyncOut.multipathEq.compareMethods = "none";
    case {"mmse", "zf", "ml_ridge", "ml_mlp", "sc_fde_mmse"}
        rxSyncOut.multipathEq.enable = true;
        rxSyncOut.multipathEq.compareMethods = equalizerMethod;
    otherwise
        error("Unsupported equalizer method: %s.", equalizerMethod);
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

function Lh = local_multipath_channel_len_symbols_local(channelCfg, ~)
Lh = 1;
if ~isfield(channelCfg, "multipath") || ~isstruct(channelCfg.multipath) ...
        || ~isfield(channelCfg.multipath, "enable") || ~channelCfg.multipath.enable
    return;
end

if ~(isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols))
    error("FH-aware multipath equalizer requires channel.multipath.pathDelaysSymbols.");
end
dly = double(channelCfg.multipath.pathDelaysSymbols(:));
if isempty(dly) || any(~isfinite(dly)) || any(dly < 0) || any(abs(dly - round(dly)) > 1e-12)
    error("channel.multipath.pathDelaysSymbols must contain nonnegative integer symbol delays.");
end
Lh = max(1, round(max(dly)) + 1);
end

function eq = local_design_multipath_equalizer_local(txPreamble, rxPreamble, eqCfg, N0, chLenSymbols, freqBySymbol)
eqCfgUse = eqCfg;
requestedMethod = local_configured_equalizer_method_from_compare_methods_local(eqCfgUse);
if requestedMethod == "sc_fde_mmse"
    eqCfgUse.method = "mmse";
else
    eqCfgUse.method = requestedMethod;
end
eqCfgUse.frequencyOffsets = local_equalizer_frequency_set_local(freqBySymbol);
[eq, ok] = multipath_equalizer_from_preamble(txPreamble, rxPreamble, eqCfgUse, N0, chLenSymbols);
if ~ok
    error("Multipath equalizer design failed.");
end
if requestedMethod == "sc_fde_mmse"
    eq.method = "sc_fde_mmse";
end
end

function candidates = local_build_header_decode_candidates_local(rFullRaw, rFullConfigured, txPreamble, rxSyncCfg, N0, chLenSymbols, freqBySymbol, symbolAction, mitigation)
rFullRaw = rFullRaw(:);
rFullConfigured = rFullConfigured(:);
if numel(rFullRaw) ~= numel(rFullConfigured)
    error("Header decode equalizer candidates require raw/configured blocks with identical lengths.");
end

requestedMethods = local_header_decode_equalizer_methods_local(rxSyncCfg);
candidates = repmat(struct("method", "", "rFull", complex(zeros(0, 1))), 0, 1);
actualMethods = strings(1, 0);

for requestedMethod = requestedMethods
    actualMethod = requestedMethod;
    if any(actualMethods == actualMethod)
        continue;
    end

    if actualMethod == "none"
        rFullNow = rFullRaw;
    else
        if actualMethod == local_configured_equalizer_method_from_compare_methods_local(rxSyncCfg.multipathEq)
            rFullNow = rFullConfigured;
        else
            eqCfgNow = rxSyncCfg.multipathEq;
            eqCfgNow.compareMethods = actualMethod;
            preambleForEqNow = local_preamble_for_equalizer_estimation_local( ...
                rFullRaw(1:numel(txPreamble)), symbolAction, mitigation);
            eqNow = local_design_multipath_equalizer_local( ...
                txPreamble, preambleForEqNow, eqCfgNow, N0, chLenSymbols, freqBySymbol);
            rFullNow = local_apply_frequency_aware_equalizer_block_local(rFullRaw, eqNow, freqBySymbol);
        end
    end

    candidates(end + 1) = struct("method", actualMethod, "rFull", rFullNow); %#ok<AGROW>
    actualMethods(end + 1) = actualMethod; %#ok<AGROW>
end

if isempty(candidates)
    error("Header decode equalizer diversity produced no candidates.");
end
end

function candidates = local_single_header_decode_candidate_local(methodName, rFull)
candidates = struct("method", string(methodName), "rFull", rFull(:));
end

function methods = local_header_decode_equalizer_methods_local(rxSyncCfg)
if ~(isstruct(rxSyncCfg) && isfield(rxSyncCfg, "multipathEq") && isstruct(rxSyncCfg.multipathEq))
    error("rxSync.multipathEq is required for PHY-header equalizer diversity.");
end
if ~(isfield(rxSyncCfg.multipathEq, "compareMethods") && ~isempty(rxSyncCfg.multipathEq.compareMethods))
    error("rxSync.multipathEq.compareMethods is required when multipath equalization is enabled.");
end
methods = lower(string(rxSyncCfg.multipathEq.compareMethods(:).'));
validMethods = ["none" "mmse" "zf" "ml_ridge" "ml_mlp" "sc_fde_mmse"];
invalid = setdiff(methods, validMethods);
if ~isempty(invalid)
    error("Unsupported rxSync.multipathEq.compareMethods entries for PHY-header decode: %s.", strjoin(cellstr(invalid), ", "));
end
if numel(unique(methods, "stable")) ~= numel(methods)
    error("rxSync.multipathEq.compareMethods must not contain duplicates.");
end
end

function method = local_configured_equalizer_method_from_compare_methods_local(eqCfg)
if ~(isstruct(eqCfg) && isfield(eqCfg, "compareMethods") && ~isempty(eqCfg.compareMethods))
    error("rxSync.multipathEq.compareMethods is required.");
end
methods = local_validate_equalizer_compare_methods_local(eqCfg.compareMethods);
configuredIdx = find(methods ~= "none", 1, "first");
if isempty(configuredIdx)
    error("rxSync.multipathEq.compareMethods must contain at least one non-""none"" equalizer method.");
end
method = methods(configuredIdx);
end

function freqSet = local_equalizer_frequency_set_local(freqBySymbol)
freqBySymbol = double(freqBySymbol(:).');
if isempty(freqBySymbol)
    freqSet = 0;
    return;
end
if any(~isfinite(freqBySymbol))
    error("Equalizer frequency vector contains non-finite entries.");
end
freqSet = unique([0, freqBySymbol], "stable");
end

function freqBySymbol = local_packet_equalizer_frequency_vector_local(txPacket, fhCaptureCfg, totalLen)
preLen = numel(txPacket.syncSym);
hdrLen = numel(txPacket.phyHeaderSymTx);
dataLen = numel(txPacket.dataSymHop);
totalLen = round(double(totalLen));
if totalLen ~= preLen + hdrLen + dataLen
    error("Packet equalizer length mismatch: totalLen=%d, sync+header+data=%d.", ...
        totalLen, preLen + hdrLen + dataLen);
end

freqBySymbol = zeros(totalLen, 1);
if totalLen == 0
    return;
end
if ~(isstruct(fhCaptureCfg) && isfield(fhCaptureCfg, "enable") && logical(fhCaptureCfg.enable))
    return;
end

if isfield(fhCaptureCfg, "headerFhCfg") && isstruct(fhCaptureCfg.headerFhCfg) ...
        && isfield(fhCaptureCfg.headerFhCfg, "enable") && logical(fhCaptureCfg.headerFhCfg.enable)
    freqBySymbol(preLen+1:preLen+hdrLen) = ...
        local_symbol_frequency_offsets_from_fh_cfg_local(fhCaptureCfg.headerFhCfg, hdrLen);
end
if isfield(fhCaptureCfg, "dataFhCfg") && isstruct(fhCaptureCfg.dataFhCfg) ...
        && isfield(fhCaptureCfg.dataFhCfg, "enable") && logical(fhCaptureCfg.dataFhCfg.enable)
    freqBySymbol(preLen+hdrLen+1:end) = ...
        local_symbol_frequency_offsets_from_fh_cfg_local(fhCaptureCfg.dataFhCfg, dataLen);
end
end

function freqBySymbol = local_session_equalizer_frequency_vector_local(sessionFrame, fhCaptureCfg, totalLen)
preLen = numel(sessionFrame.syncSym);
dataLen = double(sessionFrame.nDataSym);
totalLen = round(double(totalLen));
if totalLen ~= preLen + dataLen
    error("Session equalizer length mismatch: totalLen=%d, sync+data=%d.", ...
        totalLen, preLen + dataLen);
end

freqBySymbol = zeros(totalLen, 1);
if totalLen == 0
    return;
end
if ~(isstruct(fhCaptureCfg) && isfield(fhCaptureCfg, "enable") && logical(fhCaptureCfg.enable))
    return;
end
if isfield(fhCaptureCfg, "dataFhCfg") && isstruct(fhCaptureCfg.dataFhCfg) ...
        && isfield(fhCaptureCfg.dataFhCfg, "enable") && logical(fhCaptureCfg.dataFhCfg.enable)
    freqBySymbol(preLen+1:end) = ...
        local_symbol_frequency_offsets_from_fh_cfg_local(fhCaptureCfg.dataFhCfg, dataLen);
end
end

function freqBySymbol = local_symbol_frequency_offsets_from_fh_cfg_local(fhCfg, nSym)
nSym = round(double(nSym));
if ~(isscalar(nSym) && isfinite(nSym) && nSym >= 0)
    error("FH frequency expansion requires a finite nonnegative symbol count.");
end
freqBySymbol = zeros(nSym, 1);
if nSym == 0
    return;
end
if ~(isstruct(fhCfg) && isfield(fhCfg, "enable") && logical(fhCfg.enable))
    return;
end
if ~(isfield(fhCfg, "freqSet") && ~isempty(fhCfg.freqSet))
    error("FH-aware equalizer requires fhCfg.freqSet when FH is enabled.");
end

if fh_is_fast(fhCfg)
    [freqIdx, ~] = fh_generate_sequence(nSym, fhCfg);
    freqIdx = round(double(freqIdx(:)));
    freqSet = double(fhCfg.freqSet(:));
    if any(freqIdx < 1) || any(freqIdx > numel(freqSet))
        error("Fast FH frequency index exceeds fhCfg.freqSet.");
    end
    freqBySymbol = freqSet(freqIdx);
    return;
end

hopInfo = fh_hop_info_from_cfg(fhCfg, nSym);
freqBySymbol = local_expand_hop_frequency_offsets_local(hopInfo, nSym);
end

function freqBySymbol = local_expand_hop_frequency_offsets_local(hopInfo, nSym)
nSym = round(double(nSym));
if ~(isstruct(hopInfo) && isfield(hopInfo, "enable") && logical(hopInfo.enable))
    freqBySymbol = zeros(nSym, 1);
    return;
end
if ~(isfield(hopInfo, "hopLen") && ~isempty(hopInfo.hopLen))
    error("Slow FH equalizer expansion requires hopInfo.hopLen.");
end
hopLen = round(double(hopInfo.hopLen));
if ~(isscalar(hopLen) && isfinite(hopLen) && hopLen >= 1)
    error("Slow FH equalizer expansion requires a positive finite hopLen.");
end
if ~(isfield(hopInfo, "freqOffsets") && ~isempty(hopInfo.freqOffsets))
    error("FH equalizer expansion requires hopInfo.freqOffsets.");
end
nHops = ceil(double(nSym) / double(hopLen));
freqOffsets = double(hopInfo.freqOffsets(:));
if numel(freqOffsets) < nHops
    error("FH equalizer expansion needs %d hop frequencies, got %d.", nHops, numel(freqOffsets));
end
freqBySymbol = repelem(freqOffsets(1:nHops), hopLen, 1);
freqBySymbol = freqBySymbol(1:nSym);
end

function yEq = local_apply_frequency_aware_equalizer_block_local(y, eq, freqBySymbol)
y = y(:);
N = numel(y);
freqBySymbol = double(freqBySymbol(:));
if numel(freqBySymbol) ~= N
    error("Equalizer frequency vector length %d does not match block length %d.", numel(freqBySymbol), N);
end
if N == 0
    yEq = y;
    return;
end
if ~(isstruct(eq) && isfield(eq, "enabled") && logical(eq.enabled))
    error("Frequency-aware multipath equalizer requires eq.enabled=true.");
end
if isfield(eq, "method") && string(eq.method) == "ml_mlp"
    if ~(isfield(eq, "mlMlp") && isstruct(eq.mlMlp) && isfield(eq, "hBank") && isfield(eq, "frequencyOffsets") && isfield(eq, "N0"))
        error("ML MLP multipath equalizer requires eq.mlMlp, eq.hBank, eq.frequencyOffsets and eq.N0.");
    end
    [yEqMl, mlInfo] = ml_predict_multipath_equalizer_symbols(y, freqBySymbol, eq.hBank, double(eq.frequencyOffsets(:)), double(eq.N0), eq.mlMlp);
    if ~(isfield(mlInfo, "baseline") && numel(mlInfo.baseline) == numel(yEqMl) && isfield(eq, "mlMlpBlend"))
        error("ML MLP multipath equalizer requires baseline info and eq.mlMlpBlend.");
    end
    blend = double(eq.mlMlpBlend);
    if ~(isscalar(blend) && isfinite(blend) && blend >= 0 && blend <= 1)
        error("eq.mlMlpBlend must be a finite scalar in [0, 1].");
    end
    yEq = mlInfo.baseline(:) + blend * (yEqMl(:) - mlInfo.baseline(:));
    return;
end
if ~(isfield(eq, "gBank") && ~isempty(eq.gBank) && isfield(eq, "frequencyOffsets") && ~isempty(eq.frequencyOffsets))
    error("Frequency-aware multipath equalizer requires eq.gBank and eq.frequencyOffsets.");
end
if ~(isfield(eq, "delay") && isfield(eq, "eqLen"))
    error("Frequency-aware multipath equalizer requires eq.delay and eq.eqLen.");
end

d = max(0, round(double(eq.delay)));
Leq = round(double(eq.eqLen));
gBank = eq.gBank;
if size(gBank, 1) ~= Leq
    error("Equalizer bank row count %d does not match eq.eqLen=%d.", size(gBank, 1), Leq);
end

bankIdx = local_equalizer_bank_indices_for_freqs_local(eq.frequencyOffsets, freqBySymbol);
yEq = complex(zeros(N, 1));
for n = 1:N
    g = gBank(:, bankIdx(n));
    acc = complex(0, 0);
    for tap = 1:Leq
        srcIdx = n + d - tap + 1;
        if srcIdx >= 1 && srcIdx <= N
            acc = acc + g(tap) * y(srcIdx);
        end
    end
    yEq(n) = acc;
end
end

function reliability = local_multipath_equalizer_reliability_vector_local(eq, freqBySymbol, mitigation)
freqBySymbol = double(freqBySymbol(:));
reliability = ones(numel(freqBySymbol), 1);
if isempty(freqBySymbol)
    return;
end
cfg = local_require_fh_erasure_cfg_local(mitigation);
if ~cfg.multipathFadeEnable
    return;
end
if ~(isstruct(eq) && isfield(eq, "enabled") && logical(eq.enabled))
    error("Multipath fade erasure requires an enabled equalizer.");
end
if isfield(eq, "method") && lower(string(eq.method)) == "ml_mlp"
    return;
end
if ~(isfield(eq, "gBank") && ~isempty(eq.gBank) ...
        && isfield(eq, "hBank") && ~isempty(eq.hBank) ...
        && isfield(eq, "frequencyOffsets") && ~isempty(eq.frequencyOffsets) ...
        && isfield(eq, "delay") && isfield(eq, "N0"))
    error("Multipath fade erasure requires eq.gBank, eq.hBank, eq.frequencyOffsets, eq.delay and eq.N0.");
end

gBank = eq.gBank;
hBank = eq.hBank;
if size(gBank, 2) ~= numel(eq.frequencyOffsets) || size(hBank, 2) ~= numel(eq.frequencyOffsets)
    error("Multipath fade erasure bank dimensions do not match eq.frequencyOffsets.");
end

nBank = numel(eq.frequencyOffsets);
noiseGain = sum(abs(gBank).^2, 1).';
sinrDb = nan(nBank, 1);
mainIdx = round(double(eq.delay)) + 1;
N0 = double(eq.N0);
if ~(isscalar(N0) && isfinite(N0) && N0 >= 0)
    error("eq.N0 must be a finite nonnegative scalar for multipath fade erasure.");
end
for k = 1:nBank
    c = conv(hBank(:, k), gBank(:, k));
    if mainIdx < 1 || mainIdx > numel(c)
        error("Equalizer delay index is outside the effective channel response.");
    end
    mainPower = abs(c(mainIdx)).^2;
    isiPower = max(sum(abs(c).^2) - mainPower, 0);
    denom = isiPower + N0 * noiseGain(k);
    sinrDb(k) = 10 * log10(max(mainPower, eps) / max(denom, eps));
end

validNoise = isfinite(noiseGain) & noiseGain > 0;
validSinr = isfinite(sinrDb);
if ~any(validNoise) || ~any(validSinr)
    error("Multipath fade erasure could not derive finite equalizer reliability.");
end
noiseRef = median(noiseGain(validNoise));
sinrRefDb = median(sinrDb(validSinr));
if ~(isfinite(noiseRef) && noiseRef > 0 && isfinite(sinrRefDb))
    error("Multipath fade erasure reference metrics are invalid.");
end

noiseRatio = noiseGain ./ noiseRef;
relNoise = local_erasure_reliability_from_ratio_local( ...
    noiseRatio, cfg.multipathNoiseGainRatioThreshold, cfg.minReliability, cfg.multipathSoftSlope);

sinrTriggerDb = sinrRefDb - cfg.multipathSinrDropDbThreshold;
sinrDeficit = max(sinrTriggerDb - sinrDb, 0);
sinrRatio = 1 + sinrDeficit ./ max(cfg.multipathSinrDropDbThreshold, 1);
relSinr = local_erasure_reliability_from_ratio_local( ...
    sinrRatio, 1, cfg.minReliability, cfg.multipathSoftSlope);

relBank = min(relNoise, relSinr);
relBank(~isfinite(relBank)) = 1;
relBank = max(cfg.minReliability, min(1, relBank));

bankIdx = local_equalizer_bank_indices_for_freqs_local(eq.frequencyOffsets, freqBySymbol);
reliability = relBank(bankIdx);
reliability = max(cfg.minReliability, min(1, reliability(:)));
end

function bankIdx = local_equalizer_bank_indices_for_freqs_local(bankFreqs, freqBySymbol)
bankFreqs = double(bankFreqs(:));
freqBySymbol = double(freqBySymbol(:));
if isempty(bankFreqs)
    error("Equalizer bank frequency list must not be empty.");
end
bankIdx = zeros(numel(freqBySymbol), 1);
tol = 1e-10;
for k = 1:numel(freqBySymbol)
    [err, idx] = min(abs(bankFreqs - freqBySymbol(k)));
    if isempty(idx) || err > tol
        error("Equalizer bank does not contain normalized frequency %.12g.", freqBySymbol(k));
    end
    bankIdx(k) = idx;
end
end

function [yPrep, relPrep] = local_prepare_data_symbols_local(rData, rawReliability, rxState, hopInfoUsed, modCfg, rxSyncCfg, fhEnabled, actionName, mitigation)
% Prepare per-packet data symbols (dehop -> targeted mitigation -> carrier PLL).
%
% FH-aware multipath equalization has already been applied on the full
% [preamble; PHY; data] block. Here we only process the payload region.
if local_rx_state_sc_fde_diversity_enabled_local(rxState)
    [r, relPrep] = local_prepare_sc_fde_diversity_data_symbols_local( ...
        rxState, hopInfoUsed, modCfg, rxSyncCfg, fhEnabled, actionName, mitigation);
else
    [r, relPrep] = local_prepare_data_symbols_prescfde_local( ...
        rData, rawReliability, rxState, hopInfoUsed, modCfg, fhEnabled, actionName, mitigation);
    if local_rx_state_sc_fde_enabled_local(rxState)
        [r, relPrep] = local_prepare_sc_fde_payload_local(r, relPrep, rxState, rxSyncCfg);
    end
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

function [r, relPrep, rawReliability] = local_prepare_data_symbols_prescfde_local(rData, rawReliabilityIn, rxState, hopInfoUsed, modCfg, fhEnabled, actionName, mitigation)
r = fit_complex_length_local(rData, rxState.nDataSym);
rawReliability = local_fit_reliability_length_local(rawReliabilityIn, rxState.nDataSym);
fastFhEnabled = isfield(rxState, "fhCfg") && isstruct(rxState.fhCfg) ...
    && isfield(rxState.fhCfg, "enable") && rxState.fhCfg.enable && fh_is_fast(rxState.fhCfg);
sampleFhDataDemod = isfield(rxState, "sampleFhDataDemod") && logical(rxState.sampleFhDataDemod);

if fastFhEnabled
    [r, rawReliability] = local_fast_fh_symbol_prepare_local(r, rawReliability, hopInfoUsed, rxState);
elseif fhEnabled && ~sampleFhDataDemod
    r = fh_demodulate(r, hopInfoUsed);
end

[r, relPrep] = local_apply_data_action_local(r, actionName, mitigation, hopInfoUsed, fhEnabled && ~fastFhEnabled, modCfg, local_rx_state_psymbol_blend_local(rxState));
relPrep = local_fit_reliability_length_local(relPrep, numel(r));
if any(actionName == ["fh_erasure" "ml_fh_erasure"])
    [r, relPrep] = local_apply_multipath_fade_erasure_local(r, relPrep, rxState, mitigation);
end
if all(relPrep >= 0.999999)
    relPrep = rawReliability;
else
    relPrep = min(relPrep, rawReliability);
end
end

function [rOut, relOut] = local_prepare_sc_fde_diversity_data_symbols_local(rxState, hopInfoUsed, modCfg, rxSyncCfg, fhEnabled, actionName, mitigation)
divState = local_require_sc_fde_diversity_state_local(rxState);
nBranches = double(divState.nBranches);
branchSymbols = cell(nBranches, 1);
branchReliability = cell(nBranches, 1);
fallbackSymbols = cell(nBranches, 1);
fallbackReliability = cell(nBranches, 1);
fallbackAvailable = logical(divState.fallbackEnable);

for branchIdx = 1:nBranches
    [branchSymbols{branchIdx}, branchReliability{branchIdx}] = local_prepare_data_symbols_prescfde_local( ...
        divState.payloadBranches{branchIdx}, divState.reliabilityBranches{branchIdx}, ...
        rxState, hopInfoUsed, modCfg, fhEnabled, actionName, mitigation);
    if fallbackAvailable
        [fallbackSymbols{branchIdx}, fallbackReliability{branchIdx}] = local_prepare_data_symbols_prescfde_local( ...
            divState.fallbackBranches{branchIdx}, divState.fallbackReliabilityBranches{branchIdx}, ...
            rxState, hopInfoUsed, modCfg, fhEnabled, actionName, mitigation);
    end
end

if local_sc_fde_equalizer_method_local(rxSyncCfg)
    [rOut, relOut] = local_apply_sc_fde_mmse_payload_diversity_local( ...
        branchSymbols, branchReliability, fallbackSymbols, fallbackReliability, rxState, rxSyncCfg);
else
    [rOut, relOut] = local_apply_sc_fde_payload_diversity_local( ...
        branchSymbols, branchReliability, rxState);
end
end

function [rOut, relOut] = local_fast_fh_symbol_prepare_local(rIn, relIn, hopInfoUsed, rxState)
rIn = rIn(:);
relIn = local_fit_reliability_length_local(relIn, numel(rIn));
if ~(isfield(rxState, "nDataSymBase") && ~isempty(rxState.nDataSymBase))
    error("fast FH payload recovery requires rxState.nDataSymBase.");
end
if ~(isfield(rxState, "fhCfg") && isstruct(rxState.fhCfg) && fh_is_fast(rxState.fhCfg))
    error("local_fast_fh_symbol_prepare_local requires fast FH rxState.fhCfg.");
end

hopsPerSymbol = fh_hops_per_symbol(rxState.fhCfg);
nBase = round(double(rxState.nDataSymBase));
nExpected = nBase * hopsPerSymbol;
rUse = fit_complex_length_local(rIn, nExpected);
relUse = local_fit_reliability_length_local(relIn, nExpected);

if isstruct(hopInfoUsed) && isfield(hopInfoUsed, "enable") && hopInfoUsed.enable
    if ~(isfield(hopInfoUsed, "mode") && string(hopInfoUsed.mode) == "fast")
        error("fast FH payload recovery requires fast-mode hopInfo.");
    end
end

rOut = local_group_mean_complex_local(rUse, hopsPerSymbol, nBase);
relOut = local_group_mean_real_local(relUse, hopsPerSymbol, nBase);
end

function y = local_group_mean_complex_local(x, groupLen, nGroups)
x = x(:);
groupLen = max(1, round(double(groupLen)));
nGroups = max(0, round(double(nGroups)));
needLen = groupLen * nGroups;
if needLen <= 0
    y = complex(zeros(0, 1));
    return;
end
if numel(x) < needLen
    error("group mean requires %d samples, got %d.", needLen, numel(x));
end
x = reshape(x(1:needLen), groupLen, nGroups);
y = mean(x, 1).';
end

function y = local_group_mean_real_local(x, groupLen, nGroups)
x = double(x(:));
groupLen = max(1, round(double(groupLen)));
nGroups = max(0, round(double(nGroups)));
needLen = groupLen * nGroups;
if needLen <= 0
    y = zeros(0, 1);
    return;
end
if numel(x) < needLen
    error("group mean requires %d samples, got %d.", needLen, numel(x));
end
x = reshape(x(1:needLen), groupLen, nGroups);
y = mean(x, 1).';
end

function [rOut, relOut] = local_prepare_sc_fde_payload_local(rIn, relIn, rxState, rxSyncCfg)
if ~(isstruct(rxState) && isfield(rxState, "scFdePlan") && isstruct(rxState.scFdePlan) ...
        && isfield(rxState.scFdePlan, "enable") && logical(rxState.scFdePlan.enable))
    error("SC-FDE payload preparation requires rxState.scFdePlan.enable=true.");
end
plan = rxState.scFdePlan;
cfg = rxState.scFdeCfg;
r = fit_complex_length_local(rIn, plan.nTxSymbols);
rel = local_fit_reliability_length_local(relIn, plan.nTxSymbols);

if local_sc_fde_equalizer_method_local(rxSyncCfg)
    [rOut, relOut] = local_apply_sc_fde_mmse_payload_local(r, rel, rxState, cfg, plan);
else
    [rOut, relOut] = local_strip_sc_fde_payload_local(r, rel, rxState, cfg, plan);
end
rOut = fit_complex_length_local(rOut, plan.nInputSymbols);
relOut = local_fit_reliability_length_local(relOut, plan.nInputSymbols);
end

function [dataOut, relOut] = local_strip_sc_fde_payload_local(r, rel, rxState, cfg, plan)
dataOutFull = complex(zeros(plan.nHops * plan.dataSymbolsPerHop, 1));
relOutFull = ones(plan.nHops * plan.dataSymbolsPerHop, 1);
for hopIdx = 1:plan.nHops
    [core, relCore] = local_sc_fde_core_from_physical_hop_local(r, rel, hopIdx, plan);
    dataIdx = (hopIdx - 1) * plan.dataSymbolsPerHop + (1:plan.dataSymbolsPerHop);
    dataOutFull(dataIdx) = core(plan.pilotLength + 1:end);
    relOutFull(dataIdx) = relCore(plan.pilotLength + 1:end);
    sc_fde_payload_pilot_symbols(cfg, rxState.packetIndex, hopIdx);
end
dataOut = dataOutFull(1:min(plan.nInputSymbols, numel(dataOutFull)));
relOut = relOutFull(1:min(plan.nInputSymbols, numel(relOutFull)));
end

function [dataOut, relOut] = local_apply_sc_fde_mmse_payload_local(r, rel, rxState, cfg, plan)
if ~(isfield(rxState, "scFdeEq") && isstruct(rxState.scFdeEq))
    error("SC-FDE MMSE requires rxState.scFdeEq.");
end
eq = rxState.scFdeEq;
if ~(isfield(eq, "hBank") && ~isempty(eq.hBank) && isfield(eq, "frequencyOffsets") && ~isempty(eq.frequencyOffsets))
    error("SC-FDE MMSE requires eq.hBank and eq.frequencyOffsets.");
end
if ~(isfield(rxState, "hopInfo") && isstruct(rxState.hopInfo))
    error("SC-FDE MMSE requires rxState.hopInfo.");
end
N0 = 0;
if isfield(rxState, "scFdeN0") && ~isempty(rxState.scFdeN0)
    N0 = double(rxState.scFdeN0);
elseif isfield(eq, "N0") && ~isempty(eq.N0)
    N0 = double(eq.N0);
end
if ~(isscalar(N0) && isfinite(N0) && N0 >= 0)
    error("SC-FDE MMSE requires a finite nonnegative N0.");
end

dataOutFull = complex(zeros(plan.nHops * plan.dataSymbolsPerHop, 1));
relOutFull = ones(plan.nHops * plan.dataSymbolsPerHop, 1);
lambda = double(cfg.lambdaFactor) * N0;
if ~(isscalar(lambda) && isfinite(lambda) && lambda >= 0)
    error("SC-FDE lambda must be finite and nonnegative.");
end

hopFreqs = local_sc_fde_hop_frequencies_local(rxState.hopInfo, plan.nHops);
bankIdx = local_equalizer_bank_indices_for_freqs_local(eq.frequencyOffsets, hopFreqs);
fallbackSymbols = complex(zeros(0, 1));
fallbackReliability = zeros(0, 1);
fallbackAvailable = isfield(rxState, "scFdeFallbackSymbols") && ~isempty(rxState.scFdeFallbackSymbols);
if fallbackAvailable
    fallbackSymbols = fit_complex_length_local(rxState.scFdeFallbackSymbols, plan.nTxSymbols);
    if isfield(rxState, "scFdeFallbackReliability") && ~isempty(rxState.scFdeFallbackReliability)
        fallbackReliability = local_fit_reliability_length_local(rxState.scFdeFallbackReliability, plan.nTxSymbols);
    else
        fallbackReliability = ones(plan.nTxSymbols, 1);
    end
end

for hopIdx = 1:plan.nHops
    [core, relCore] = local_sc_fde_core_from_physical_hop_local(r, rel, hopIdx, plan);
    h = eq.hBank(:, bankIdx(hopIdx));
    if numel(h) - 1 > plan.cpLen
        error("SC-FDE CP length %d is shorter than estimated channel memory %d.", plan.cpLen, numel(h) - 1);
    end
    if numel(h) > plan.coreLen
        error("SC-FDE core length %d is shorter than estimated channel length %d.", plan.coreLen, numel(h));
    end

    H = fft([h(:); complex(zeros(plan.coreLen - numel(h), 1))]);
    denom = abs(H).^2 + lambda;
    if any(~isfinite(denom)) || any(denom <= 0)
        error("SC-FDE MMSE denominator is invalid.");
    end
    xCore = local_apply_sc_fde_mmse_core_local(core, h, lambda, plan);

    pilot = sc_fde_payload_pilot_symbols(cfg, rxState.packetIndex, hopIdx);
    maxPilotShift = min(plan.cpLen, max(0, numel(h) - 1));
    [xCore, hopReliability, fdeMse] = local_sc_fde_apply_pilot_scalar_local(xCore, pilot, cfg, maxPilotShift);
    relCore = min(relCore, hopReliability);

    if fallbackAvailable
        [fallbackCoreRaw, fallbackRelCore] = local_sc_fde_core_from_physical_hop_local( ...
            fallbackSymbols, fallbackReliability, hopIdx, plan);
        [~, ~, fallbackMse] = local_sc_fde_apply_pilot_scalar_local( ...
            fallbackCoreRaw, pilot, cfg, maxPilotShift);
        useFde = fdeMse <= double(cfg.fdePilotMseThreshold) ...
            && fdeMse <= double(cfg.fdePilotMseMargin) * fallbackMse;
        if ~useFde
            xCore = fallbackCoreRaw;
            relCore = fallbackRelCore;
        end
    end

    dataIdx = (hopIdx - 1) * plan.dataSymbolsPerHop + (1:plan.dataSymbolsPerHop);
    dataOutFull(dataIdx) = xCore(plan.pilotLength + 1:end);
    relOutFull(dataIdx) = relCore(plan.pilotLength + 1:end);
end

dataOut = dataOutFull(1:min(plan.nInputSymbols, numel(dataOutFull)));
relOut = relOutFull(1:min(plan.nInputSymbols, numel(relOutFull)));
end

function [dataOut, relOut] = local_apply_sc_fde_mmse_payload_diversity_local(branchSymbols, branchReliability, fallbackSymbols, fallbackReliability, rxState, rxSyncCfg)
if ~local_sc_fde_equalizer_method_local(rxSyncCfg)
    error("SC-FDE diversity MMSE combining requires rxSync.multipathEq.compareMethods to include ""sc_fde_mmse"".");
end
divState = local_require_sc_fde_diversity_state_local(rxState);
plan = rxState.scFdePlan;
cfg = rxState.scFdeCfg;
nBranches = double(divState.nBranches);
if ~(iscell(branchSymbols) && iscell(branchReliability) ...
        && numel(branchSymbols) == nBranches && numel(branchReliability) == nBranches)
    error("SC-FDE diversity payload branches must match rxState.scFdeDiversity.nBranches.");
end

eqBranches = divState.eqBranches;
if ~(iscell(eqBranches) && numel(eqBranches) == nBranches)
    error("SC-FDE diversity state must provide one equalizer per branch.");
end

N0 = local_sc_fde_noise_power_local(rxState, eqBranches{1});
lambda = double(cfg.lambdaFactor) * N0;
if ~(isscalar(lambda) && isfinite(lambda) && lambda >= 0)
    error("SC-FDE diversity lambda must be finite and nonnegative.");
end

hopFreqs = local_sc_fde_hop_frequencies_local(rxState.hopInfo, plan.nHops);
bankIdx = cell(nBranches, 1);
for branchIdx = 1:nBranches
    eqBranch = eqBranches{branchIdx};
    if ~(isstruct(eqBranch) && isfield(eqBranch, "hBank") && ~isempty(eqBranch.hBank) ...
            && isfield(eqBranch, "frequencyOffsets") && ~isempty(eqBranch.frequencyOffsets))
        error("SC-FDE diversity branch %d requires hBank and frequencyOffsets.", branchIdx);
    end
    bankIdx{branchIdx} = local_equalizer_bank_indices_for_freqs_local(eqBranch.frequencyOffsets, hopFreqs);
    branchSymbols{branchIdx} = fit_complex_length_local(branchSymbols{branchIdx}, plan.nTxSymbols);
    branchReliability{branchIdx} = local_fit_reliability_length_local(branchReliability{branchIdx}, plan.nTxSymbols);
end

fallbackAvailable = logical(divState.fallbackEnable);
if fallbackAvailable
    if ~(iscell(fallbackSymbols) && iscell(fallbackReliability) ...
            && numel(fallbackSymbols) == nBranches && numel(fallbackReliability) == nBranches)
        error("SC-FDE diversity fallback branches must match rxState.scFdeDiversity.nBranches.");
    end
    for branchIdx = 1:nBranches
        fallbackSymbols{branchIdx} = fit_complex_length_local(fallbackSymbols{branchIdx}, plan.nTxSymbols);
        fallbackReliability{branchIdx} = local_fit_reliability_length_local(fallbackReliability{branchIdx}, plan.nTxSymbols);
    end
end

dataOutFull = complex(zeros(plan.nHops * plan.dataSymbolsPerHop, 1));
relOutFull = ones(plan.nHops * plan.dataSymbolsPerHop, 1);

for hopIdx = 1:plan.nHops
    pilot = sc_fde_payload_pilot_symbols(cfg, rxState.packetIndex, hopIdx);
    eqCoreList = cell(nBranches, 1);
    eqRelList = cell(nBranches, 1);
    eqGainList = ones(nBranches, 1);
    eqScoreList = zeros(nBranches, 1);
    maxPilotShiftList = zeros(nBranches, 1);

    for branchIdx = 1:nBranches
        [core, relCore] = local_sc_fde_core_from_physical_hop_local( ...
            branchSymbols{branchIdx}, branchReliability{branchIdx}, hopIdx, plan);
        eqBranch = eqBranches{branchIdx};
        h = eqBranch.hBank(:, bankIdx{branchIdx}(hopIdx));
        if numel(h) - 1 > plan.cpLen
            error("SC-FDE diversity CP length %d is shorter than branch %d channel memory %d at hop %d.", ...
                plan.cpLen, branchIdx, numel(h) - 1, hopIdx);
        end
        maxPilotShift = min(plan.cpLen, max(0, numel(h) - 1));
        maxPilotShiftList(branchIdx) = maxPilotShift;
        xCore = local_apply_sc_fde_mmse_core_local(core, h, lambda, plan);
        [~, eqCoreList{branchIdx}, hopRel] = local_sc_fde_align_core_to_pilot_local( ...
            xCore, pilot, cfg, maxPilotShift);
        eqRelList{branchIdx} = min(relCore, hopRel);
        eqScoreList(branchIdx) = mean(eqRelList{branchIdx});
    end

    eqScoreList = local_sc_fde_gate_branch_scores_local( ...
        eqScoreList, sprintf("SC-FDE diversity equalized hop %d", hopIdx));
    [xCoreCombRaw, relCoreComb] = local_sc_fde_mrc_combine_branch_cores_local( ...
        eqCoreList, eqRelList, eqGainList, eqScoreList, sprintf("SC-FDE diversity equalized hop %d", hopIdx));
    [xCoreComb, hopReliabilityComb, fdeMse] = local_sc_fde_apply_pilot_scalar_local(xCoreCombRaw, pilot, cfg, 0);
    relCoreComb = min(relCoreComb, hopReliabilityComb);

    if fallbackAvailable
        fallbackCoreList = cell(nBranches, 1);
        fallbackRelList = cell(nBranches, 1);
        fallbackGainList = ones(nBranches, 1);
        fallbackScoreList = zeros(nBranches, 1);
        for branchIdx = 1:nBranches
            [fallbackCoreRaw, fallbackRelCore] = local_sc_fde_core_from_physical_hop_local( ...
                fallbackSymbols{branchIdx}, fallbackReliability{branchIdx}, hopIdx, plan);
            [~, fallbackCoreList{branchIdx}, fallbackHopRel] = local_sc_fde_align_core_to_pilot_local( ...
                fallbackCoreRaw, pilot, cfg, maxPilotShiftList(branchIdx));
            fallbackRelList{branchIdx} = min(fallbackRelCore, fallbackHopRel);
            fallbackScoreList(branchIdx) = mean(fallbackRelList{branchIdx});
        end

        fallbackScoreList = local_sc_fde_gate_branch_scores_local( ...
            fallbackScoreList, sprintf("SC-FDE diversity fallback hop %d", hopIdx));
        [fallbackCombRaw, fallbackRelComb] = local_sc_fde_mrc_combine_branch_cores_local( ...
            fallbackCoreList, fallbackRelList, fallbackGainList, fallbackScoreList, sprintf("SC-FDE diversity fallback hop %d", hopIdx));
        [fallbackComb, fallbackHopReliability, fallbackMse] = local_sc_fde_apply_pilot_scalar_local( ...
            fallbackCombRaw, pilot, cfg, 0);
        fallbackRelComb = min(fallbackRelComb, fallbackHopReliability);

        useFde = fdeMse <= double(cfg.fdePilotMseThreshold) ...
            && fdeMse <= double(cfg.fdePilotMseMargin) * fallbackMse;
        if ~useFde
            xCoreComb = fallbackComb;
            relCoreComb = fallbackRelComb;
        end
    end

    dataIdx = (hopIdx - 1) * plan.dataSymbolsPerHop + (1:plan.dataSymbolsPerHop);
    dataOutFull(dataIdx) = xCoreComb(plan.pilotLength + 1:end);
    relOutFull(dataIdx) = relCoreComb(plan.pilotLength + 1:end);
end

dataOut = dataOutFull(1:min(plan.nInputSymbols, numel(dataOutFull)));
relOut = relOutFull(1:min(plan.nInputSymbols, numel(relOutFull)));
end

function [dataOut, relOut] = local_apply_sc_fde_payload_diversity_local(branchSymbols, branchReliability, rxState)
divState = local_require_sc_fde_diversity_state_local(rxState);
plan = rxState.scFdePlan;
cfg = rxState.scFdeCfg;
nBranches = double(divState.nBranches);
if ~(iscell(branchSymbols) && iscell(branchReliability) ...
        && numel(branchSymbols) == nBranches && numel(branchReliability) == nBranches)
    error("SC-FDE diversity payload branches must match rxState.scFdeDiversity.nBranches.");
end

for branchIdx = 1:nBranches
    branchSymbols{branchIdx} = fit_complex_length_local(branchSymbols{branchIdx}, plan.nTxSymbols);
    branchReliability{branchIdx} = local_fit_reliability_length_local(branchReliability{branchIdx}, plan.nTxSymbols);
end

dataOutFull = complex(zeros(plan.nHops * plan.dataSymbolsPerHop, 1));
relOutFull = ones(plan.nHops * plan.dataSymbolsPerHop, 1);

for hopIdx = 1:plan.nHops
    pilot = sc_fde_payload_pilot_symbols(cfg, rxState.packetIndex, hopIdx);
    coreList = cell(nBranches, 1);
    relList = cell(nBranches, 1);
    scoreList = zeros(nBranches, 1);

    for branchIdx = 1:nBranches
        [core, relCore] = local_sc_fde_core_from_physical_hop_local( ...
            branchSymbols{branchIdx}, branchReliability{branchIdx}, hopIdx, plan);
        [~, coreList{branchIdx}, hopRel] = local_sc_fde_align_core_to_pilot_local( ...
            core, pilot, cfg, plan.cpLen);
        relList{branchIdx} = min(relCore, hopRel);
        scoreList(branchIdx) = mean(relList{branchIdx});
    end

    scoreList = local_sc_fde_gate_branch_scores_local( ...
        scoreList, sprintf("SC-FDE diversity payload hop %d", hopIdx));
    [xCoreComb, relCoreComb] = local_sc_fde_mrc_combine_branch_cores_local( ...
        coreList, relList, ones(nBranches, 1), scoreList, sprintf("SC-FDE diversity payload hop %d", hopIdx));

    dataIdx = (hopIdx - 1) * plan.dataSymbolsPerHop + (1:plan.dataSymbolsPerHop);
    dataOutFull(dataIdx) = xCoreComb(plan.pilotLength + 1:end);
    relOutFull(dataIdx) = relCoreComb(plan.pilotLength + 1:end);
end

dataOut = dataOutFull(1:min(plan.nInputSymbols, numel(dataOutFull)));
relOut = relOutFull(1:min(plan.nInputSymbols, numel(relOutFull)));
end

function xCore = local_apply_sc_fde_mmse_core_local(core, h, lambda, plan)
core = core(:);
h = h(:);
if numel(h) > plan.coreLen
    error("SC-FDE core length %d is shorter than estimated channel length %d.", plan.coreLen, numel(h));
end
H = fft([h; complex(zeros(plan.coreLen - numel(h), 1))]);
denom = abs(H).^2 + lambda;
if any(~isfinite(denom)) || any(denom <= 0)
    error("SC-FDE MMSE denominator is invalid.");
end
xCore = ifft(conj(H) ./ denom .* fft(core));
end

function xCore = local_apply_sc_fde_mmse_simo_core_local(coreList, hList, lambda, plan, scoreWeights, ownerName)
if nargin < 5 || isempty(scoreWeights)
    scoreWeights = ones(numel(coreList), 1);
end
if nargin < 6 || strlength(string(ownerName)) == 0
    ownerName = "SC-FDE diversity SIMO MMSE";
end
if ~(iscell(coreList) && iscell(hList) && numel(coreList) == numel(hList) ...
        && numel(scoreWeights) == numel(coreList))
    error("%s requires matched core/channel/weight lists.", char(ownerName));
end

scoreWeights = double(scoreWeights(:));
numer = complex(zeros(plan.coreLen, 1));
denom = lambda * ones(plan.coreLen, 1);
validCount = 0;
for branchIdx = 1:numel(coreList)
    coreNow = coreList{branchIdx};
    hNow = hList{branchIdx};
    scoreNow = scoreWeights(branchIdx);
    if isempty(coreNow) || isempty(hNow)
        error("%s branch %d is empty.", char(ownerName), branchIdx);
    end
    if ~(isfinite(scoreNow) && scoreNow > 0)
        continue;
    end
    coreNow = coreNow(:);
    hNow = hNow(:);
    if numel(coreNow) ~= plan.coreLen
        error("%s branch %d core length mismatch.", char(ownerName), branchIdx);
    end
    if numel(hNow) > plan.coreLen
        error("%s branch %d channel length exceeds SC-FDE core length.", char(ownerName), branchIdx);
    end
    H = fft([hNow; complex(zeros(plan.coreLen - numel(hNow), 1))]);
    Y = fft(coreNow);
    numer = numer + scoreNow * conj(H) .* Y;
    denom = denom + scoreNow * abs(H).^2;
    validCount = validCount + 1;
end
if validCount == 0
    error("%s produced no valid branches.", char(ownerName));
end
if any(~isfinite(denom)) || any(denom <= 0)
    error("%s denominator is invalid.", char(ownerName));
end
xCore = ifft(numer ./ denom);
end

function N0 = local_sc_fde_noise_power_local(rxState, eq)
N0 = 0;
if isfield(rxState, "scFdeN0") && ~isempty(rxState.scFdeN0)
    N0 = double(rxState.scFdeN0);
elseif nargin >= 2 && isstruct(eq) && isfield(eq, "N0") && ~isempty(eq.N0)
    N0 = double(eq.N0);
end
if ~(isscalar(N0) && isfinite(N0) && N0 >= 0)
    error("SC-FDE MMSE requires a finite nonnegative N0.");
end
end

function [coreOut, relOut] = local_sc_fde_mrc_combine_branch_cores_local(coreList, relList, gains, scoreWeights, ownerName)
if nargin < 4 || isempty(scoreWeights)
    scoreWeights = ones(numel(coreList), 1);
end
if nargin < 5 || strlength(string(ownerName)) == 0
    ownerName = "SC-FDE diversity combining";
end
if ~(iscell(coreList) && iscell(relList) && numel(coreList) == numel(relList) ...
        && numel(gains) == numel(coreList) && numel(scoreWeights) == numel(coreList))
    error("%s requires matched core/reliability/gain lists.", char(ownerName));
end

scoreWeights = double(scoreWeights(:));

validMask = false(numel(coreList), 1);
coreLen = [];
for branchIdx = 1:numel(coreList)
    coreNow = coreList{branchIdx};
    relNow = relList{branchIdx};
    if isempty(coreNow) || isempty(relNow)
        error("%s branch %d is empty.", char(ownerName), branchIdx);
    end
    coreNow = coreNow(:);
    relNow = local_fit_reliability_length_local(relNow, numel(coreNow));
    coreList{branchIdx} = coreNow;
    relList{branchIdx} = relNow;
    gainNow = gains(branchIdx);
    scoreNow = scoreWeights(branchIdx);
    if ~(isfinite(gainNow) && abs(gainNow) > 0 && isfinite(scoreNow) && scoreNow > 0)
        continue;
    end
    validMask(branchIdx) = true;
    if isempty(coreLen)
        coreLen = numel(coreNow);
    elseif numel(coreNow) ~= coreLen
        error("%s branch lengths are inconsistent.", char(ownerName));
    end
end
if ~any(validMask)
    error("%s produced no valid branch gains.", char(ownerName));
end

usedIdx = find(validMask);
coreMat = complex(zeros(coreLen, numel(usedIdx)));
relMat = zeros(coreLen, numel(usedIdx));
gainUse = complex(zeros(numel(usedIdx), 1));
scoreUse = zeros(numel(usedIdx), 1);
for k = 1:numel(usedIdx)
    branchIdx = usedIdx(k);
    coreMat(:, k) = coreList{branchIdx};
    relMat(:, k) = relList{branchIdx};
    gainUse(k) = gains(branchIdx);
    scoreUse(k) = scoreWeights(branchIdx);
end
powerWeights = abs(gainUse).^2 .* scoreUse;
denom = sum(powerWeights);
if ~(isfinite(denom) && denom > 0)
    error("%s denominator is invalid.", char(ownerName));
end
combineWeights = conj(gainUse) .* scoreUse;
coreOut = (coreMat * combineWeights) / denom;
relOut = (relMat * powerWeights) / denom;
end

function scoreOut = local_sc_fde_gate_branch_scores_local(scoreIn, ownerName)
if nargin < 2 || strlength(string(ownerName)) == 0
    ownerName = "SC-FDE diversity branch gating";
end
scoreIn = double(scoreIn(:));
if isempty(scoreIn)
    error("%s requires a non-empty score vector.", char(ownerName));
end
if any(~isfinite(scoreIn) | scoreIn < 0)
    error("%s scores must be finite and nonnegative.", char(ownerName));
end

[bestScore, bestIdx] = max(scoreIn);
if ~(isfinite(bestScore) && bestScore > 0)
    error("%s requires at least one positive branch score.", char(ownerName));
end

if bestScore < 0.20
    keepMask = false(size(scoreIn));
    keepMask(bestIdx) = true;
else
    keepMask = scoreIn >= 0.85 * bestScore;
    if ~any(keepMask)
        keepMask(bestIdx) = true;
    end
end

scoreOut = zeros(size(scoreIn));
scoreOut(keepMask) = scoreIn(keepMask);
end

function relOut = local_sc_fde_combine_branch_reliability_local(relList, scoreWeights, ownerName)
if nargin < 3 || strlength(string(ownerName)) == 0
    ownerName = "SC-FDE diversity reliability combine";
end
if ~(iscell(relList) && numel(relList) == numel(scoreWeights))
    error("%s requires matched reliability/weight lists.", char(ownerName));
end

scoreWeights = double(scoreWeights(:));
validMask = false(numel(relList), 1);
coreLen = [];
for branchIdx = 1:numel(relList)
    relNow = relList{branchIdx};
    if isempty(relNow)
        error("%s branch %d reliability is empty.", char(ownerName), branchIdx);
    end
    relNow = relNow(:);
    relList{branchIdx} = relNow;
    if ~(isfinite(scoreWeights(branchIdx)) && scoreWeights(branchIdx) > 0)
        continue;
    end
    validMask(branchIdx) = true;
    if isempty(coreLen)
        coreLen = numel(relNow);
    elseif numel(relNow) ~= coreLen
        error("%s branch reliability lengths are inconsistent.", char(ownerName));
    end
end
if ~any(validMask)
    error("%s produced no valid branch weights.", char(ownerName));
end

usedIdx = find(validMask);
relMat = zeros(coreLen, numel(usedIdx));
scoreUse = zeros(numel(usedIdx), 1);
for k = 1:numel(usedIdx)
    branchIdx = usedIdx(k);
    relMat(:, k) = local_fit_reliability_length_local(relList{branchIdx}, coreLen);
    scoreUse(k) = scoreWeights(branchIdx);
end
denom = sum(scoreUse);
if ~(isfinite(denom) && denom > 0)
    error("%s denominator is invalid.", char(ownerName));
end
relOut = (relMat * scoreUse) / denom;
end

function [core, relCore] = local_sc_fde_core_from_physical_hop_local(r, rel, hopIdx, plan)
blockIdx = (hopIdx - 1) * plan.hopLen + (1:plan.hopLen);
if blockIdx(end) > numel(r)
    error("SC-FDE hop %d exceeds received payload length.", hopIdx);
end
block = r(blockIdx);
relBlock = rel(blockIdx);
core = block(plan.cpLen + 1:end);
relCore = relBlock(plan.cpLen + 1:end);
if numel(core) ~= plan.coreLen || numel(relCore) ~= plan.coreLen
    error("SC-FDE core extraction length mismatch.");
end
end

function hopFreqs = local_sc_fde_hop_frequencies_local(hopInfo, nHops)
nHops = max(0, round(double(nHops)));
hopFreqs = zeros(nHops, 1);
if nHops == 0
    return;
end
if ~(isfield(hopInfo, "enable") && logical(hopInfo.enable))
    return;
end
if ~(isfield(hopInfo, "freqOffsets") && ~isempty(hopInfo.freqOffsets))
    error("SC-FDE MMSE requires hopInfo.freqOffsets when FH is enabled.");
end
freqOffsets = double(hopInfo.freqOffsets(:));
if numel(freqOffsets) < nHops
    error("SC-FDE MMSE needs %d hop frequencies, got %d.", nHops, numel(freqOffsets));
end
hopFreqs = freqOffsets(1:nHops);
end

function [xCoreOut, reliability, mse] = local_sc_fde_apply_pilot_scalar_local(xCore, pilot, cfg, maxShift)
xCoreOut = complex(zeros(0, 1));
[~, xCoreNorm, reliability, mse] = local_sc_fde_align_core_to_pilot_local(xCore, pilot, cfg, maxShift);
xCoreOut = xCoreNorm;
end

function [xCoreRawOut, xCoreNormOut, reliability, mse, alphaOut] = local_sc_fde_align_core_to_pilot_local(xCore, pilot, cfg, maxShift)
xCore = xCore(:);
pilot = pilot(:);
if nargin < 4 || isempty(maxShift)
    maxShift = 0;
end
maxShift = max(0, round(double(maxShift)));
if numel(xCore) < numel(pilot)
    error("SC-FDE pilot length exceeds equalized core length.");
end
den = sum(abs(pilot).^2);
if den <= 0
    error("SC-FDE pilot energy is zero.");
end

bestMse = inf;
bestCoreRaw = xCore;
bestCoreNorm = xCore;
bestPilotRx = xCore(1:numel(pilot));
bestAlpha = complex(1, 0);
for shiftNow = -maxShift:maxShift
    cand = circshift(xCore, shiftNow);
    pilotRxNow = cand(1:numel(pilot));
    alpha = sum(conj(pilot) .* pilotRxNow) / den;
    if abs(alpha) >= double(cfg.pilotMinAbsGain)
        candUse = cand ./ alpha;
        pilotUse = pilotRxNow ./ alpha;
    else
        candUse = cand;
        pilotUse = pilotRxNow;
    end
    mseNow = mean(abs(pilotUse - pilot).^2);
    if isfinite(mseNow) && mseNow < bestMse
        bestMse = mseNow;
        bestCoreRaw = cand;
        bestCoreNorm = candUse;
        bestPilotRx = pilotUse;
        bestAlpha = alpha;
    end
end
xCoreRawOut = bestCoreRaw;
xCoreNormOut = bestCoreNorm;
mse = mean(abs(bestPilotRx - pilot).^2);
if ~(isscalar(mse) && isfinite(mse) && mse >= 0)
    error("SC-FDE pilot residual MSE is invalid.");
end
reliability = 1 / (1 + mse / max(double(cfg.pilotMseReference), eps));
reliability = max(double(cfg.minReliability), min(1, reliability));
alphaOut = bestAlpha;
if ~isfinite(alphaOut)
    error("SC-FDE pilot gain estimate is invalid.");
end
end

function tf = local_rx_state_sc_fde_enabled_local(rxState)
tf = isstruct(rxState) && isfield(rxState, "scFdePlan") && isstruct(rxState.scFdePlan) ...
    && isfield(rxState.scFdePlan, "enable") && logical(rxState.scFdePlan.enable);
end

function tf = local_rx_state_sc_fde_diversity_enabled_local(rxState)
tf = isstruct(rxState) && isfield(rxState, "scFdeDiversity") && isstruct(rxState.scFdeDiversity) ...
    && isfield(rxState.scFdeDiversity, "enable") && logical(rxState.scFdeDiversity.enable);
end

function pBlend = local_rx_state_psymbol_blend_local(rxState)
pBlend = 1.0;
if ~(isstruct(rxState) && isfield(rxState, "adaptivePSymbolBlend"))
    return;
end
raw = double(rxState.adaptivePSymbolBlend);
if ~(isscalar(raw) && isfinite(raw))
    return;
end
pBlend = max(min(raw, 1), 0);
end

function divState = local_disabled_sc_fde_diversity_state_local()
divState = struct( ...
    "enable", false, ...
    "nBranches", 0, ...
    "payloadBranches", {cell(0, 1)}, ...
    "reliabilityBranches", {cell(0, 1)}, ...
    "eqBranches", {cell(0, 1)}, ...
    "fallbackEnable", false, ...
    "fallbackBranches", {cell(0, 1)}, ...
    "fallbackReliabilityBranches", {cell(0, 1)});
end

function divState = local_require_sc_fde_diversity_state_local(rxState)
if ~local_rx_state_sc_fde_diversity_enabled_local(rxState)
    error("SC-FDE diversity state is required.");
end
divState = rxState.scFdeDiversity;
requiredFields = ["nBranches", "payloadBranches", "reliabilityBranches", "eqBranches", ...
    "fallbackEnable", "fallbackBranches", "fallbackReliabilityBranches"];
local_require_struct_fields_local(divState, requiredFields, "rxState.scFdeDiversity");
divState.nBranches = round(double(divState.nBranches));
if ~(isscalar(divState.nBranches) && isfinite(divState.nBranches) && divState.nBranches >= 2)
    error("rxState.scFdeDiversity.nBranches must be an integer >= 2.");
end
divState.fallbackEnable = logical(divState.fallbackEnable);
if ~isscalar(divState.fallbackEnable)
    error("rxState.scFdeDiversity.fallbackEnable must be a logical scalar.");
end
end

function tf = local_sc_fde_equalizer_method_local(rxSyncCfg)
tf = false;
if ~(isstruct(rxSyncCfg) && isfield(rxSyncCfg, "multipathEq") && isstruct(rxSyncCfg.multipathEq))
    return;
end
if ~(isfield(rxSyncCfg.multipathEq, "enable") && logical(rxSyncCfg.multipathEq.enable))
    return;
end
if ~(isfield(rxSyncCfg.multipathEq, "compareMethods") && ~isempty(rxSyncCfg.multipathEq.compareMethods))
    return;
end
methods = local_validate_equalizer_compare_methods_local(rxSyncCfg.multipathEq.compareMethods);
tf = any(methods == "sc_fde_mmse");
end

function [rOut, reliability] = local_apply_data_action_local(rIn, actionName, mitigation, hopInfoUsed, fhEnabled, modCfg, pBlend)
r = rIn(:);
actionName = string(actionName);
reliability = ones(numel(r), 1);
if nargin < 7 || isempty(pBlend)
    pBlend = 1.0;
end
pBlend = max(min(double(pBlend), 1), 0);
if actionName == "none"
    rOut = r;
    return;
end

if actionName == "fh_erasure"
    if ~fhEnabled
        error("fh_erasure requires enabled FH hop information.");
    end
    [rOut, reliability] = local_apply_fh_erasure_action_local(r, hopInfoUsed, mitigation, modCfg);
    reliability = (1 - pBlend) * ones(numel(r), 1) + pBlend * reliability;
    return;
end

if actionName == "ml_fh_erasure"
    if ~fhEnabled
        error("ml_fh_erasure requires enabled FH hop information.");
    end
    [rOut, reliability] = local_apply_ml_fh_erasure_action_local(r, hopInfoUsed, mitigation, modCfg);
    reliability = (1 - pBlend) * ones(numel(r), 1) + pBlend * reliability;
    return;
end

if local_action_prefers_per_hop_local(actionName) && fhEnabled ...
        && isstruct(hopInfoUsed) && isfield(hopInfoUsed, "enable") && hopInfoUsed.enable ...
        && isfield(hopInfoUsed, "hopLen") && double(hopInfoUsed.hopLen) > 0
    [rOutMit, reliabilityMit] = local_apply_action_per_hop_local(r, actionName, mitigation, round(double(hopInfoUsed.hopLen)));
    rOut = (1 - pBlend) * r + pBlend * rOutMit;
    reliability = (1 - pBlend) * ones(numel(r), 1) + pBlend * reliabilityMit;
    return;
end

[rOutMit, reliabilityMit] = mitigate_impulses(r, actionName, mitigation);
rOut = (1 - pBlend) * r + pBlend * rOutMit;
reliability = (1 - pBlend) * ones(numel(r), 1) + pBlend * reliabilityMit;
end

function [rOut, reliabilityOut] = local_apply_multipath_fade_erasure_local(rIn, reliabilityIn, rxState, mitigation)
rOut = rIn(:);
reliabilityOut = local_fit_reliability_length_local(reliabilityIn, numel(rOut));
cfg = local_require_fh_erasure_cfg_local(mitigation);
if ~cfg.multipathFadeEnable
    return;
end
if ~(isstruct(rxState) && isfield(rxState, "multipathEqReliability") && ~isempty(rxState.multipathEqReliability))
    return;
end
eqReliability = local_fit_reliability_length_local(rxState.multipathEqReliability, numel(rOut));
reliabilityOut = min(reliabilityOut, eqReliability);
if cfg.attenuateSymbols
    rOut = eqReliability .* rOut;
end
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

function tf = local_action_is_narrowband_local(actionName)
tf = local_action_prefers_per_hop_local(actionName);
end

function preambleOut = local_preamble_for_equalizer_estimation_local(preambleIn, actionName, mitigation)
preambleOut = preambleIn(:);
if isempty(preambleOut)
    return;
end
if ~local_action_is_narrowband_local(actionName)
    return;
end
[preambleOut, ~] = mitigate_impulses(preambleOut, actionName, mitigation);
end

function [rOut, reliability] = local_apply_fh_erasure_action_local(rIn, hopInfoUsed, mitigation, modCfg)
rOut = rIn(:);
N = numel(rOut);
reliability = ones(N, 1);
if N == 0
    return;
end
cfg = local_require_fh_erasure_cfg_local(mitigation);
if ~(isstruct(hopInfoUsed) && isfield(hopInfoUsed, "enable") && hopInfoUsed.enable)
    error("fh_erasure requires hopInfo.enable=true.");
end
if ~(isfield(hopInfoUsed, "hopLen") && double(hopInfoUsed.hopLen) > 0)
    error("fh_erasure requires slow-FH hopInfo.hopLen.");
end
if ~(isfield(hopInfoUsed, "freqIdx") && ~isempty(hopInfoUsed.freqIdx))
    error("fh_erasure requires hopInfo.freqIdx.");
end

hopLen = round(double(hopInfoUsed.hopLen));
nHops = ceil(double(N) / double(hopLen));
freqIdx = round(double(hopInfoUsed.freqIdx(:)));
if numel(freqIdx) < nHops
    error("fh_erasure needs %d hop frequency indices, got %d.", nHops, numel(freqIdx));
end
freqIdx = freqIdx(1:nHops);
if any(~isfinite(freqIdx)) || any(freqIdx < 1)
    error("fh_erasure hopInfo.freqIdx must contain positive finite indices.");
end

nFreqs = max(freqIdx);
if isfield(hopInfoUsed, "nFreqs") && ~isempty(hopInfoUsed.nFreqs)
    nFreqs = max(nFreqs, round(double(hopInfoUsed.nFreqs)));
end
if ~(isscalar(nFreqs) && isfinite(nFreqs) && nFreqs >= 1)
    error("fh_erasure requires a positive finite hopInfo.nFreqs.");
end

hopPower = nan(nHops, 1);
hopConstellationMse = nan(nHops, 1);
for hopIdx = 1:nHops
    idx = local_hop_symbol_indices_local(hopIdx, hopLen, N, cfg.edgeGuardSymbols);
    if isempty(idx)
        idx = local_hop_symbol_indices_local(hopIdx, hopLen, N, 0);
    end
    seg = rOut(idx);
    hopPower(hopIdx) = mean(abs(seg).^2);
    if cfg.constellationMseEnable
        hopConstellationMse(hopIdx) = local_constellation_mse_for_erasure_local(seg, modCfg);
    end
end

validHop = isfinite(hopPower) & hopPower > 0;
if ~any(validHop)
    return;
end
refPower = median(hopPower(validHop));
if ~(isfinite(refPower) && refPower > 0)
    return;
end
validMseHop = isfinite(hopConstellationMse) & hopConstellationMse > 0;
refConstellationMse = NaN;
if any(validMseHop)
    refConstellationMse = median(hopConstellationMse(validMseHop));
end

relHop = ones(nHops, 1);
freqPower = nan(nFreqs, 1);
freqConstellationMse = nan(nFreqs, 1);
for freqNow = 1:nFreqs
    use = validHop & freqIdx == freqNow;
    if any(use)
        freqPower(freqNow) = median(hopPower(use));
    end
    if cfg.constellationMseEnable
        useMse = validMseHop & freqIdx == freqNow;
        if any(useMse)
            freqConstellationMse(freqNow) = median(hopConstellationMse(useMse));
        end
    end
end

freqRatio = freqPower ./ refPower;
candidateFreq = find(isfinite(freqRatio) & freqRatio >= cfg.freqPowerRatioThreshold);
if ~isempty(candidateFreq)
    [~, ord] = sort(freqRatio(candidateFreq), "descend");
    maxErasedFreqs = max(1, ceil(cfg.maxErasedFreqFraction * double(nFreqs)));
    candidateFreq = candidateFreq(ord(1:min(numel(ord), maxErasedFreqs)));
    for k = 1:numel(candidateFreq)
        freqNow = candidateFreq(k);
        freqRel = local_erasure_reliability_from_ratio_local( ...
            freqRatio(freqNow), cfg.freqPowerRatioThreshold, cfg.minReliability, cfg.softSlope);
        relHop(freqIdx == freqNow) = min(relHop(freqIdx == freqNow), freqRel);
    end
end
if cfg.lowPowerFadeEnable
    candidateFreqLow = find(isfinite(freqRatio) & freqRatio <= cfg.lowFreqPowerRatioThreshold);
    if ~isempty(candidateFreqLow)
        [~, ord] = sort(freqRatio(candidateFreqLow), "ascend");
        maxErasedFreqs = max(1, ceil(cfg.maxErasedFreqFraction * double(nFreqs)));
        candidateFreqLow = candidateFreqLow(ord(1:min(numel(ord), maxErasedFreqs)));
        for k = 1:numel(candidateFreqLow)
            freqNow = candidateFreqLow(k);
            freqRel = local_erasure_reliability_from_low_ratio_local( ...
                freqRatio(freqNow), cfg.lowFreqPowerRatioThreshold, cfg.minReliability, cfg.lowPowerSoftSlope);
            relHop(freqIdx == freqNow) = min(relHop(freqIdx == freqNow), freqRel);
        end
    end
end
if cfg.constellationMseEnable && cfg.freqConstellationMseEnable ...
        && isfinite(refConstellationMse) && refConstellationMse > 0
    freqMseRatio = freqConstellationMse ./ refConstellationMse;
    candidateFreqMse = find( ...
        isfinite(freqMseRatio) ...
        & freqMseRatio >= cfg.freqConstellationMseRatioThreshold ...
        & freqConstellationMse >= cfg.freqConstellationMseFloor);
    if ~isempty(candidateFreqMse)
        [~, ord] = sort(freqMseRatio(candidateFreqMse), "descend");
        maxErasedFreqs = max(1, ceil(cfg.maxErasedFreqFraction * double(nFreqs)));
        candidateFreqMse = candidateFreqMse(ord(1:min(numel(ord), maxErasedFreqs)));
        for k = 1:numel(candidateFreqMse)
            freqNow = candidateFreqMse(k);
            freqRel = local_erasure_reliability_from_ratio_local( ...
                freqMseRatio(freqNow), cfg.freqConstellationMseRatioThreshold, cfg.minReliability, cfg.constellationMseSoftSlope);
            relHop(freqIdx == freqNow) = min(relHop(freqIdx == freqNow), freqRel);
        end
    end
end

hopRatio = hopPower ./ refPower;
candidateHop = find(isfinite(hopRatio) & hopRatio >= cfg.hopPowerRatioThreshold);
for k = 1:numel(candidateHop)
    hopNow = candidateHop(k);
    hopRel = local_erasure_reliability_from_ratio_local( ...
        hopRatio(hopNow), cfg.hopPowerRatioThreshold, cfg.minReliability, cfg.softSlope);
    relHop(hopNow) = min(relHop(hopNow), hopRel);
end
if cfg.lowPowerFadeEnable
    candidateHopLow = find(isfinite(hopRatio) & hopRatio <= cfg.lowHopPowerRatioThreshold);
    for k = 1:numel(candidateHopLow)
        hopNow = candidateHopLow(k);
        hopRel = local_erasure_reliability_from_low_ratio_local( ...
            hopRatio(hopNow), cfg.lowHopPowerRatioThreshold, cfg.minReliability, cfg.lowPowerSoftSlope);
        relHop(hopNow) = min(relHop(hopNow), hopRel);
    end
end
if cfg.constellationMseEnable
    candidateHopMse = find(isfinite(hopConstellationMse) & hopConstellationMse >= cfg.constellationMseThreshold);
    for k = 1:numel(candidateHopMse)
        hopNow = candidateHopMse(k);
        hopRel = local_erasure_reliability_from_ratio_local( ...
            hopConstellationMse(hopNow), cfg.constellationMseThreshold, cfg.minReliability, cfg.constellationMseSoftSlope);
        relHop(hopNow) = min(relHop(hopNow), hopRel);
    end
end

for hopIdx = 1:nHops
    startIdx = (hopIdx - 1) * hopLen + 1;
    stopIdx = min(N, hopIdx * hopLen);
    reliability(startIdx:stopIdx) = relHop(hopIdx);
end

if cfg.attenuateSymbols
    rOut = reliability .* rOut;
end
end

function [rOut, reliability] = local_apply_ml_fh_erasure_action_local(rIn, hopInfoUsed, mitigation, modCfg)
rIn = rIn(:);
rOut = rIn;
N = numel(rIn);
reliability = ones(N, 1);
if N == 0
    return;
end
cfg = local_require_fh_erasure_cfg_local(mitigation);
model = local_require_ml_fh_erasure_model_local(mitigation);
[~, ruleReliability] = local_apply_fh_erasure_action_local(rIn, hopInfoUsed, mitigation, modCfg);
if cfg.mlRequirePowerEvidence && all(ruleReliability >= 0.999999)
    reliability = ruleReliability;
    if cfg.attenuateSymbols
        rOut = reliability .* rIn;
    end
    return;
end
[hopFeatureMatrix, featureInfo] = ml_extract_fh_erasure_features(rIn, hopInfoUsed, cfg, modCfg);
[freqFeatureMatrix, freqFeatureInfo] = ml_extract_fh_erasure_freq_features(hopFeatureMatrix, featureInfo);
[~, pBadFreq, ~, ~] = ml_predict_fh_erasure_reliability(freqFeatureMatrix, model, ...
    "minReliability", cfg.minReliability);
relHop = local_ml_erasure_reliability_from_probability_local( ...
    pBadFreq, featureInfo.freqIdx, freqFeatureInfo.nFreqs, cfg);
relHop = double(relHop(:));
if numel(relHop) ~= double(featureInfo.nHops)
    error("ml_fh_erasure predicted %d hop reliabilities, expected %d.", numel(relHop), featureInfo.nHops);
end

hopLen = round(double(featureInfo.hopLen));
mlReliability = ones(N, 1);
for hopIdx = 1:double(featureInfo.nHops)
    startIdx = (hopIdx - 1) * hopLen + 1;
    stopIdx = min(N, hopIdx * hopLen);
    mlReliability(startIdx:stopIdx) = relHop(hopIdx);
end
ruleReliability = local_fit_reliability_length_local(ruleReliability, N);
reliability = min(ruleReliability, mlReliability);
if cfg.attenuateSymbols
    rOut = reliability .* rIn;
end
end

function model = local_require_ml_fh_erasure_model_local(mitigation)
if ~(isfield(mitigation, "mlFhErasure") && isstruct(mitigation.mlFhErasure))
    error("mitigation.mlFhErasure is required for ml_fh_erasure.");
end
model = mitigation.mlFhErasure;
if ~(isfield(model, "trained") && logical(model.trained))
    error("ml_fh_erasure requires a trained FH-erasure model.");
end
end

function idx = local_hop_symbol_indices_local(hopIdx, hopLen, totalLen, edgeGuard)
startIdx = (hopIdx - 1) * hopLen + 1;
stopIdx = min(totalLen, hopIdx * hopLen);
edgeGuard = max(0, round(double(edgeGuard)));
startIdx = min(stopIdx + 1, startIdx + edgeGuard);
stopIdx = max(startIdx - 1, stopIdx - edgeGuard);
idx = (startIdx:stopIdx).';
end

function rel = local_erasure_reliability_from_ratio_local(ratio, threshold, minReliability, softSlope)
ratio = double(ratio);
threshold = double(threshold);
excess = max(ratio - threshold, 0);
rel = 1 ./ (1 + double(softSlope) * excess);
rel = max(double(minReliability), min(1, rel));
end

function rel = local_erasure_reliability_from_low_ratio_local(ratio, threshold, minReliability, softSlope)
ratio = max(double(ratio), eps);
threshold = double(threshold);
deficit = max(threshold ./ ratio - 1, 0);
rel = 1 ./ (1 + double(softSlope) .* deficit);
rel = max(double(minReliability), min(1, rel));
end

function mse = local_constellation_mse_for_erasure_local(seg, modCfg)
seg = seg(:);
if isempty(seg)
    mse = 0;
    return;
end
switch upper(string(modCfg.type))
    case "BPSK"
        dec = sign(real(seg));
        dec(dec == 0) = 1;
        ref = complex(dec, 0);
    case {"QPSK", "MSK"}
        decI = sign(real(seg));
        decQ = sign(imag(seg));
        decI(decI == 0) = 1;
        decQ(decQ == 0) = 1;
        ref = (decI + 1j * decQ) / sqrt(2);
    otherwise
        error("Unsupported modulation for FH-erasure constellation MSE: %s.", char(string(modCfg.type)));
end
mse = mean(abs(seg - ref).^2) / max(mean(abs(seg).^2), eps);
if ~(isscalar(mse) && isfinite(mse))
    mse = 0;
end
end

function rel = local_ml_erasure_reliability_from_probability_local(pBadFreq, freqIdx, nFreqs, cfg)
pBadFreq = double(pBadFreq(:));
freqIdx = round(double(freqIdx(:)));
nFreqs = round(double(nFreqs));
if ~(isscalar(nFreqs) && isfinite(nFreqs) && nFreqs >= 1)
    error("ml_fh_erasure requires a positive finite nFreqs.");
end
if numel(pBadFreq) ~= nFreqs
    error("ml_fh_erasure predicted %d frequency probabilities, expected %d.", numel(pBadFreq), nFreqs);
end
if any(~isfinite(freqIdx) | freqIdx < 1 | freqIdx > nFreqs)
    error("ml_fh_erasure freqIdx must be within [1, nFreqs].");
end

rel = ones(size(freqIdx));
freqProb = pBadFreq(:);

candidateFreq = find(isfinite(freqProb) & freqProb >= cfg.mlFreqProbabilityThreshold);
if ~isempty(candidateFreq)
    [~, ord] = sort(freqProb(candidateFreq), "descend");
    maxErasedFreqs = max(1, ceil(cfg.mlMaxErasedFreqFraction * double(nFreqs)));
    candidateFreq = candidateFreq(ord(1:min(numel(ord), maxErasedFreqs)));
    for k = 1:numel(candidateFreq)
        freqNow = candidateFreq(k);
        freqRel = local_probability_erasure_reliability_local( ...
            freqProb(freqNow), cfg.mlFreqProbabilityThreshold, cfg.minReliability, cfg.mlProbabilitySlope);
        rel(freqIdx == freqNow) = min(rel(freqIdx == freqNow), freqRel);
    end
end
rel = max(cfg.minReliability, min(1, rel));
end

function rel = local_probability_erasure_reliability_local(probability, threshold, minReliability, slope)
probability = double(probability);
excess = max(probability - double(threshold), 0);
rel = 1 ./ (1 + double(slope) .* excess);
rel = max(double(minReliability), min(1, rel));
end

function cfg = local_require_fh_erasure_cfg_local(mitigation)
if ~(isfield(mitigation, "fhErasure") && isstruct(mitigation.fhErasure))
    error("mitigation.fhErasure is required for fh_erasure.");
end
raw = mitigation.fhErasure;
cfg = struct();
cfg.freqPowerRatioThreshold = local_required_positive_scalar_local(raw, "freqPowerRatioThreshold", "mitigation.fhErasure");
cfg.hopPowerRatioThreshold = local_required_positive_scalar_local(raw, "hopPowerRatioThreshold", "mitigation.fhErasure");
cfg.minReliability = local_required_probability_scalar_local(raw, "minReliability", "mitigation.fhErasure");
cfg.softSlope = local_required_positive_scalar_local(raw, "softSlope", "mitigation.fhErasure");
cfg.maxErasedFreqFraction = local_required_probability_scalar_local(raw, "maxErasedFreqFraction", "mitigation.fhErasure");
cfg.edgeGuardSymbols = local_required_nonnegative_scalar_local(raw, "edgeGuardSymbols", "mitigation.fhErasure");
cfg.attenuateSymbols = local_required_logical_scalar_local(raw, "attenuateSymbols", "mitigation.fhErasure");
cfg.lowPowerFadeEnable = local_required_logical_scalar_local(raw, "lowPowerFadeEnable", "mitigation.fhErasure");
cfg.lowFreqPowerRatioThreshold = local_required_probability_scalar_local(raw, "lowFreqPowerRatioThreshold", "mitigation.fhErasure");
cfg.lowHopPowerRatioThreshold = local_required_probability_scalar_local(raw, "lowHopPowerRatioThreshold", "mitigation.fhErasure");
cfg.lowPowerSoftSlope = local_required_positive_scalar_local(raw, "lowPowerSoftSlope", "mitigation.fhErasure");
cfg.constellationMseEnable = local_required_logical_scalar_local(raw, "constellationMseEnable", "mitigation.fhErasure");
cfg.constellationMseThreshold = local_required_positive_scalar_local(raw, "constellationMseThreshold", "mitigation.fhErasure");
cfg.constellationMseSoftSlope = local_required_positive_scalar_local(raw, "constellationMseSoftSlope", "mitigation.fhErasure");
cfg.freqConstellationMseEnable = local_required_logical_scalar_local(raw, "freqConstellationMseEnable", "mitigation.fhErasure");
cfg.freqConstellationMseRatioThreshold = local_required_positive_scalar_local(raw, "freqConstellationMseRatioThreshold", "mitigation.fhErasure");
cfg.freqConstellationMseFloor = local_required_nonnegative_scalar_local(raw, "freqConstellationMseFloor", "mitigation.fhErasure");
cfg.mlFreqProbabilityThreshold = local_required_probability_scalar_local(raw, "mlFreqProbabilityThreshold", "mitigation.fhErasure");
if cfg.mlFreqProbabilityThreshold >= 1
    error("mitigation.fhErasure.mlFreqProbabilityThreshold must be < 1.");
end
cfg.mlMaxErasedFreqFraction = local_required_probability_scalar_local(raw, "mlMaxErasedFreqFraction", "mitigation.fhErasure");
if cfg.mlMaxErasedFreqFraction <= 0
    error("mitigation.fhErasure.mlMaxErasedFreqFraction must be > 0.");
end
cfg.mlProbabilitySlope = local_required_positive_scalar_local(raw, "mlProbabilitySlope", "mitigation.fhErasure");
cfg.mlRequirePowerEvidence = local_required_logical_scalar_local(raw, "mlRequirePowerEvidence", "mitigation.fhErasure");
cfg.multipathFadeEnable = local_required_logical_scalar_local(raw, "multipathFadeEnable", "mitigation.fhErasure");
cfg.multipathNoiseGainRatioThreshold = local_required_positive_scalar_local(raw, "multipathNoiseGainRatioThreshold", "mitigation.fhErasure");
cfg.multipathSinrDropDbThreshold = local_required_nonnegative_scalar_local(raw, "multipathSinrDropDbThreshold", "mitigation.fhErasure");
cfg.multipathSoftSlope = local_required_positive_scalar_local(raw, "multipathSoftSlope", "mitigation.fhErasure");
if cfg.freqPowerRatioThreshold < 1 || cfg.hopPowerRatioThreshold < 1
    error("mitigation.fhErasure power-ratio thresholds must be >= 1.");
end
if cfg.lowPowerFadeEnable && (cfg.lowFreqPowerRatioThreshold <= 0 || cfg.lowHopPowerRatioThreshold <= 0)
    error("mitigation.fhErasure low-power thresholds must be in (0, 1].");
end
if cfg.multipathNoiseGainRatioThreshold < 1
    error("mitigation.fhErasure.multipathNoiseGainRatioThreshold must be >= 1.");
end
end

function value = local_required_positive_scalar_local(cfg, fieldName, label)
value = local_required_numeric_scalar_local(cfg, fieldName, label);
if value <= 0
    error("%s.%s must be positive.", label, fieldName);
end
end

function value = local_required_nonnegative_scalar_local(cfg, fieldName, label)
value = local_required_numeric_scalar_local(cfg, fieldName, label);
if value < 0
    error("%s.%s must be nonnegative.", label, fieldName);
end
end

function value = local_required_probability_scalar_local(cfg, fieldName, label)
value = local_required_numeric_scalar_local(cfg, fieldName, label);
if value < 0 || value > 1
    error("%s.%s must be in [0, 1].", label, fieldName);
end
end

function value = local_required_numeric_scalar_local(cfg, fieldName, label)
if ~(isfield(cfg, fieldName) && ~isempty(cfg.(fieldName)))
    error("%s.%s is required.", label, fieldName);
end
value = double(cfg.(fieldName));
if ~(isscalar(value) && isfinite(value))
    error("%s.%s must be a finite scalar.", label, fieldName);
end
end

function value = local_required_logical_scalar_local(cfg, fieldName, label)
if ~(isfield(cfg, fieldName) && ~isempty(cfg.(fieldName)))
    error("%s.%s is required.", label, fieldName);
end
value = cfg.(fieldName);
if ~(islogical(value) || isnumeric(value))
    error("%s.%s must be a logical scalar.", label, fieldName);
end
value = logical(value);
if ~isscalar(value)
    error("%s.%s must be a logical scalar.", label, fieldName);
end
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

function front = local_capture_synced_block_local(rxSampleRaw, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg, rxDiversityCfg)
if nargin < 9
    bootstrapChain = strings(1, 0);
end
if nargin < 10 || isempty(fhCaptureCfg)
    fhCaptureCfg = struct("enable", false);
end
if nargin < 11 || isempty(rxDiversityCfg)
    rxDiversityCfg = local_disabled_rx_diversity_cfg_local();
end

branchSamples = local_rx_capture_branch_list_local(rxSampleRaw);
if numel(branchSamples) == 1
    cfgSingle = local_validate_rx_diversity_cfg_local(rxDiversityCfg, "rxDiversity");
    if cfgSingle.enable
        error("RX diversity capture requires multiple branches when rxDiversity.enable=true.");
    end
    front = capture_synced_block_from_samples( ...
        branchSamples{1}, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg);
    branchFront = front;
    front.branchFronts = {branchFront};
    front.branchOkMask = true;
    front.branchCombineWeights = complex(1, 0);
    front.branchPowerWeights = 1;
    return;
end

front = local_capture_synced_block_diversity_local( ...
    branchSamples, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg, rxDiversityCfg);
end

function front = local_capture_synced_block_diversity_local(branchSamples, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg, rxDiversityCfg)
cfg = local_validate_rx_diversity_cfg_local(rxDiversityCfg, "rxDiversity");
if ~cfg.enable
    error("Multi-branch capture requires rxDiversity.enable=true.");
end
if numel(branchSamples) ~= double(cfg.nRx)
    error("RX diversity capture expects %d branches, got %d.", double(cfg.nRx), numel(branchSamples));
end

fronts = cell(numel(branchSamples), 1);
okMask = false(numel(branchSamples), 1);
for branchIdx = 1:numel(branchSamples)
    fronts{branchIdx} = capture_synced_block_from_samples( ...
        branchSamples{branchIdx}, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg, waveform, sampleAction, bootstrapChain, fhCaptureCfg);
    okMask(branchIdx) = fronts{branchIdx}.ok;
end
if ~any(okMask)
    front = fronts{1};
    front.branchFronts = fronts;
    front.branchOkMask = okMask;
    front.branchCombineWeights = complex(zeros(numel(fronts), 1));
    front.branchPowerWeights = zeros(numel(fronts), 1);
    return;
end

usedIdx = find(okMask);
combineWeights = complex(zeros(numel(usedIdx), 1));
powerWeights = zeros(numel(usedIdx), 1);
for k = 1:numel(usedIdx)
    [combineWeights(k), powerWeights(k)] = local_diversity_branch_combine_weights_local( ...
        syncSymRef, fronts{usedIdx(k)}, syncCfgUse);
end
if any(~isfinite(powerWeights)) || any(powerWeights <= 0)
    error("RX diversity combining produced invalid branch power weights.");
end

rMat = complex(zeros(totalLen, numel(usedIdx)));
relMat = zeros(totalLen, numel(usedIdx));
for k = 1:numel(usedIdx)
    frontNow = fronts{usedIdx(k)};
    rMat(:, k) = fit_complex_length_local(frontNow.rFull, totalLen);
    relMat(:, k) = local_fit_reliability_length_local(frontNow.reliabilityFull, totalLen);
end

switch cfg.combineMethod
    case "mrc"
        denom = sum(powerWeights);
        if ~(isfinite(denom) && denom > 0)
            error("RX diversity MRC denominator is invalid.");
        end
        rComb = (rMat * combineWeights) / denom;
        relComb = (relMat * powerWeights) / denom;
    otherwise
        error("Unsupported rxDiversity.combineMethod: %s.", char(cfg.combineMethod));
end

[~, refLocalIdx] = max(powerWeights);
front = fronts{usedIdx(refLocalIdx)};
front.ok = true;
front.rFull = rComb;
front.reliabilityFull = local_fit_reliability_length_local(relComb, totalLen);
branchCombineWeights = complex(zeros(numel(fronts), 1));
branchPowerWeights = zeros(numel(fronts), 1);
branchCombineWeights(usedIdx) = combineWeights;
branchPowerWeights(usedIdx) = powerWeights;
front.branchFronts = fronts;
front.branchOkMask = okMask;
front.branchCombineWeights = branchCombineWeights;
front.branchPowerWeights = branchPowerWeights;
end

function [combineWeight, powerWeight] = local_diversity_branch_combine_weights_local(syncSymRef, front, syncCfgUse)
combineWeight = complex(NaN, NaN);
powerWeight = NaN;

if ~(isstruct(front) && isfield(front, "syncInfo") && isstruct(front.syncInfo))
    error("RX diversity branch is missing syncInfo for combining.");
end

gainRaw = complex(NaN, NaN);
if isfield(front.syncInfo, "chanGainEstimate") && ~isempty(front.syncInfo.chanGainEstimate)
    gainRaw = front.syncInfo.chanGainEstimate;
end
gainRawValid = isfinite(gainRaw) && abs(gainRaw) > 1e-12;

compApplied = false;
if isfield(front.syncInfo, "compensated") && ~isempty(front.syncInfo.compensated)
    compApplied = logical(front.syncInfo.compensated);
    if ~isscalar(compApplied)
        error("RX diversity branch syncInfo.compensated must be a logical scalar.");
    end
end

equalizeAmplitude = true;
if isstruct(syncCfgUse) && isfield(syncCfgUse, "equalizeAmplitude") && ~isempty(syncCfgUse.equalizeAmplitude)
    equalizeAmplitude = logical(syncCfgUse.equalizeAmplitude);
    if ~isscalar(equalizeAmplitude)
        error("rxSync.equalizeAmplitude must be a logical scalar.");
    end
end

if compApplied && gainRawValid
    gainMag = abs(gainRaw);
    powerWeight = gainMag ^ 2;
    if equalizeAmplitude
        % capture_synced_block_from_samples has already divided by hHat,
        % so each branch is phase/amplitude normalized and should be combined
        % with post-equalization MRC power weights.
        combineWeight = complex(powerWeight, 0);
    else
        % Only phase was removed, so the residual branch amplitude is |hHat|.
        combineWeight = complex(gainMag, 0);
    end
    return;
end

gainRaw = local_estimate_diversity_branch_gain_local(syncSymRef, front);
powerWeight = abs(gainRaw) ^ 2;
combineWeight = conj(gainRaw);
end

function gain = local_estimate_diversity_branch_gain_local(syncSymRef, front)
syncSymRef = syncSymRef(:);
if ~(isstruct(front) && isfield(front, "rFull") && numel(front.rFull) >= numel(syncSymRef))
    error("RX diversity branch is missing a valid synchronized preamble.");
end
den = sum(abs(syncSymRef).^2);
if ~(isfinite(den) && den > 0)
    error("RX diversity reference preamble energy is invalid.");
end
preambleRx = front.rFull(1:numel(syncSymRef));
gain = sum(conj(syncSymRef) .* preambleRx) / den;
if ~isfinite(gain)
    error("RX diversity branch gain estimate is invalid.");
end
end

function branches = local_rx_capture_branch_list_local(rxCapture)
if iscell(rxCapture)
    branches = rxCapture(:);
else
    branches = {rxCapture(:)};
end
for k = 1:numel(branches)
    if isempty(branches{k})
        error("RX capture branch %d is empty.", k);
    end
    branches{k} = branches{k}(:);
end
end

function fhCaptureCfg = local_packet_sample_fh_capture_cfg_local(txPacket, fhAssumption)
fhCaptureCfg = struct("enable", false);
if nargin < 2 || strlength(string(fhAssumption)) == 0
    fhAssumption = "known";
end

preambleFhCfg = struct("enable", false);
if isfield(txPacket, "preambleFhCfg") && isstruct(txPacket.preambleFhCfg)
    preambleFhCfg = local_assumed_packet_fh_cfg_local(txPacket.preambleFhCfg, fhAssumption);
end

headerFhCfg = struct("enable", false);
if isfield(txPacket, "phyHeaderFhCfg") && isstruct(txPacket.phyHeaderFhCfg)
    headerFhCfg = local_assumed_packet_fh_cfg_local(txPacket.phyHeaderFhCfg, fhAssumption);
end

dataFhCfg = struct("enable", false);
if isfield(txPacket, "fhCfg") && isstruct(txPacket.fhCfg)
    dataFhCfg = local_assumed_packet_fh_cfg_local(txPacket.fhCfg, fhAssumption);
end

preambleEnabled = isfield(preambleFhCfg, "enable") && preambleFhCfg.enable;
headerEnabled = isfield(headerFhCfg, "enable") && headerFhCfg.enable;
dataEnabled = isfield(dataFhCfg, "enable") && dataFhCfg.enable;
if ~(preambleEnabled || headerEnabled || dataEnabled)
    return;
end

fhCaptureCfg = struct( ...
    "enable", true, ...
    "syncSymbols", double(numel(txPacket.syncSym)), ...
    "headerSymbols", double(numel(txPacket.phyHeaderSymTx)), ...
    "preambleFhCfg", preambleFhCfg, ...
    "headerFhCfg", headerFhCfg, ...
    "dataFhCfg", dataFhCfg);
end

function fhCaptureCfg = local_session_sample_fh_capture_cfg_local(sessionFrame, fhAssumption)
fhCaptureCfg = struct("enable", false);
if nargin < 2 || strlength(string(fhAssumption)) == 0
    fhAssumption = "known";
end

preambleFhCfg = struct("enable", false);
if isfield(sessionFrame, "preambleFhCfg") && isstruct(sessionFrame.preambleFhCfg)
    preambleFhCfg = local_assumed_packet_fh_cfg_local(sessionFrame.preambleFhCfg, fhAssumption);
end

dataFhCfg = struct("enable", false);
if isfield(sessionFrame, "fhCfg") && isstruct(sessionFrame.fhCfg)
    dataFhCfg = local_assumed_packet_fh_cfg_local(sessionFrame.fhCfg, fhAssumption);
end

preambleEnabled = isfield(preambleFhCfg, "enable") && preambleFhCfg.enable;
dataEnabled = isfield(dataFhCfg, "enable") && dataFhCfg.enable;
if ~(preambleEnabled || dataEnabled)
    return;
end

fhCaptureCfg = struct( ...
    "enable", true, ...
    "syncSymbols", double(numel(sessionFrame.syncSym)), ...
    "headerSymbols", 0, ...
    "preambleFhCfg", preambleFhCfg, ...
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

function [rFull, reliabilityFull, ok] = local_extract_sample_fh_symbol_block_local( ...
    rxPrep, relSamplePrep, startIdx, totalLen, fhCaptureCfg, syncCfgUse, modCfg, waveform, syncStageSps)
rFull = complex(zeros(0, 1));
reliabilityFull = zeros(0, 1);
ok = false;

if ~(isstruct(waveform) && isfield(waveform, "enable") && waveform.enable)
    error("Sample-domain FH capture requires waveform.enable=true.");
end
if ~(isfield(waveform, "sps") && double(waveform.sps) >= 2)
    error("Sample-domain FH capture requires waveform.sps>=2.");
end

decim = round(double(waveform.sps) / double(syncStageSps));
packetStartSample = 1 + (double(startIdx) - 1) * decim;
packetSampleLen = local_packet_sample_length_local(totalLen, waveform);

[pktSample, okPkt, extractInfo] = extract_fractional_block( ...
    rxPrep, packetStartSample, packetSampleLen, local_symbol_extract_sync_cfg_local(syncCfgUse), modCfg, 1);
if ~okPkt
    return;
end

relPkt = local_extract_reliability_from_sample_times_local(relSamplePrep, extractInfo.sampleTimes);
pktSample = local_apply_fast_fh_packet_demod_local(pktSample, fhCaptureCfg, waveform);
pktMf = local_matched_filter_samples_local(pktSample, waveform);
relMf = local_matched_filter_reliability_samples_local(relPkt, waveform);
[rFull, reliabilityFull] = local_decimate_stage_branch_local(pktMf, relMf, waveform, 1);
rFull = fit_complex_length_local(rFull, totalLen);
reliabilityFull = local_fit_reliability_length_local(reliabilityFull, totalLen);
ok = numel(rFull) == totalLen && any(abs(rFull) > 0);
end

function pktOut = local_apply_fast_fh_packet_demod_local(pktIn, fhCaptureCfg, waveform)
pktOut = pktIn(:);
syncSymbols = local_fast_fh_capture_scalar_local(fhCaptureCfg, "syncSymbols");
headerSymbols = local_fast_fh_capture_scalar_local(fhCaptureCfg, "headerSymbols");
headerStart = local_symbol_boundary_sample_index_local(syncSymbols, waveform);
dataStart = local_symbol_boundary_sample_index_local(syncSymbols + headerSymbols, waveform);

if isfield(fhCaptureCfg, "headerFhCfg") && isstruct(fhCaptureCfg.headerFhCfg) ...
        && isfield(fhCaptureCfg.headerFhCfg, "enable") && fhCaptureCfg.headerFhCfg.enable
    headerStop = min(numel(pktOut), dataStart - 1);
    if headerStart <= headerStop
        pktOut(headerStart:headerStop) = local_fast_fh_segment_demod_local( ...
            pktOut(headerStart:headerStop), fhCaptureCfg.headerFhCfg, waveform);
    end
end

if isfield(fhCaptureCfg, "dataFhCfg") && isstruct(fhCaptureCfg.dataFhCfg) ...
        && isfield(fhCaptureCfg.dataFhCfg, "enable") && fhCaptureCfg.dataFhCfg.enable
    dataStart = min(max(1, dataStart), numel(pktOut) + 1);
    if dataStart <= numel(pktOut)
        pktOut(dataStart:end) = local_fast_fh_segment_demod_local( ...
            pktOut(dataStart:end), fhCaptureCfg.dataFhCfg, waveform);
    end
end
end

function segOut = local_fast_fh_segment_demod_local(segIn, fhCfg, waveform)
hopInfo = fh_sample_hop_info_from_cfg(fhCfg, waveform, numel(segIn));
segOut = fh_demodulate_samples(segIn, hopInfo, waveform);
end

function value = local_fast_fh_capture_scalar_local(fhCaptureCfg, fieldName)
if ~(isfield(fhCaptureCfg, fieldName) && ~isempty(fhCaptureCfg.(fieldName)))
    error("fhCaptureCfg.%s is required for sample-domain FH capture.", fieldName);
end
value = round(double(fhCaptureCfg.(fieldName)));
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("fhCaptureCfg.%s must be a nonnegative finite scalar.", fieldName);
end
end

function nSample = local_packet_sample_length_local(nSym, waveform)
nSym = max(0, round(double(nSym)));
if ~waveform.enable
    nSample = nSym;
    return;
end
nSample = (nSym - 1) * round(double(waveform.sps)) + numel(waveform.rrcTaps);
end

function sampleIdx = local_symbol_boundary_sample_index_local(nLeadingSym, waveform)
nLeadingSym = max(0, round(double(nLeadingSym)));
sampleIdx = nLeadingSym * round(double(waveform.sps)) + 1;
end

function [decision, committedFront] = local_select_frontend_action_local(methodName, adaptiveEnabled, initialFront, syncSymRef, mitigation, channelCfg, waveform, N0, captureFn)
featureCount = numel(ml_interference_selector_feature_names());
decision = struct( ...
    "selectedClass", "", ...
    "selectedAction", "", ...
    "sampleAction", "none", ...
    "symbolAction", "none", ...
    "confidence", NaN, ...
    "classProbabilities", zeros(0, 1), ...
    "featureRow", zeros(1, featureCount), ...
    "bootstrapPath", string(initialFront.bootstrapPath), ...
    "pSample", 0, ...
    "pSymbol", 0, ...
    "sampleEvmScores", struct("candidates", strings(0, 1), "scores", zeros(0, 1)), ...
    "evmScores", struct("candidates", strings(0, 1), "scores", zeros(0, 1)));
committedFront = initialFront;

methodName = string(methodName);
if ~(local_is_adaptive_frontend_method_local(methodName) && logical(adaptiveEnabled))
    decision.selectedAction = local_effective_presync_method_name_local(methodName, adaptiveEnabled);
    [decision.sampleAction, decision.symbolAction] = local_split_mitigation_action_local(decision.selectedAction);
    return;
end

selectorModel = local_require_selector_model_local(mitigation);
captureDiag = struct("ok", true, "rFull", initialFront.rFull(:), "syncInfo", initialFront.syncInfo);
channelLenSymbols = local_multipath_channel_len_symbols_local(channelCfg, waveform);
[featureRow, ~] = adaptive_frontend_extract_features(captureDiag, syncSymRef, N0, ...
    "channelLenSymbols", channelLenSymbols);
[classProbabilities, classNames] = ml_predict_interference_presence(featureRow, selectorModel);

cfg = local_require_adaptive_frontend_cfg_local(mitigation);
stagesCfg = local_require_adaptive_stages_cfg_local(cfg);

[sampleAction, pSample, sampleEvmScores, committedFront] = local_select_sample_stage_with_evm_local( ...
    stagesCfg.sample, classProbabilities, classNames, initialFront, syncSymRef, captureFn);
if ~(isstruct(committedFront) && isfield(committedFront, "ok") && committedFront.ok)
    return;
end

[symbolAction, pSymbol, evmScores] = local_select_symbol_stage_local( ...
    stagesCfg.symbol, classProbabilities, classNames, committedFront.rFull, syncSymRef, mitigation);

routeLabel = local_compose_adaptive_action_label_local(sampleAction, symbolAction);
presenceLabel = local_compose_presence_label_local(classProbabilities, classNames);
dominantProb = max([pSample, pSymbol, 0]);

decision.selectedClass = presenceLabel;
decision.selectedAction = routeLabel;
decision.sampleAction = sampleAction;
decision.symbolAction = symbolAction;
decision.confidence = double(dominantProb);
decision.classProbabilities = classProbabilities;
decision.featureRow = featureRow;
decision.bootstrapPath = string(committedFront.bootstrapPath);
decision.pSample = double(pSample);
decision.pSymbol = double(pSymbol);
decision.sampleEvmScores = sampleEvmScores;
decision.evmScores = evmScores;
end

function [sampleAction, pSample, evmScores, committedFront] = local_select_sample_stage_with_evm_local( ...
    stageCfg, classProbabilities, classNames, initialFront, syncSymRef, captureFn)
sampleAction = "none";
evmScores = struct("candidates", strings(0, 1), "scores", zeros(0, 1));
committedFront = initialFront;
pSample = local_aggregate_evidence_probability_local(stageCfg, classProbabilities, classNames);
if pSample < double(stageCfg.enableThreshold)
    return;
end

[orderedCandidates, ~] = local_order_stage_candidates_local(stageCfg, classProbabilities, classNames, "sample");
if isempty(orderedCandidates)
    return;
end

topK = max(1, round(double(local_stage_cfg_scalar_local(stageCfg, "evmTopK", 2))));
topK = min(topK, numel(orderedCandidates));
picks = orderedCandidates(1:topK);
% "none" baseline is free — it reuses the initial capture.
if ~any(picks == "none")
    picks(end+1, 1) = "none"; %#ok<AGROW>
end

syncSymRef = syncSymRef(:);
fronts = cell(numel(picks), 1);
scores = inf(numel(picks), 1);
for k = 1:numel(picks)
    candidate = picks(k);
    if candidate == "none"
        fronts{k} = initialFront;
    elseif isa(captureFn, "function_handle")
        fronts{k} = captureFn(candidate);
    else
        fronts{k} = struct("ok", false);
    end
    frontNow = fronts{k};
    if isstruct(frontNow) && isfield(frontNow, "ok") && frontNow.ok ...
            && isfield(frontNow, "rFull") && ~isempty(frontNow.rFull)
        rSample = frontNow.rFull;
        nSync = min(numel(syncSymRef), numel(rSample));
        scores(k) = local_score_sync_evm_local(rSample, syncSymRef, nSync);
    end
end

if ~any(isfinite(scores))
    return;
end
[~, bestIdx] = min(scores);
sampleAction = picks(bestIdx);
committedFront = fronts{bestIdx};
evmScores = struct("candidates", picks, "scores", scores);
end

function [symbolAction, pSymbol, evmScores] = local_select_symbol_stage_local(stageCfg, classProbabilities, classNames, rFull, syncSymRef, mitigation)
symbolAction = "none";
evmScores = struct("candidates", strings(0, 1), "scores", zeros(0, 1));
pSymbol = local_aggregate_evidence_probability_local(stageCfg, classProbabilities, classNames);
if pSymbol < double(stageCfg.enableThreshold)
    return;
end

[orderedCandidates, ~] = local_order_stage_candidates_local(stageCfg, classProbabilities, classNames, "symbol");
if isempty(orderedCandidates)
    return;
end

topK = max(1, round(double(local_stage_cfg_scalar_local(stageCfg, "evmTopK", 2))));
topK = min(topK, numel(orderedCandidates));
picks = orderedCandidates(1:topK);
% Always include "none" as a baseline — if the raw signal already has lower
% EVM than any mitigated candidate, the stage should back off. Without this,
% the stage commits to some action whenever the gate fires, even when doing
% nothing would have been strictly better.
if ~any(picks == "none")
    picks(end+1, 1) = "none"; %#ok<AGROW>
end

rFull = rFull(:);
syncSymRef = syncSymRef(:);
nSync = min(numel(syncSymRef), numel(rFull));
scores = inf(numel(picks), 1);
for k = 1:numel(picks)
    candidate = picks(k);
    rCandidate = local_score_candidate_symbol_action_local(rFull, candidate, mitigation);
    scores(k) = local_score_sync_evm_local(rCandidate, syncSymRef, nSync);
end

[~, bestIdx] = min(scores);
symbolAction = picks(bestIdx);
evmScores = struct("candidates", picks, "scores", scores);
end

function rOut = local_score_candidate_symbol_action_local(rIn, actionName, mitigation)
rIn = rIn(:);
switch lower(string(actionName))
    case "none"
        rOut = rIn;
    case {"fh_erasure", "ml_fh_erasure"}
        % FH-aware actions need hop info that is not available at scoring
        % time; fall back to the raw signal so EVM reflects the baseline.
        % Downstream execution still uses the full FH-aware pipeline.
        rOut = rIn;
    otherwise
        [rOut, ~] = mitigate_impulses(rIn, actionName, mitigation);
end
rOut = rOut(:);
end

function evm = local_score_sync_evm_local(r, syncSymRef, nSync)
r = r(:);
syncSymRef = syncSymRef(:);
nSync = round(double(nSync));
if nSync <= 0 || numel(r) < nSync || numel(syncSymRef) < nSync
    evm = inf;
    return;
end
refSeg = syncSymRef(1:nSync);
rxSeg = r(1:nSync);
refPower = sum(abs(refSeg).^2);
if ~(isfinite(refPower) && refPower > 0)
    evm = inf;
    return;
end
denom = sum(refSeg .* conj(refSeg));
if abs(denom) <= 1e-12
    evm = inf;
    return;
end
hHat = sum(rxSeg .* conj(refSeg)) / denom;
if ~isfinite(hHat) || abs(hHat) <= 1e-12
    evm = inf;
    return;
end
err = rxSeg ./ hHat - refSeg;
evm = sqrt(sum(abs(err).^2) / refPower);
if ~isfinite(evm)
    evm = inf;
end
end

function pEvidence = local_aggregate_evidence_probability_local(stageCfg, classProbabilities, classNames)
evidence = string(stageCfg.evidenceClasses(:).');
if isempty(evidence)
    pEvidence = 0;
    return;
end
pEvidence = 0;
for k = 1:numel(evidence)
    idx = find(classNames == evidence(k), 1, "first");
    if isempty(idx)
        continue;
    end
    pEvidence = max(pEvidence, classProbabilities(idx));
end
end

function [orderedCandidates, orderedProbs] = local_order_stage_candidates_local(stageCfg, classProbabilities, classNames, layerName)
candidates = string(stageCfg.candidates(:).');
candidateClasses = string(stageCfg.candidateClasses(:).');
if numel(candidates) ~= numel(candidateClasses)
    error("mitigation.adaptiveFrontend.stages.%s.candidates and candidateClasses must have equal length.", char(layerName));
end
if isempty(candidates)
    orderedCandidates = strings(0, 1);
    orderedProbs = zeros(0, 1);
    return;
end

probs = zeros(numel(candidates), 1);
for k = 1:numel(candidates)
    idx = find(classNames == candidateClasses(k), 1, "first");
    if isempty(idx)
        error("mitigation.adaptiveFrontend.stages.%s candidateClass %s is not registered.", ...
            char(layerName), char(candidateClasses(k)));
    end
    probs(k) = classProbabilities(idx);
    if candidates(k) == "none"
        probs(k) = -inf;
    end
end
[orderedProbs, order] = sort(probs, "descend");
orderedCandidates = candidates(order);
keep = orderedProbs > -inf;
orderedCandidates = orderedCandidates(keep);
orderedProbs = orderedProbs(keep);
orderedCandidates = orderedCandidates(:);
orderedProbs = orderedProbs(:);
end

function value = local_stage_cfg_scalar_local(stageCfg, fieldName, defaultValue)
value = double(defaultValue);
if isfield(stageCfg, fieldName) && ~isempty(stageCfg.(fieldName))
    value = double(stageCfg.(fieldName));
end
if ~(isscalar(value) && isfinite(value))
    error("stages.%s must be a finite scalar.", char(fieldName));
end
end

function stagesCfg = local_require_adaptive_stages_cfg_local(cfg)
if ~(isstruct(cfg) && isfield(cfg, "stages") && isstruct(cfg.stages))
    error("mitigation.adaptiveFrontend.stages is required.");
end
stagesCfg = cfg.stages;
for layer = ["sample" "symbol"]
    if ~(isfield(stagesCfg, layer) && isstruct(stagesCfg.(layer)))
        error("mitigation.adaptiveFrontend.stages.%s is required.", char(layer));
    end
    layerCfg = stagesCfg.(layer);
    requiredFields = ["evidenceClasses", "candidates", "candidateClasses", "enableThreshold"];
    for k = 1:numel(requiredFields)
        if ~isfield(layerCfg, requiredFields(k))
            error("mitigation.adaptiveFrontend.stages.%s.%s is required.", ...
                char(layer), char(requiredFields(k)));
        end
    end
end
end

function label = local_compose_presence_label_local(classProbabilities, classNames)
classProbabilities = double(classProbabilities(:));
classNames = string(classNames(:));
if isempty(classProbabilities) || isempty(classNames)
    label = "";
    return;
end
[~, idx] = max(classProbabilities);
label = classNames(idx);
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
symbolActions = ["fh_erasure" "ml_fh_erasure" "fft_notch" "fft_bandstop" "adaptive_notch" "stft_notch" "ml_narrowband"];
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
cfg = local_require_adaptive_frontend_cfg_local(mitigation);
if ~(isfield(cfg, "classNames") && ~isempty(cfg.classNames))
    error("mitigation.adaptiveFrontend.classNames is required for adaptive_ml_frontend.");
end
if ~(isfield(model, "classNames") && ~isempty(model.classNames))
    error("adaptive_ml_frontend selector model must provide classNames.");
end
modelClasses = string(model.classNames(:).');
cfgClasses = string(cfg.classNames(:).');
if ~isequal(modelClasses, cfgClasses)
    error("adaptive_ml_frontend selector classNames must match mitigation.adaptiveFrontend.classNames.");
end
end

function routeLabel = local_compose_adaptive_action_label_local(sampleAction, symbolAction)
sampleAction = lower(string(sampleAction));
symbolAction = lower(string(symbolAction));
if sampleAction == "none" && symbolAction == "none"
    routeLabel = "none";
    return;
end
if sampleAction == "none"
    routeLabel = symbolAction;
    return;
end
if symbolAction == "none"
    routeLabel = sampleAction;
    return;
end
routeLabel = sampleAction + "+" + symbolAction;
end

function cfg = local_require_adaptive_frontend_cfg_local(mitigation)
if ~(isfield(mitigation, "adaptiveFrontend") && isstruct(mitigation.adaptiveFrontend))
    error("mitigation.adaptiveFrontend is required for adaptive_ml_frontend.");
end
cfg = mitigation.adaptiveFrontend;
end

function hdrSymPrep = local_prepare_header_symbols_local(hdrSym, actionName, mitigation, headerActionCtx)
hdrSym = hdrSym(:);
actionName = string(actionName);
if nargin < 4 || isempty(headerActionCtx)
    headerActionCtx = local_empty_header_action_ctx_local();
end
if any(actionName == ["none" "fh_erasure" "ml_fh_erasure"])
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

function [phy, headerOk] = local_try_decode_header_local(rFull, preLen, hdrLen, primaryAction, mitigation, frameCfg, fhCfgBase, fecCfg, softCfg, sampleFhDehopped)
phy = struct();
headerOk = false;
rFull = rFull(:);
hdrRaw = rFull(preLen+1:preLen+hdrLen);
[hdrRaw, headerHopInfo] = local_header_known_fh_demod_local(hdrRaw, frameCfg, fhCfgBase, fecCfg, sampleFhDehopped);
actions = local_header_action_candidates_local(primaryAction, mitigation);
copyLen = phy_header_single_symbol_length(frameCfg, fecCfg);
copies = phy_header_diversity_copies(frameCfg);
if hdrLen ~= copyLen * copies
    error("PHY-header diversity length mismatch: hdrLen=%d, copyLen=%d, copies=%d.", hdrLen, copyLen, copies);
end
for actionName = actions
    for copyIdx = 1:copies
        copyRange = (copyIdx - 1) * copyLen + (1:copyLen);
        hdrCopyRaw = hdrRaw(copyRange);
        headerBlock = [complex(zeros(preLen, 1)); hdrCopyRaw];
        headerActionCtx = local_build_header_action_ctx_local(headerBlock, preLen, copyLen, actionName, mitigation);
        if isstruct(headerHopInfo) && isfield(headerHopInfo, "enable") && headerHopInfo.enable ...
                && isfield(headerHopInfo, "hopLen") && double(headerHopInfo.hopLen) > 0
            headerActionCtx.usePerHop = true;
            headerActionCtx.hopLen = min(copyLen, round(double(headerHopInfo.hopLen)));
            if isfield(headerActionCtx, "bandstopCfg") && isstruct(headerActionCtx.bandstopCfg)
                headerActionCtx.bandstopCfg.forcedFreqBounds = zeros(0, 2);
            end
        end
        hdrSym = local_prepare_header_symbols_local(hdrCopyRaw, actionName, mitigation, headerActionCtx);
        hdrBits = decode_phy_header_symbols(hdrSym, frameCfg, fecCfg, softCfg);
        [phyNow, okNow] = parse_phy_header_bits(hdrBits, frameCfg);
        if okNow
            phy = phyNow;
            headerOk = true;
            return;
        end
    end
end
end

function [phy, headerOk, rFullUsed] = local_try_decode_header_candidates_local(headerCandidates, preLen, hdrLen, primaryAction, mitigation, frameCfg, fhCfgBase, fecCfg, softCfg, sampleFhDehopped)
if ~(isstruct(headerCandidates) && ~isempty(headerCandidates))
    error("Header decode candidate list must be a non-empty struct array.");
end

phy = struct();
headerOk = false;
rFullUsed = headerCandidates(1).rFull;

for idx = 1:numel(headerCandidates)
    candidate = headerCandidates(idx);
    if ~(isfield(candidate, "rFull") && ~isempty(candidate.rFull))
        error("Header decode candidate %d is missing rFull.", idx);
    end
    [phy, headerOk] = local_try_decode_header_local( ...
        candidate.rFull, preLen, hdrLen, primaryAction, mitigation, frameCfg, fhCfgBase, fecCfg, softCfg, sampleFhDehopped);
    if headerOk
        rFullUsed = candidate.rFull;
        return;
    end
end
end

function [hdrRaw, hopInfo] = local_header_known_fh_demod_local(hdrRaw, frameCfg, fhCfgBase, fecCfg, sampleFhDehopped)
hdrRaw = hdrRaw(:);
fhCfg = phy_header_fh_cfg(frameCfg, fhCfgBase, fecCfg);
hopInfo = struct('enable', false);
if ~fhCfg.enable
    return;
end
if fh_is_fast(fhCfg)
    baseHdrLen = phy_header_symbol_length(frameCfg, fecCfg);
    hdrRaw = local_group_mean_complex_local(hdrRaw, fh_hops_per_symbol(fhCfg), baseHdrLen);
    return;
end
hopInfo = hop_info_from_fh_cfg_local(fhCfg, numel(hdrRaw));
if ~sampleFhDehopped
    hdrRaw = fh_demodulate(hdrRaw, hopInfo);
end
end

function raw = local_init_raw_capture_local(nPackets, nSessionFrames, rxDiversityCfg)
raw = struct();
raw.rxPackets = cell(nPackets, 1);
raw.sessionRx = cell(nSessionFrames, 1);
raw.rxDiversity = rxDiversityCfg;
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
nom.adaptivePSample = zeros(nPackets, 1);
nom.adaptivePSymbol = zeros(nPackets, 1);
nom.adaptiveEvmScores = cell(nPackets, 1);
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
nom.adaptivePSample = zeros(nFrames, 1);
nom.adaptivePSymbol = zeros(nFrames, 1);
nom.adaptiveEvmScores = cell(nFrames, 1);
end

function sessionRx = local_capture_session_frames_raw_local(sessionFrames, rxAmplitudeScale, N0, channelBank, frameDelay, waveform, rxDiversityCfg)
sessionRx = cell(numel(sessionFrames), 1);
if isempty(sessionFrames)
    return;
end

for frameIdx = 1:numel(sessionFrames)
    sessionFrame = sessionFrames(frameIdx);
    tx = [zeros(frameDelay, 1); rxAmplitudeScale * sessionFrame.txSymForChannel];
    sessionRx{frameIdx} = local_capture_rx_diversity_waveforms_local(tx, N0, channelBank, rxDiversityCfg);
end
end

function rxCfg = local_capture_rx_diversity_cfg_local(branchCapture)
branches = local_rx_capture_branch_list_local(branchCapture);
if numel(branches) <= 1
    rxCfg = local_disabled_rx_diversity_cfg_local();
else
    rxCfg = struct("enable", true, "nRx", double(numel(branches)), "combineMethod", "mrc");
end
end

function rxBranches = local_capture_rx_diversity_waveforms_local(tx, N0, channelBank, rxDiversityCfg)
cfg = local_validate_rx_diversity_cfg_local(rxDiversityCfg, "rxDiversity");
if ~iscell(channelBank) || numel(channelBank) ~= double(cfg.nRx)
    error("RX diversity channel bank must contain %d branches.", double(cfg.nRx));
end
rxBranches = cell(double(cfg.nRx), 1);
for branchIdx = 1:double(cfg.nRx)
    rxBranches{branchIdx} = channel_bg_impulsive(tx, N0, channelBank{branchIdx});
end
end

function channelBank = local_freeze_rx_diversity_channel_bank_local(channelIn, rxDiversityCfg)
cfg = local_validate_rx_diversity_cfg_local(rxDiversityCfg, "rxDiversity");
channelBank = cell(double(cfg.nRx), 1);
for branchIdx = 1:double(cfg.nRx)
    channelBank{branchIdx} = local_freeze_channel_realization_local(channelIn);
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
    hdrLen = numel(txPackets(pktIdx).phyHeaderSymTx);
    dataLen = numel(txPackets(pktIdx).dataSymHop);
    totalLen = preLen + hdrLen + dataLen;
    sampleActionHint = local_initial_sample_action_hint_local(methodName, adaptiveEnabled);
    bootstrapChain = local_capture_bootstrap_chain_for_method_local(methodName, adaptiveEnabled);
    fhCaptureCfg = local_packet_sample_fh_capture_cfg_local(txPackets(pktIdx), fhAssumption);
    front = local_capture_synced_block_local( ...
        rxRaw, syncSymRef, totalLen, syncCfgUse, mitigation, p.mod, waveform, sampleActionHint, bootstrapChain, fhCaptureCfg, rawCapture.rxDiversity);
    if ~front.ok
        continue;
    end

    captureFn = @(sampleAction) local_capture_synced_block_local( ...
        rxRaw, syncSymRef, totalLen, syncCfgUse, mitigation, p.mod, waveform, ...
        sampleAction, local_capture_bootstrap_chain_for_method_local(methodName, adaptiveEnabled), fhCaptureCfg, rawCapture.rxDiversity);
    [decision, front] = local_select_frontend_action_local( ...
        methodName, adaptiveEnabled, front, syncSymRef, ...
        mitigation, p.channel, waveform, N0, captureFn);
    if ~front.ok
        continue;
    end
    rFull = front.rFull;
    reliabilityFull = front.reliabilityFull;
    nom.adaptiveClass(pktIdx) = string(decision.selectedClass);
    nom.adaptiveAction(pktIdx) = string(decision.selectedAction);
    nom.adaptiveBootstrapPath(pktIdx) = string(front.bootstrapPath);
    nom.adaptiveConfidence(pktIdx) = double(decision.confidence);
    nom.adaptivePSample(pktIdx) = double(decision.pSample);
    nom.adaptivePSymbol(pktIdx) = double(decision.pSymbol);
    nom.adaptiveEvmScores{pktIdx} = decision.evmScores;

    multipathEqReliabilityFull = [];
    multipathEq = [];
    chLenSymbols = NaN;
    freqBySymbol = zeros(totalLen, 1);
    rFullRaw = rFull;
    rFullForHeader = rFull;
    headerDecodeCandidates = local_single_header_decode_candidate_local("none", rFullForHeader);
    if local_multipath_eq_enabled_local(p.channel, rxSyncCfg)
        chLenSymbols = local_multipath_channel_len_symbols_local(p.channel, waveform);
        eqCfg = rxSyncCfg.multipathEq;
        freqBySymbol = local_packet_equalizer_frequency_vector_local(txPackets(pktIdx), fhCaptureCfg, totalLen);
        preambleForEq = local_preamble_for_equalizer_estimation_local(rFull(1:preLen), decision.symbolAction, mitigation);
        eq = local_design_multipath_equalizer_local(syncSymRef, preambleForEq, eqCfg, N0, chLenSymbols, freqBySymbol);
        multipathEq = eq;
        multipathEqReliabilityFull = local_multipath_equalizer_reliability_vector_local(eq, freqBySymbol, mitigation);
        if local_sc_fde_equalizer_method_local(rxSyncCfg)
            rFullEqGuard = local_apply_frequency_aware_equalizer_block_local(rFull, eq, freqBySymbol);
            headerEqLen = preLen + hdrLen;
            if headerEqLen > 0
                rFullForHeader(1:headerEqLen) = rFullEqGuard(1:headerEqLen);
            end
        else
            rFull = local_apply_frequency_aware_equalizer_block_local(rFull, eq, freqBySymbol);
            rFullForHeader = rFull;
        end
        headerDecodeCandidates = local_build_header_decode_candidates_local( ...
            rFullRaw, rFullForHeader, syncSymRef, rxSyncCfg, N0, chLenSymbols, freqBySymbol, decision.symbolAction, mitigation);
    end

    nom.frontEndOk(pktIdx) = true;
    nom.preambleRef{pktIdx} = syncSymRef;

    actionName = string(decision.symbolAction);
    [phy, headerOk, rFullHeaderUsed] = local_try_decode_header_candidates_local( ...
        headerDecodeCandidates, preLen, hdrLen, actionName, mitigation, p.frame, p.fh, p.fec, p.softMetric, ...
        local_header_sample_fh_demod_enabled_local(fhCaptureCfg));
    nom.preambleRx{pktIdx} = fit_complex_length_local(rFullHeaderUsed(1:preLen), preLen);
    nom.headerOk(pktIdx) = headerOk;
    if ~headerOk
        continue;
    end

    rxState = derive_rx_packet_state_local( ...
        p, double(phy.packetIndex), local_packet_data_bits_len_from_header_local(p, double(phy.packetIndex), phy));
    rxState.sampleFhDataDemod = local_data_sample_fh_demod_enabled_local(fhCaptureCfg);
    rxState.adaptivePSymbolBlend = double(decision.pSymbol);
    if ~isempty(multipathEqReliabilityFull)
        rxState.multipathEqReliability = local_fit_reliability_length_local( ...
            multipathEqReliabilityFull(preLen+hdrLen+1:end), rxState.nDataSym);
    end
    if local_rx_state_sc_fde_enabled_local(rxState)
        rxState.scFdeDiversity = local_build_sc_fde_diversity_state_local( ...
            front, preLen, hdrLen, syncSymRef, p.channel, rxSyncCfg, p.mod, waveform, fhCaptureCfg, N0, chLenSymbols, freqBySymbol, rxState, decision.symbolAction, mitigation);
    end
    if local_sc_fde_equalizer_method_local(rxSyncCfg)
        if isempty(multipathEq)
            error("SC-FDE receiver branch requires a preamble-derived channel estimate.");
        end
        rxState.scFdeEq = multipathEq;
        rxState.scFdeN0 = double(N0);
        rxState.scFdeFallbackSymbols = fit_complex_length_local(rFullEqGuard(preLen+hdrLen+1:end), rxState.nDataSym);
        rxState.scFdeFallbackReliability = local_fit_reliability_length_local(reliabilityFull(preLen+hdrLen+1:end), rxState.nDataSym);
    end
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
    fhCaptureCfg = local_session_sample_fh_capture_cfg_local(sessionFrame, fhAssumption);
    front = local_capture_synced_block_local( ...
        sessionRx{frameIdx}, sessionFrame.syncSym(:), totalLen, syncCfgUse, mitigation, sessionFrame.modCfg, waveform, sampleActionHint, bootstrapChain, fhCaptureCfg, local_capture_rx_diversity_cfg_local(sessionRx{frameIdx}));
    if ~front.ok
        continue;
    end

    captureFn = @(sampleAction) local_capture_synced_block_local( ...
        sessionRx{frameIdx}, sessionFrame.syncSym(:), totalLen, syncCfgUse, mitigation, sessionFrame.modCfg, waveform, ...
        sampleAction, local_capture_bootstrap_chain_for_method_local(methodName, adaptiveEnabled), fhCaptureCfg, local_capture_rx_diversity_cfg_local(sessionRx{frameIdx}));
    [decision, front] = local_select_frontend_action_local( ...
        methodName, adaptiveEnabled, front, sessionFrame.syncSym(:), ...
        mitigation, p.channel, waveform, N0, captureFn);
    if ~front.ok
        continue;
    end
    rFull = front.rFull;
    reliabilityFull = front.reliabilityFull;
    nom.adaptiveClass(frameIdx) = string(decision.selectedClass);
    nom.adaptiveAction(frameIdx) = string(decision.selectedAction);
    nom.adaptiveBootstrapPath(frameIdx) = string(front.bootstrapPath);
    nom.adaptiveConfidence(frameIdx) = double(decision.confidence);
    nom.adaptivePSample(frameIdx) = double(decision.pSample);
    nom.adaptivePSymbol(frameIdx) = double(decision.pSymbol);
    nom.adaptiveEvmScores{frameIdx} = decision.evmScores;

    if local_multipath_eq_enabled_local(p.channel, rxSyncCfg)
        chLenSymbols = local_multipath_channel_len_symbols_local(p.channel, waveform);
        eqCfg = rxSyncCfg.multipathEq;
        freqBySymbol = local_session_equalizer_frequency_vector_local(sessionFrame, fhCaptureCfg, totalLen);
        preambleForEq = local_preamble_for_equalizer_estimation_local(rFull(1:preLen), decision.symbolAction, mitigation);
        eq = local_design_multipath_equalizer_local(sessionFrame.syncSym(:), preambleForEq, eqCfg, N0, chLenSymbols, freqBySymbol);
        rFull = local_apply_frequency_aware_equalizer_block_local(rFull, eq, freqBySymbol);
    end

    rxStateSession = local_session_rx_state_local(sessionFrame);
    rxStateSession.sampleFhDataDemod = local_data_sample_fh_demod_enabled_local(fhCaptureCfg);
    rxStateSession.adaptivePSymbolBlend = double(decision.pSymbol);
    nom.preambleRx{frameIdx} = fit_complex_length_local(rFull(1:preLen), preLen);
    nom.preambleRef{frameIdx} = sessionFrame.syncSym(:);
    actionName = string(decision.symbolAction);
    nom.symbolAction(frameIdx) = actionName;
    if string(sessionFrame.decodeKind) == "protected_header"
        hopInfoUsed = local_nominal_hop_info_local(rxStateSession, fhAssumption);
        [nom.rDataPrepared{frameIdx}, nom.rDataReliability{frameIdx}] = ...
            local_prepare_session_header_symbols_local( ...
                rFull, reliabilityFull, preLen, sessionFrame, hopInfoUsed, ...
                local_data_sample_fh_demod_enabled_local(fhCaptureCfg));
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

function nSym = local_session_decode_symbol_count_local(sessionFrame)
nSym = local_session_demod_symbol_count_local(sessionFrame);
if string(sessionFrame.decodeKind) ~= "protected_header"
    return;
end
[copies, copyLen] = local_session_header_body_diversity_info_local(sessionFrame);
if copies > 1
    nSym = copies * copyLen;
end
end

function [copies, copyLen] = local_session_header_body_diversity_info_local(sessionFrame)
copies = 1;
copyLen = local_session_demod_symbol_count_local(sessionFrame);
if isfield(sessionFrame, "bodyDiversityCopies") && ~isempty(sessionFrame.bodyDiversityCopies)
    copies = round(double(sessionFrame.bodyDiversityCopies));
end
if isfield(sessionFrame, "bodyDiversityCopyLen") && ~isempty(sessionFrame.bodyDiversityCopyLen)
    copyLen = round(double(sessionFrame.bodyDiversityCopyLen));
end
if ~(isscalar(copies) && isfinite(copies) && copies >= 1)
    error("Session header body diversity copies must be a positive integer scalar.");
end
if ~(isscalar(copyLen) && isfinite(copyLen) && copyLen >= 0)
    error("Session header body diversity copyLen must be a nonnegative integer scalar.");
end
copies = round(copies);
copyLen = round(copyLen);
if copies > 1 && double(sessionFrame.nDataSym) ~= copies * copyLen
    error("Session header body diversity length mismatch: nDataSym=%d, copies=%d, copyLen=%d.", ...
        double(sessionFrame.nDataSym), copies, copyLen);
end
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

    nDecodeSym = local_session_decode_symbol_count_local(sessionFrames(frameIdx));
    rData = fit_complex_length_local(sessionNom.rDataPrepared{frameIdx}, nDecodeSym);
    reliability = [];
    if isfield(sessionNom, "rDataReliability") && numel(sessionNom.rDataReliability) >= frameIdx ...
            && ~isempty(sessionNom.rDataReliability{frameIdx})
        reliability = local_fit_reliability_length_local(sessionNom.rDataReliability{frameIdx}, nDecodeSym);
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

    rMitList{end+1, 1} = fit_complex_length_local(rData, nDecodeSym); %#ok<AGROW>
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
            [bodyCopies, bodyCopyLen] = local_session_header_body_diversity_info_local(sessionFrame);
            if bodyCopies > 1
                if numel(rUse) ~= bodyCopies * bodyCopyLen
                    error("Session header body diversity decode length mismatch: len=%d, copies=%d, copyLen=%d.", ...
                        numel(rUse), bodyCopies, bodyCopyLen);
                end
                rUseCopies = cell(bodyCopies, 1);
                for copyIdx = 1:bodyCopies
                    copyRange = (copyIdx - 1) * bodyCopyLen + (1:bodyCopyLen);
                    rCopy = rUse(copyRange);
                    if symbolRepeat > 1
                        rCopy = local_repeat_combine_symbols_local(rCopy, symbolRepeat);
                    end
                    rUseCopies{copyIdx} = rCopy;
                    sessionBits = decode_protected_header_symbols(rCopy, sessionFrame.infoBitsLen, p.frame, p.fec, p.softMetric);
                    [metaSession, ~, ok] = parse_session_header_bits(sessionBits, p.frame);
                    if ok
                        return;
                    end
                end
                rCombined = local_average_session_symbols_local(rUseCopies);
                sessionBits = decode_protected_header_symbols(rCombined, sessionFrame.infoBitsLen, p.frame, p.fec, p.softMetric);
                [metaSession, ~, ok] = parse_session_header_bits(sessionBits, p.frame);
                if ok
                    return;
                end
                continue;
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

function [hdrRaw, reliability] = local_prepare_session_header_symbols_local(rFull, reliabilityFull, preLen, sessionFrame, hopInfoUsed, sampleFhDehopped)
hdrLen = double(sessionFrame.nDataSym);
hdrRaw = fit_complex_length_local(rFull(preLen+1:end), hdrLen);
reliability = local_fit_reliability_length_local(reliabilityFull(preLen+1:end), hdrLen);
if ~(isfield(sessionFrame, "fhCfg") && isstruct(sessionFrame.fhCfg) ...
        && isfield(sessionFrame.fhCfg, "enable") && sessionFrame.fhCfg.enable)
    return;
end
if fh_is_fast(sessionFrame.fhCfg)
    baseLen = local_session_demod_symbol_count_local(sessionFrame);
    hdrRaw = local_group_mean_complex_local(hdrRaw, fh_hops_per_symbol(sessionFrame.fhCfg), baseLen);
    reliability = local_group_mean_real_local(reliability, fh_hops_per_symbol(sessionFrame.fhCfg), baseLen);
    return;
end
if nargin >= 5 && isstruct(hopInfoUsed) && isfield(hopInfoUsed, "enable") && hopInfoUsed.enable
    hopInfo = hopInfoUsed;
else
    hopInfo = hop_info_from_fh_cfg_local(sessionFrame.fhCfg, numel(hdrRaw));
end
if ~(nargin >= 6 && logical(sampleFhDehopped))
    hdrRaw = fh_demodulate(hdrRaw, hopInfo);
end
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
cfg = local_require_adaptive_frontend_cfg_local(mitigationCfg);
local_require_struct_fields_local(cfg, ...
    ["bootstrapSyncChain", "classNames", "stages", "diagnostics"], ...
    "mitigation.adaptiveFrontend");

classNames = string(cfg.classNames(:).');
bootstrapPaths = string(cfg.bootstrapSyncChain(:).');
if isempty(classNames)
    error("mitigation.adaptiveFrontend.classNames 不能为空。");
end
if isempty(bootstrapPaths)
    error("mitigation.adaptiveFrontend.bootstrapSyncChain 不能为空。");
end

stagesCfg = local_require_adaptive_stages_cfg_local(cfg);
sampleActions = local_stage_action_catalog_local(stagesCfg.sample, "sample");
symbolActions = local_stage_action_catalog_local(stagesCfg.symbol, "symbol");

diagCfg = struct( ...
    "classNames", classNames, ...
    "actionNames", local_build_adaptive_action_catalog_local(sampleActions, symbolActions), ...
    "bootstrapPaths", bootstrapPaths);
end

function actions = local_stage_action_catalog_local(stageCfg, layerName)
actions = "none";
if ~(isfield(stageCfg, "candidates") && ~isempty(stageCfg.candidates))
    return;
end
candidates = lower(string(stageCfg.candidates(:).'));
for k = 1:numel(candidates)
    actionName = candidates(k);
    if actionName == "none"
        continue;
    end
    [sampleAction, symbolAction] = local_split_mitigation_action_local(actionName);
    switch lower(string(layerName))
        case "sample"
            if sampleAction == "none" || symbolAction ~= "none"
                error("mitigation.adaptiveFrontend.stages.sample candidate %s must be a sample-domain action.", char(actionName));
            end
            resolved = sampleAction;
        case "symbol"
            if symbolAction == "none" || sampleAction ~= "none"
                error("mitigation.adaptiveFrontend.stages.symbol candidate %s must be a symbol-domain action.", char(actionName));
            end
            resolved = symbolAction;
        otherwise
            error("Unsupported adaptive stage layer: %s", char(layerName));
    end
    if ~any(actions == resolved)
        actions(end + 1) = resolved; %#ok<AGROW>
    end
end
end

function actionNames = local_build_adaptive_action_catalog_local(sampleActions, symbolActions)
sampleActions = unique(string(sampleActions(:).'), "stable");
symbolActions = unique(string(symbolActions(:).'), "stable");
if isempty(sampleActions) || isempty(symbolActions)
    error("Adaptive front-end action catalog requires non-empty sample and symbol action sets.");
end

actionNames = strings(1, 0);
for isample = 1:numel(sampleActions)
    for isymbol = 1:numel(symbolActions)
        actionLabel = local_compose_adaptive_action_label_local(sampleActions(isample), symbolActions(isymbol));
        if ~any(actionNames == actionLabel)
            actionNames(end + 1) = actionLabel; %#ok<AGROW>
        end
    end
end
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

function divState = local_build_sc_fde_diversity_state_local(front, preLen, hdrLen, syncSymRef, channelCfg, rxSyncCfg, modCfg, waveform, fhCaptureCfg, N0, chLenSymbols, freqBySymbol, rxState, symbolAction, mitigation)
divState = local_disabled_sc_fde_diversity_state_local();
if ~local_rx_state_sc_fde_enabled_local(rxState)
    return;
end

branchFronts = local_valid_capture_branch_fronts_local(front);
if numel(branchFronts) <= 1
    return;
end

multipathEqEnabled = local_multipath_eq_enabled_local(channelCfg, rxSyncCfg);
useScFdeEq = multipathEqEnabled && local_sc_fde_equalizer_method_local(rxSyncCfg);
eqCfg = struct();
if multipathEqEnabled
    eqCfg = rxSyncCfg.multipathEq;
end
totalLen = preLen + hdrLen + rxState.nDataSym;
payloadBranches = cell(numel(branchFronts), 1);
reliabilityBranches = cell(numel(branchFronts), 1);
eqBranches = cell(numel(branchFronts), 1);
fallbackBranches = cell(numel(branchFronts), 1);
fallbackReliabilityBranches = cell(numel(branchFronts), 1);

for branchIdx = 1:numel(branchFronts)
    branchFront = branchFronts{branchIdx};
    if ~(isstruct(branchFront) && isfield(branchFront, "rFull") && isfield(branchFront, "reliabilityFull"))
        error("SC-FDE diversity branch %d is missing synchronized full-block state.", branchIdx);
    end
    rFullBranch = fit_complex_length_local(branchFront.rFull, totalLen);
    relFullBranch = local_fit_reliability_length_local(branchFront.reliabilityFull, totalLen);
    payloadFullBranch = rFullBranch;
    eqBranch = struct();
    rFullEqGuardBranch = complex(zeros(0, 1));
    if multipathEqEnabled
        preambleForEqBranch = local_preamble_for_equalizer_estimation_local(rFullBranch(1:preLen), symbolAction, mitigation);
        eqBranch = local_design_multipath_equalizer_local( ...
            syncSymRef, preambleForEqBranch, eqCfg, N0, chLenSymbols, freqBySymbol);
        rFullEqGuardBranch = local_apply_frequency_aware_equalizer_block_local(rFullBranch, eqBranch, freqBySymbol);
        if ~useScFdeEq
            payloadFullBranch = rFullEqGuardBranch;
        end
    end

    payloadBranches{branchIdx} = fit_complex_length_local(payloadFullBranch(preLen+hdrLen+1:end), rxState.nDataSym);
    reliabilityBranches{branchIdx} = local_fit_reliability_length_local(relFullBranch(preLen+hdrLen+1:end), rxState.nDataSym);
    eqBranches{branchIdx} = eqBranch;
    if useScFdeEq
        fallbackBranches{branchIdx} = fit_complex_length_local(rFullEqGuardBranch(preLen+hdrLen+1:end), rxState.nDataSym);
        fallbackReliabilityBranches{branchIdx} = local_fit_reliability_length_local(relFullBranch(preLen+hdrLen+1:end), rxState.nDataSym);
    else
        fallbackBranches{branchIdx} = complex(zeros(0, 1));
        fallbackReliabilityBranches{branchIdx} = zeros(0, 1);
    end
end

divState = struct( ...
    "enable", true, ...
    "nBranches", double(numel(branchFronts)), ...
    "payloadBranches", {payloadBranches}, ...
    "reliabilityBranches", {reliabilityBranches}, ...
    "eqBranches", {eqBranches}, ...
    "fallbackEnable", logical(useScFdeEq), ...
    "fallbackBranches", {fallbackBranches}, ...
    "fallbackReliabilityBranches", {fallbackReliabilityBranches});
end

function branchFronts = local_valid_capture_branch_fronts_local(front)
if ~(isstruct(front) && isfield(front, "branchFronts") && iscell(front.branchFronts) ...
        && isfield(front, "branchOkMask") && ~isempty(front.branchOkMask))
    error("RX front is missing branchFronts/branchOkMask metadata.");
end
branchOkMask = logical(front.branchOkMask(:));
if numel(branchOkMask) ~= numel(front.branchFronts)
    error("RX front branchOkMask size does not match branchFronts.");
end
usedIdx = find(branchOkMask);
branchFronts = front.branchFronts(usedIdx);
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
nDataSymBase = dsss_symbol_count(nDemodSym, dsssCfg);
scFdeCfg = sc_fde_payload_config(p);
scFdePlan = sc_fde_payload_plan(nDataSymBase, scFdeCfg);
nFhInputSym = nDataSymBase;
if scFdePlan.enable
    nFhInputSym = scFdePlan.nTxSymbols;
end
fhCfg = derive_packet_fh_cfg(p.fh, pktIdx, offsets.fhOffsetHops, nFhInputSym);
nDataSym = nFhInputSym;
if isfield(fhCfg, "enable") && fhCfg.enable && fh_is_fast(fhCfg)
    nDataSym = nFhInputSym * fh_hops_per_symbol(fhCfg);
end

state = struct();
state.packetIndex = pktIdx;
state.packetDataBitsLen = packetDataBitsLen;
state.packetDataBytes = ceil(packetDataBitsLen / 8);
state.fecCodedBitsLen = fecCodedBitsLen;
state.codedBitsLen = numel(codedBitsInt);
state.nDemodSym = nDemodSym;
state.nDataSymBase = nDataSymBase;
state.nFhInputSym = nFhInputSym;
state.nDataSym = nDataSym;
state.intState = intState;
state.stateOffsets = offsets;
state.scrambleCfg = derive_packet_scramble_cfg(p.scramble, pktIdx, offsets.scrambleOffsetBits);
state.dsssCfg = dsssCfg;
state.fhCfg = fhCfg;
state.hopInfo = hop_info_from_fh_cfg_local(state.fhCfg, nFhInputSym);
state.scFdeCfg = scFdeCfg;
state.scFdePlan = scFdePlan;
state.scFdeDiversity = local_disabled_sc_fde_diversity_state_local();
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
hopInfo = fh_hop_info_from_cfg(fhCfg, nSym);
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

function tf = local_header_sample_fh_demod_enabled_local(fhCaptureCfg)
tf = isstruct(fhCaptureCfg) && isfield(fhCaptureCfg, "enable") && logical(fhCaptureCfg.enable) ...
    && isfield(fhCaptureCfg, "headerFhCfg") && isstruct(fhCaptureCfg.headerFhCfg) ...
    && isfield(fhCaptureCfg.headerFhCfg, "enable") && logical(fhCaptureCfg.headerFhCfg.enable);
end

function tf = local_data_sample_fh_demod_enabled_local(fhCaptureCfg)
tf = isstruct(fhCaptureCfg) && isfield(fhCaptureCfg, "enable") && logical(fhCaptureCfg.enable) ...
    && isfield(fhCaptureCfg, "dataFhCfg") && isstruct(fhCaptureCfg.dataFhCfg) ...
    && isfield(fhCaptureCfg.dataFhCfg, "enable") && logical(fhCaptureCfg.dataFhCfg.enable);
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

function cfg = local_disabled_rx_diversity_cfg_local()
cfg = struct("enable", false, "nRx", 1, "combineMethod", "mrc");
end

function cfg = local_validate_rx_diversity_cfg_local(cfgIn, ownerName)
if nargin < 2 || strlength(string(ownerName)) == 0
    ownerName = "rxDiversity";
end
if ~(isstruct(cfgIn) && isscalar(cfgIn))
    error("%s 必须是标量struct。", char(ownerName));
end
local_require_struct_fields_local(cfgIn, ["enable", "nRx", "combineMethod"], char(ownerName));

cfg = struct();
cfg.enable = logical(cfgIn.enable);
if ~isscalar(cfg.enable)
    error("%s.enable 必须是逻辑标量。", char(ownerName));
end
cfg.nRx = double(cfgIn.nRx);
if ~(isscalar(cfg.nRx) && isfinite(cfg.nRx) && cfg.nRx >= 1 && abs(cfg.nRx - round(cfg.nRx)) <= 1e-12)
    error("%s.nRx 必须是正整数标量。", char(ownerName));
end
cfg.nRx = round(cfg.nRx);
cfg.combineMethod = lower(string(cfgIn.combineMethod));
if strlength(cfg.combineMethod) == 0
    error("%s.combineMethod 不能为空。", char(ownerName));
end
if cfg.enable
    if cfg.nRx ~= 2
        error("%s.enable=true 时当前仅支持 nRx=2。", char(ownerName));
    end
else
    if cfg.nRx ~= 1
        error("%s.enable=false 时必须设置 nRx=1。", char(ownerName));
    end
end
if cfg.combineMethod ~= "mrc"
    error("%s.combineMethod 当前仅支持 ""mrc""。", char(ownerName));
end
end

function eveCfg = local_validate_eve_config_local(eveCfg, methodsMain, channelCfg)
local_require_struct_field_local(eveCfg, "linkGainOffsetDb", "eve");
local_require_struct_field_local(eveCfg, "scrambleAssumption", "eve");
local_require_struct_field_local(eveCfg, "fhAssumption", "eve");
local_require_struct_field_local(eveCfg, "chaosAssumption", "eve");
local_require_struct_field_local(eveCfg, "chaosApproxDelta", "eve");
local_require_struct_field_local(eveCfg, "rxSync", "eve");
local_require_struct_field_local(eveCfg, "rxDiversity", "eve");
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
eveCfg.rxDiversity = local_validate_rx_diversity_cfg_local(eveCfg.rxDiversity, "eve.rxDiversity");
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
    "bootstrapSyncChain", "classNames", "stages", "diagnostics"], ...
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

function summary = local_pack_rx_diversity_summary_local(rxDiversityCfg)
cfg = local_validate_rx_diversity_cfg_local(rxDiversityCfg, "rxDiversity");
summary = struct( ...
    "enable", logical(cfg.enable), ...
    "nRx", double(cfg.nRx), ...
    "combineMethod", string(cfg.combineMethod));
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
