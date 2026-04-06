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
bobRxSync = p.rxSync;
bobMitigation = p.mitigation;
waveform = resolve_waveform_cfg(p);
local_require_presync_mitigation_cfg_local(bobMitigation, "p.mitigation");

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
nPackets = numel(txPackets);
sessionFrames = txPlan.sessionFrames;
hasDedicatedSessionFrames = ~isempty(sessionFrames);
% 主链路译码统计仅依赖每包payload比特（避免在并行worker间广播巨大的txPackets结构体）
txPktIndex = (1:nPackets).';
txPayloadBits = {txPackets.payloadBits}.';
fhEnabled = txPlan.fhEnabled;
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
packetConcealActive = packetConcealEnable && nPackets > 1;

% 用于信道/频谱/监视者评估的整段突发
txSymForChannel = txPlan.txBurstForChannel;
modInfo = txPlan.modInfo;
txBaseReport = measure_tx_burst(txSymForChannel, waveform);
linkBudget = resolve_link_budget(p.linkBudget, p.tx, modInfo, txBaseReport.averagePowerLin);
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
fprintf('[SIM] Tx记录: burst %.3fs, txPower点=%s dB, base avg %.4f (1 sps等效)\n', ...
    txReport.burstDurationSec, mat2str(double(txReport.configuredPowerDb)), txBaseReport.averagePowerLin);

%% 仿真参数初始化与配置

EbN0dBList = linkBudget.bob.ebN0dB(:).'; % 由链路预算推导的Bob接收端Eb/N0
methods = string(bobMitigation.methods(:).');%仿真不同脉冲噪声抑制方法，列向量

ber = nan(numel(methods), numel(EbN0dBList)); %比特错误率（BER）统计
packetFrontEndBobVals = nan(1, numel(EbN0dBList));
packetHeaderBobVals = nan(1, numel(EbN0dBList));
packetFrontEndBobMethodVals = nan(numel(methods), numel(EbN0dBList));
packetHeaderBobMethodVals = nan(numel(methods), numel(EbN0dBList));
packetSuccessBobVals = nan(numel(methods), numel(EbN0dBList));
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
    eveCfg = local_validate_eve_config_local(p.eve, methods);
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

% 将“对外按符号/Hz配置”的信道参数映射到“对内按采样执行”。
channelSample = adapt_channel_for_sps(p.channel, waveform);
maxDelaySamples = max(0, round(double(p.channel.maxDelaySymbols) * waveform.sps));

totalEbN0Points = numel(EbN0dBList);
totalFrames = totalEbN0Points * p.sim.nFramesPerPoint;
globalFrameIdx = 0;
frameLogStep = max(1, floor(p.sim.nFramesPerPoint / 10));
simTic = tic;

fprintf('\n========================================\n');
fprintf('[SIM] 链路仿真开始\n');
fprintf('[SIM] 链路预算点数=%d, 每点帧数=%d, 总帧数=%d\n', ...
    totalEbN0Points, p.sim.nFramesPerPoint, totalFrames);
fprintf('[SIM] Tx功率点=%s dB\n', mat2str(double(linkBudget.bob.txPowerDb)));
fprintf('[SIM] 抑制方法(%d): %s\n', numel(methods), strjoin(cellstr(methods), ', '));
if numel(methods) > 1
    hasImpulse = isfield(p, "channel") && isfield(p.channel, "impulseProb") && double(p.channel.impulseProb) > 0;
    hasTone = isfield(p, "channel") && isfield(p.channel, "singleTone") && isfield(p.channel.singleTone, "enable") && p.channel.singleTone.enable;
    hasNb = isfield(p, "channel") && isfield(p.channel, "narrowband") && isfield(p.channel.narrowband, "enable") && p.channel.narrowband.enable;
    hasSweep = isfield(p, "channel") && isfield(p.channel, "sweep") && isfield(p.channel.sweep, "enable") && p.channel.sweep.enable;
    if ~hasImpulse && ~hasTone && ~hasNb && ~hasSweep
        fprintf('[SIM] NOTE: impulse/tone/narrowband/sweep all disabled. Most mitigation methods will behave like \"none\".\n');
    end
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
fprintf('[SIM] Eve=%s, Warden=%s, FH=%s, Chaos=%s, Pulse=%s, RxSync(B/E)=%s/%s, MP=%s\n', ...
    on_off_text(eveEnabled), on_off_text(wardenEnabled), on_off_text(fhEnabled), ...
    on_off_text(chaosEnabled), pulseTxt, on_off_text(syncEnabledBob), on_off_text(syncEnabledEve), on_off_text(mpEnabled));
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
    N0 = linkBudget.bob.noisePsdLin(ie);
    txBurstBobForPoint = linkBudget.bob.rxAmplitudeScale(ie) * txSymForChannel;
    [klSigVsNoise(ie), klNoiseVsSig(ie), klSym(ie)] = signal_noise_kl(txBurstBobForPoint, N0, 128);

    fprintf('[SIM] >>> 链路预算点 %d/%d: txPower %.2f dB, Bob Eb/N0 %.2f dB\n', ...
        ie, totalEbN0Points, linkBudget.bob.txPowerDb(ie), EbN0dB);

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
        wardenRngScope = rng_scope(double(p.rngSeed) + 100000 + ie); %#ok<NASGU>
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
    metricAccComm = init_image_metric_acc_local(numel(methods));
    metricAccComp = init_image_metric_acc_local(numel(methods));
    exampleCandidates = init_example_candidate_bank_local(numel(methods), p.sim.nFramesPerPoint);


    if eveEnabled
        nErrEve = zeros(numel(methods), 1);
        nTotEve = zeros(numel(methods), 1);
        packetFrontEndEveAcc = zeros(numel(methods), 1);
        packetHeaderEveAcc = zeros(numel(methods), 1);
        packetSuccessEveAcc = zeros(numel(methods), 1);
        metricAccCommEve = init_image_metric_acc_local(numel(methods));
        metricAccCompEve = init_image_metric_acc_local(numel(methods));
        exampleCandidatesEve = init_example_candidate_bank_local(numel(methods), p.sim.nFramesPerPoint);
    end

    % --- 帧循环：每个链路预算点仿真多帧 ---
    totalPayloadBits = numel(payloadBits);
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
    frameCtx.frameSeedBase = NaN;
    if useParallelFrames
        frameCtx.frameSeedBase = local_point_frame_seed_base_local(p.rngSeed, ie);
    end

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

    fprintf('[SIM] <<< 链路预算点完成: txPower %.2f dB, Bob Eb/N0 %.2f dB, 用时 %.2fs\n', ...
        linkBudget.bob.txPowerDb(ie), EbN0dB, toc(pointTic));
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
[psd, freqHz, bw99Hz, etaBpsHz, spectrumInfo] = estimate_spectrum( ...
    txBurstForSpectrum, modInfo, waveform, struct("payloadBits", numel(payloadBits)));

results = struct();
results.params = p;
results.ebN0dB = EbN0dBList;
results.methods = methods;
results.tx = txReport;
results.linkBudget = linkBudget;
results.ber = ber;
results.packetDiagnostics = struct();
results.packetDiagnostics.bob = struct( ...
    "frontEndSuccessRate", packetFrontEndBobVals, ...
    "headerSuccessRate", packetHeaderBobVals, ...
    "frontEndSuccessRateByMethod", packetFrontEndBobMethodVals, ...
    "headerSuccessRateByMethod", packetHeaderBobMethodVals, ...
    "payloadSuccessRate", packetSuccessBobVals);
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
    "bw99Hz", bw99Hz, ...
    "etaBpsHz", etaBpsHz, ...
    "symbolRateHz", spectrumInfo.symbolRateHz, ...
    "sampleRateHz", spectrumInfo.sampleRateHz, ...
    "burstDurationSec", spectrumInfo.burstDurationSec, ...
    "grossInfoBitRateBps", spectrumInfo.grossInfoBitRateBps, ...
    "payloadBitRateBps", spectrumInfo.payloadBitRateBps);
results.kl = struct("ebN0dB", EbN0dBList, ...
    "signalVsNoise", klSigVsNoise, ...
    "noiseVsSignal", klNoiseVsSig, ...
    "symmetric", klSym);


if eveEnabled
    results.linkBudget.eve = eveBudget;
    results.eve = struct();
    results.eve.methods = methods;
    results.eve.ebN0dB = eveEbN0dBList;
    results.eve.ber = berEve;
    results.eve.packetDiagnostics = struct( ...
        "frontEndSuccessRate", packetFrontEndEveVals, ...
        "headerSuccessRate", packetHeaderEveVals, ...
        "frontEndSuccessRateByMethod", packetFrontEndEveMethodVals, ...
        "headerSuccessRateByMethod", packetHeaderEveMethodVals, ...
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

function baseSeed = local_point_frame_seed_base_local(globalSeed, pointIdx)
globalSeed = round(double(globalSeed));
pointIdx = round(double(pointIdx));
baseSeed = globalSeed + 1000000 * pointIdx;
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
    rx = pulse_rx_to_symbol_rate(rx, waveform);
    bobRaw.rxPackets{pktIdx} = rx;

    if eveEnabled
        txEve = [zeros(frameDelay, 1); frameCtx.eveRxAmplitudeScale * pkt.txSymForChannel];
        rxEve = channel_bg_impulsive(txEve, frameCtx.N0Eve, channelSampleEve);
        rxEve = pulse_rx_to_symbol_rate(rxEve, waveform);
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
exampleBob = cell(nMethods, 1);

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
exampleEve = cell(nMethods, 1);

useParfor = logical(useParallelMethods) && local_has_parallel_pool_local();
if useParfor
    try
        parfor im = 1:nMethods
            bobNom = local_build_packet_nominal_local( ...
                bobRaw, txPackets, sessionFrames, methods(im), bobMitigation, ...
                syncCfgUseBob, bobRxSync, p, waveform, N0Bob, fhEnabled, "known");
            eveNom = struct();
            if eveEnabled
                eveNom = local_build_packet_nominal_local( ...
                    eveRaw, txPackets, sessionFrames, methods(im), eveMitigation, ...
                    syncCfgUseEve, eveRxSync, p, waveform, N0Eve, fhEnabled, fhAssumptionEve);
            end

            [bobRes, eveRes] = local_decode_single_method_local( ...
                methods(im), txPktIndex, txPayloadBits, sessionFrames, bobNom, eveNom, p, fhEnabled, ...
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
            exampleBob{im} = bobRes.example;

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
        exampleBob = cell(nMethods, 1);

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
        exampleEve = cell(nMethods, 1);
    end
end

if ~useParfor
    for im = 1:nMethods
        bobNom = local_build_packet_nominal_local( ...
            bobRaw, txPackets, sessionFrames, methods(im), bobMitigation, ...
            syncCfgUseBob, bobRxSync, p, waveform, N0Bob, fhEnabled, "known");
        eveNom = struct();
        if eveEnabled
            eveNom = local_build_packet_nominal_local( ...
                eveRaw, txPackets, sessionFrames, methods(im), eveMitigation, ...
                syncCfgUseEve, eveRxSync, p, waveform, N0Eve, fhEnabled, fhAssumptionEve);
        end

        [bobRes, eveRes] = local_decode_single_method_local( ...
            methods(im), txPktIndex, txPayloadBits, sessionFrames, bobNom, eveNom, p, fhEnabled, ...
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
        exampleBob{im} = bobRes.example;

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
bobFrame.metricsComm = struct("mse", mseCommBob, "psnr", psnrCommBob, "ssim", ssimCommBob);
bobFrame.metricsComp = struct("mse", mseCompBob, "psnr", psnrCompBob, "ssim", ssimCompBob);
bobFrame.example = exampleBob;

eveFrame = struct();
if eveEnabled
    eveFrame.nErr = nErrEve;
    eveFrame.nTot = nTotEve;
    eveFrame.frontEndSuccessRate = frontEndEve;
    eveFrame.headerSuccessRate = headerEve;
    eveFrame.packetSuccessRate = packetSuccessEve;
    eveFrame.metricsComm = struct("mse", mseCommEve, "psnr", psnrCommEve, "ssim", ssimCommEve);
    eveFrame.metricsComp = struct("mse", mseCompEve, "psnr", psnrCompEve, "ssim", ssimCompEve);
    eveFrame.example = exampleEve;
end
end

function [bobRes, eveRes] = local_decode_single_method_local( ...
    methodName, txPktIndex, txPayloadBits, sessionFrames, bobNom, eveNom, p, fhEnabled, ...
    packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
    packetConcealActive, packetConcealMode, imgTx, metaTx, totalPayloadBitsTx, ...
    bobRxSync, bobMitigation, eveRxSync, eveMitigation, ...
    eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosApproxDeltaEve, chaosEncInfoEve, ...
    captureExample, EbN0dB, EbN0dBEve, nPackets)

% -------- Bob --------
sessionBob = local_init_rx_session_local(p, metaTx, nPackets);
payloadFrameBob = zeros(totalPayloadBitsTx, 1, "uint8");
packetOkBob = false(1, nPackets);
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
        rData = fit_complex_length_local(bobNom.rDataPrepared{pktIdx}, rxState.nDataSym);
        reliability = [];
        if isfield(bobNom, "rDataReliability") && numel(bobNom.rDataReliability) >= pktIdx ...
                && ~isempty(bobNom.rDataReliability{pktIdx})
            reliability = local_fit_reliability_length_local(bobNom.rDataReliability{pktIdx}, rxState.nDataSym);
        end

        demodSoft = demodulate_to_softbits(rData, p.mod, p.fec, p.softMetric, reliability);
        demodDeint = deinterleave_bits(demodSoft, rxState.intState, p.interleaver);
        dataBitsRxScr = fec_decode(demodDeint, p.fec);
        packetDataBitsRx = descramble_bits(dataBitsRxScr, rxState.scrambleCfg);
        packetDataBitsRx = fit_bits_length(packetDataBitsRx, rxState.packetDataBitsLen);

        [payloadPktRx, sessionNext, packetInfo, okPacket] = recover_payload_packet_local(packetDataBitsRx, phy, sessionBob, p);
        if okPacket
            sessionBob = sessionNext;
            if packetInfo.packetIndex == txPktIndex(pktIdx)
                txBits = txPayload;
                nCompare = min(numel(payloadPktRx), numel(txBits));
                if nCompare > 0
                    nErrBob = nErrBob + sum(payloadPktRx(1:nCompare) ~= txBits(1:nCompare));
                end
                if numel(payloadPktRx) < numel(txBits)
                    nErrBob = nErrBob + (numel(txBits) - numel(payloadPktRx));
                end
                nTotBob = nTotBob + numel(txBits);
            else
                nErrBob = nErrBob + numel(txPayload);
                nTotBob = nTotBob + numel(txPayload);
            end

            payloadFrameBob(packetInfo.range.startBit:packetInfo.range.endBit) = fit_bits_length(payloadPktRx, packetInfo.range.nBits);
            packetOkBob(packetInfo.packetIndex) = true;
        else
            nErrBob = nErrBob + numel(txPayload);
            nTotBob = nTotBob + numel(txPayload);
        end
    else
        nErrBob = nErrBob + numel(txPayload);
        nTotBob = nTotBob + numel(txPayload);
    end
end

metaBobUse = metaTx;
totalPayloadBitsBob = totalPayloadBitsTx;
if isfield(sessionBob, "known") && sessionBob.known
    metaBobUse = sessionBob.meta;
    totalPayloadBitsBob = sessionBob.totalPayloadBits;
end
rxLayoutBob = derive_packet_layout_local(totalPayloadBitsBob, p);

if packetIndependentBitChaos && chaosEnabled
    payloadBitsRxDec = decrypt_payload_packets_rx_local(payloadFrameBob, packetOkBob, p, totalPayloadBitsBob, "known", 0);
    imgRxComm = payload_bits_to_image(payloadBitsRxDec, metaBobUse, p.payload);
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
    bobRes.example.headerOk = all(bobNom.headerOk);
    bobRes.example.thresholdCalibration = bobRes.thresholdCalibration;
end

% -------- Eve --------
eveRes = struct();
if ~eveEnabled
    return;
end

sessionEve = local_init_rx_session_local(p, metaTx, nPackets);
payloadFrameEve = zeros(totalPayloadBitsTx, 1, "uint8");
packetOkEve = false(1, nPackets);
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
        rData = fit_complex_length_local(eveNom.rDataPrepared{pktIdx}, rxState.nDataSym);
        reliabilityEve = [];
        if isfield(eveNom, "rDataReliability") && numel(eveNom.rDataReliability) >= pktIdx ...
                && ~isempty(eveNom.rDataReliability{pktIdx})
            reliabilityEve = local_fit_reliability_length_local(eveNom.rDataReliability{pktIdx}, rxState.nDataSym);
        end
        scrambleCfgEve = eve_scramble_cfg_local(rxState.scrambleCfg, scrambleAssumptionEve);

        demodSoftEve = demodulate_to_softbits(rData, p.mod, p.fec, p.softMetric, reliabilityEve);
        demodDeintEve = deinterleave_bits(demodSoftEve, rxState.intState, p.interleaver);
        dataBitsEveScr = fec_decode(demodDeintEve, p.fec);
        packetDataBitsEve = descramble_bits(dataBitsEveScr, scrambleCfgEve);
        packetDataBitsEve = fit_bits_length(packetDataBitsEve, rxState.packetDataBitsLen);

        [payloadPktEve, sessionNext, packetInfo, okPacket] = recover_payload_packet_local(packetDataBitsEve, phy, sessionEve, p);
        if okPacket
            sessionEve = sessionNext;
            if packetInfo.packetIndex == txPktIndex(pktIdx)
                txBits = txPayload;
                nCompare = min(numel(payloadPktEve), numel(txBits));
                if nCompare > 0
                    nErrEve = nErrEve + sum(payloadPktEve(1:nCompare) ~= txBits(1:nCompare));
                end
                if numel(payloadPktEve) < numel(txBits)
                    nErrEve = nErrEve + (numel(txBits) - numel(payloadPktEve));
                end
                nTotEve = nTotEve + numel(txBits);
            else
                nErrEve = nErrEve + numel(txPayload);
                nTotEve = nTotEve + numel(txPayload);
            end

            payloadFrameEve(packetInfo.range.startBit:packetInfo.range.endBit) = fit_bits_length(payloadPktEve, packetInfo.range.nBits);
            packetOkEve(packetInfo.packetIndex) = true;
        else
            nErrEve = nErrEve + numel(txPayload);
            nTotEve = nTotEve + numel(txPayload);
        end
    else
        nErrEve = nErrEve + numel(txPayload);
        nTotEve = nTotEve + numel(txPayload);
    end
end

metaEveUse = metaTx;
totalPayloadBitsEve = totalPayloadBitsTx;
if isfield(sessionEve, "known") && sessionEve.known
    metaEveUse = sessionEve.meta;
    totalPayloadBitsEve = sessionEve.totalPayloadBits;
end
rxLayoutEve = derive_packet_layout_local(totalPayloadBitsEve, p);

if packetIndependentBitChaos && chaosEnabled && chaosAssumptionEve ~= "none"
    payloadBitsEveDec = decrypt_payload_packets_rx_local( ...
        payloadFrameEve, packetOkEve, p, totalPayloadBitsEve, chaosAssumptionEve, chaosApproxDeltaEve);
    imgEveComm = payload_bits_to_image(payloadBitsEveDec, metaEveUse, p.payload);
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
    eveRes.example.imgRxComm = imgEveComm;
    eveRes.example.imgRxCompensated = imgEveComp;
    eveRes.example.imgRx = imgEveComp;
    eveRes.example.headerOk = all(eveNom.headerOk);
    eveRes.example.thresholdCalibration = eveRes.thresholdCalibration;
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
[refSym, ~] = modulate_bits(codedBitsInt, p.mod);
refSym = fit_complex_length_local(refSym, rxState.nDataSym);
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

function yPrep = local_prepare_data_symbols_local(rData, rxState, hopInfoUsed, modCfg, rxSyncCfg, fhEnabled)
% Prepare per-packet data symbols (dehop -> carrier PLL).
%
% Multipath equalization has already been applied at the nominal Rx stage on
% the full [preamble; PHY; data] block to avoid edge transients. Here we only
% apply the hop derotation and the (optional) carrier PLL once per packet.
r = fit_complex_length_local(rData, rxState.nDataSym);

if fhEnabled
    r = fh_demodulate(r, hopInfoUsed);
end

if isfield(rxSyncCfg, "carrierPll") && isfield(rxSyncCfg.carrierPll, "enable") ...
        && rxSyncCfg.carrierPll.enable
    r = carrier_pll_sync(r, modCfg, rxSyncCfg.carrierPll);
end

yPrep = r;
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
nom.session = local_init_session_nominal_local(nSessionFrames);
end

function nom = local_init_session_nominal_local(nFrames)
nom = struct();
nom.ok = false(nFrames, 1);
nom.rDataPrepared = cell(nFrames, 1);
nom.rDataReliability = cell(nFrames, 1);
nom.preambleRx = cell(nFrames, 1);
nom.preambleRef = cell(nFrames, 1);
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
    rx = pulse_rx_to_symbol_rate(rx, waveform);
    sessionRx{frameIdx} = rx;
end
end

function nom = local_build_packet_nominal_local(rawCapture, txPackets, sessionFrames, methodName, mitigation, syncCfgUse, rxSyncCfg, p, waveform, N0, fhEnabled, fhAssumption)
nPackets = numel(txPackets);
nom = local_init_packet_nominal_local(nPackets, numel(sessionFrames));
nom.session = local_build_session_nominal_local( ...
    rawCapture.sessionRx, sessionFrames, methodName, mitigation, syncCfgUse, rxSyncCfg, p, waveform, N0);

for pktIdx = 1:nPackets
    if numel(rawCapture.rxPackets) < pktIdx || isempty(rawCapture.rxPackets{pktIdx})
        continue;
    end
    rxRaw = rawCapture.rxPackets{pktIdx};
    [rxMit, reliability] = mitigate_impulses(rxRaw, methodName, mitigation);

    syncSymRef = txPackets(pktIdx).syncSym(:);
    [startIdx, rxSync] = frame_sync(rxMit, syncSymRef, syncCfgUse);
    if isempty(startIdx)
        continue;
    end

    preLen = numel(syncSymRef);
    hdrLen = numel(txPackets(pktIdx).phyHeaderSym);
    dataLen = numel(txPackets(pktIdx).dataSymTx);
    totalLen = preLen + hdrLen + dataLen;
    [rFull, okFull] = extract_fractional_block(rxSync, startIdx, totalLen, syncCfgUse, p.mod);
    if ~okFull
        continue;
    end
    reliabilityFull = local_extract_reliability_block_local(reliability, startIdx, totalLen);

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

    hdrSym = rFull(preLen+1:preLen+hdrLen);
    hdrBits = decode_phy_header_symbols(hdrSym, p.frame, p.fec, p.softMetric);
    [phy, headerOk] = parse_phy_header_bits(hdrBits, p.frame);
    nom.headerOk(pktIdx) = headerOk;
    if ~headerOk
        continue;
    end

    rxState = derive_rx_packet_state_local( ...
        p, double(phy.packetIndex), local_packet_data_bits_len_from_header_local(p, double(phy.packetIndex), phy));
    if fhEnabled
        hopInfoUsed = local_nominal_hop_info_local(rxState, fhAssumption);
    else
        hopInfoUsed = struct("enable", false);
    end

    rData = rFull(preLen+hdrLen+1:end);
    rDataRel = reliabilityFull(preLen+hdrLen+1:end);
    nom.phy(pktIdx) = phy;
    nom.rxState{pktIdx} = rxState;
    nom.rDataPrepared{pktIdx} = local_prepare_data_symbols_local( ...
        rData, rxState, hopInfoUsed, p.mod, rxSyncCfg, fhEnabled);
    nom.rDataReliability{pktIdx} = local_fit_reliability_length_local(rDataRel, rxState.nDataSym);
    nom.ok(pktIdx) = true;
end
end

function nom = local_build_session_nominal_local(sessionRx, sessionFrames, methodName, mitigation, syncCfgUse, rxSyncCfg, p, waveform, N0)
nom = local_init_session_nominal_local(numel(sessionFrames));
if isempty(sessionFrames)
    return;
end

for frameIdx = 1:numel(sessionFrames)
    if numel(sessionRx) < frameIdx || isempty(sessionRx{frameIdx})
        continue;
    end

    sessionFrame = sessionFrames(frameIdx);
    [rxMit, reliability] = mitigate_impulses(sessionRx{frameIdx}, methodName, mitigation);
    [startIdx, rxSync] = frame_sync(rxMit, sessionFrame.syncSym(:), syncCfgUse);
    if isempty(startIdx)
        continue;
    end

    preLen = numel(sessionFrame.syncSym);
    totalLen = preLen + sessionFrame.nDataSym;
    [rFull, okFull] = extract_fractional_block(rxSync, startIdx, totalLen, syncCfgUse, sessionFrame.modCfg);
    if ~okFull
        continue;
    end
    reliabilityFull = local_extract_reliability_block_local(reliability, startIdx, totalLen);

    if local_multipath_eq_enabled_local(p.channel, rxSyncCfg)
        chLenSymbols = local_multipath_channel_len_symbols_local(p.channel, waveform);
        eqCfg = rxSyncCfg.multipathEq;
        [eq, eqOk] = multipath_equalizer_from_preamble(sessionFrame.syncSym(:), rFull(1:preLen), eqCfg, N0, chLenSymbols);
        if eqOk
            rFull = local_apply_equalizer_block_local(rFull, eq);
        end
    end

    rxStateSession = struct("nDataSym", sessionFrame.nDataSym);
    nom.preambleRx{frameIdx} = fit_complex_length_local(rFull(1:preLen), preLen);
    nom.preambleRef{frameIdx} = sessionFrame.syncSym(:);
    nom.rDataPrepared{frameIdx} = local_prepare_data_symbols_local( ...
        rFull(preLen+1:end), rxStateSession, struct("enable", false), sessionFrame.modCfg, rxSyncCfg, false);
    nom.rDataReliability{frameIdx} = local_fit_reliability_length_local( ...
        reliabilityFull(preLen+1:end), sessionFrame.nDataSym);
    nom.ok(frameIdx) = true;
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

    rData = fit_complex_length_local(sessionNom.rDataPrepared{frameIdx}, sessionFrames(frameIdx).nDataSym);
    reliability = [];
    if isfield(sessionNom, "rDataReliability") && numel(sessionNom.rDataReliability) >= frameIdx ...
            && ~isempty(sessionNom.rDataReliability{frameIdx})
        reliability = local_fit_reliability_length_local(sessionNom.rDataReliability{frameIdx}, sessionFrames(frameIdx).nDataSym);
    end
    [metaSession, okFrame] = local_try_decode_session_frame_local(rData, reliability, sessionFrames(frameIdx), p);
    if okFrame
        sessionOut = learn_rx_session_local(metaSession);
        return;
    end

    rMitList{end+1, 1} = fit_complex_length_local(rData, sessionFrames(frameIdx).nDataSym); %#ok<AGROW>
end

if numel(rMitList) >= 2
    rCombined = local_average_session_symbols_local(rMitList);
    [metaSession, okFrame] = local_try_decode_session_frame_local(rCombined, [], sessionFrames(1), p);
    if okFrame
        sessionOut = learn_rx_session_local(metaSession);
    end
end
end

function [metaSession, ok] = local_try_decode_session_frame_local(rData, reliability, sessionFrame, p)
metaSession = struct();
ok = false;

switch string(sessionFrame.decodeKind)
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

sessionBits = fit_bits_length(sessionBits, sessionFrame.infoBitsLen);
[metaSession, ~, ok] = parse_session_header_bits(sessionBits, p.frame);
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

function rate = local_nominal_success_rate_local(nom)
rate = 0;
if isfield(nom, "ok") && ~isempty(nom.ok)
    rate = mean(double(nom.ok));
end
end

function session = rx_session_empty_local()
session = struct();
session.known = false;
session.totalPayloadBits = NaN;
session.totalPackets = NaN;
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
session.meta = metaRx;
end

function metaOut = local_preshared_session_meta_local(metaTx, nPackets)
metaOut = metaTx;
metaOut.totalPayloadBytes = uint32(metaTx.payloadBytes);
metaOut.totalPackets = uint16(nPackets);
end

function state = derive_rx_packet_state_local(p, pktIdx, packetDataBitsLen)
if nargin < 3 || isempty(packetDataBitsLen) || ~isfinite(packetDataBitsLen)
    packetDataBitsLen = local_fixed_packet_data_bits_len_local(p, pktIdx);
end
packetDataBitsLen = max(0, round(double(packetDataBitsLen)));
bitsPerSym = bits_per_symbol_local(p.mod);
codedBitsLen = coded_bits_length_local(packetDataBitsLen, p.fec);
[~, intState] = interleave_bits(zeros(codedBitsLen, 1, "uint8"), p.interleaver);
nDataSym = ceil(codedBitsLen / bitsPerSym);
offsets = derive_packet_state_offsets(p, pktIdx);

state = struct();
state.packetIndex = pktIdx;
state.packetDataBitsLen = packetDataBitsLen;
state.packetDataBytes = ceil(packetDataBitsLen / 8);
state.codedBitsLen = codedBitsLen;
state.nDataSym = nDataSym;
state.intState = intState;
state.stateOffsets = offsets;
state.scrambleCfg = derive_packet_scramble_cfg(p.scramble, pktIdx, offsets.scrambleOffsetBits);
state.fhCfg = derive_packet_fh_cfg(p.fh, pktIdx, offsets.fhOffsetHops, nDataSym);
state.hopInfo = hop_info_from_fh_cfg_local(state.fhCfg, nDataSym);
end

function [payloadPktRx, sessionOut, packetInfo, ok] = recover_payload_packet_local(packetDataBitsRx, phyHeader, sessionIn, p)
payloadPktRx = uint8([]);
sessionOut = sessionIn;
packetInfo = struct();
packetInfo.packetIndex = double(phyHeader.packetIndex);
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

packetInfo.packetIndex = packetIndex;
packetInfo.range = derive_packet_range_from_meta_local(sessionOut.meta, packetIndex, p);
if packetInfo.range.nBits <= 0
    ok = false;
    return;
end
payloadPktRx = fit_bits_length(payloadPktRx, packetInfo.range.nBits);
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
fields = ["rows", "cols", "channels", "bitsPerPixel", "totalPayloadBytes", "totalPackets"];
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
totalPackets = double(metaRx.totalPackets);
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
numInputBits = log2(fec.trellis.numInputSymbols);
numOutputBits = log2(fec.trellis.numOutputSymbols);
nBits = round(double(nInfoBits) * numOutputBits / numInputBits);
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
    "ebN0dB", baseBudget.ebN0dB + offsetDb);
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

function eveCfg = local_validate_eve_config_local(eveCfg, methodsMain)
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
    "fftNotch", "adaptiveNotch", "thresholdCalibration", ...
    "strictModelLoad", "requireTrainedModels", "ml", "mlCnn", "mlGru"], "eve.mitigation");
local_require_struct_fields_local(eveCfg.mitigation.thresholdCalibration, [ ...
    "enable", "methods", "targetCleanPfa", "thresholdMinScale", ...
    "thresholdMaxScale", "minThresholdAbs", "maxThresholdAbs", ...
    "bufferMaxSamples", "minBufferSamples", "minPreambleTrustedSamples", ...
    "minPacketTrustedSamples", "preambleUpdateAlpha", "packetUpdateAlpha", ...
    "preambleResidualAlpha", "packetResidualAlpha"], "eve.mitigation.thresholdCalibration");

methodsEve = string(eveCfg.mitigation.methods(:).');
if ~isequal(methodsEve, methodsMain)
    error("eve.mitigation.methods 必须与 p.mitigation.methods 完全一致。");
end
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
