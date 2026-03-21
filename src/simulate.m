function results = simulate(p)
%SIMULATE  端到端链路仿真，包含脉冲噪声抑制。
%
% 输入:
%   p - 仿真参数结构体（建议由default_params()生成）
%       .rngSeed, .sim, .source, .chaosEncrypt, .payload, .waveform
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
waveform = resolve_waveform_cfg(p);

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

%% 仿真参数初始化与配置

EbN0dBList = p.sim.ebN0dBList(:).';%仿真不同Eb/N0点，列向量
methods = string(p.mitigation.methods(:).');%仿真不同脉冲噪声抑制方法，列向量

ber = nan(numel(methods), numel(EbN0dBList)); %比特错误率（BER）统计
packetFrontEndBobVals = nan(1, numel(EbN0dBList));
packetHeaderBobVals = nan(1, numel(EbN0dBList));
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


example = struct();
if isfield(p.sim, "exampleEbN0dB") && ~isempty(p.sim.exampleEbN0dB)
    exampleEbN0 = double(p.sim.exampleEbN0dB);
    if isfinite(exampleEbN0)
        [~, exampleIdx] = min(abs(EbN0dBList - exampleEbN0));
    elseif exampleEbN0 > 0
        exampleIdx = numel(EbN0dBList);
    else
        exampleIdx = 1;
    end
else
    exampleIdx = numel(EbN0dBList);
end %示例图默认取最高Eb/N0点；设为具体值时取最近点

eveEnabled = isfield(p, "eve") && isfield(p.eve, "enable") && p.eve.enable;
scrambleAssumptionEve = "known";
fhAssumptionEve = "known";
chaosAssumptionEve = "none";
chaosEncInfoEve = struct('enabled', false, 'mode', "none");
eveEbN0dBList = [];
if eveEnabled
    if ~isfield(p.eve, "ebN0dBOffset"); p.eve.ebN0dBOffset = -6; end
    if ~isfield(p.eve, "scrambleAssumption"); p.eve.scrambleAssumption = "wrong_key"; end

    eveEbN0dBList = EbN0dBList + double(p.eve.ebN0dBOffset);
    berEve = nan(numel(methods), numel(EbN0dBList));
    packetFrontEndEveVals = nan(1, numel(EbN0dBList));
    packetHeaderEveVals = nan(1, numel(EbN0dBList));
    packetSuccessEveVals = nan(numel(methods), numel(EbN0dBList));
    mseCommEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrCommEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimCommEveVals = nan(numel(methods), numel(EbN0dBList));
    mseCompEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrCompEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimCompEveVals = nan(numel(methods), numel(EbN0dBList));
    exampleEve = struct();

    scrambleAssumptionEve = lower(string(p.eve.scrambleAssumption));
    switch scrambleAssumptionEve
        case {"known", "none", "wrong_key"}
            % 有效配置
        otherwise
            error("Unknown eve.scrambleAssumption: %s", string(p.eve.scrambleAssumption));
    end

    % Eve对跳频的知识（具体每包序列在后面统一预计算）
    if ~isfield(p.eve, 'fhAssumption'); p.eve.fhAssumption = "none"; end
    fhAssumptionEve = lower(string(p.eve.fhAssumption));
    switch fhAssumptionEve
        case {"known", "none", "partial"}
            % 有效配置
        otherwise
            error("Unknown eve.fhAssumption: %s", string(p.eve.fhAssumption));
    end

    % Eve对混沌加密的知识
    if ~isfield(p.eve, 'chaosAssumption'); p.eve.chaosAssumption = "none"; end
    chaosAssumptionEve = lower(string(p.eve.chaosAssumption));
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
        case "wrong_key"
            if chaosEnabled
                if packetIndependentBitChaos
                    chaosEncInfoEve = struct('enabled', true, 'mode', "payload_bits_packet");
                else
                    % Eve使用错误的混沌密钥
                    chaosEncInfoEve = chaosEncInfo;
                    chaosEncInfoEve.chaosParams.x0 = chaosEncInfo.chaosParams.x0 + 1e-10;  % 微小扰动
                end
            else
                chaosEncInfoEve = struct('enabled', false);
            end
        otherwise
            error("Unknown eve.chaosAssumption: %s", string(p.eve.chaosAssumption));
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
    [wardenEbN0dBList, wardenReferenceLink] = local_resolve_warden_ebn0_list( ...
        EbN0dBList, eveEnabled, eveEbN0dBList, p.covert.warden);
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
fprintf('[SIM] Eb/N0点数=%d, 每点帧数=%d, 总帧数=%d\n', ...
    totalEbN0Points, p.sim.nFramesPerPoint, totalFrames);
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
dllEnabled = isfield(p.rxSync, "timingDll") && isfield(p.rxSync.timingDll, "enable") ...
    && p.rxSync.timingDll.enable;
syncEnabled = p.rxSync.compensateCarrier || p.rxSync.fineSearchRadius > 0 || ...
    p.rxSync.enableFractionalTiming || p.rxSync.carrierPll.enable || dllEnabled;
mpEnabled = isfield(p.channel, "multipath") && isfield(p.channel.multipath, "enable") && p.channel.multipath.enable;
if waveform.enable
    pulseTxt = sprintf('ON(sps=%d)', waveform.sps);
else
    pulseTxt = 'OFF';
end
fprintf('[SIM] Eve=%s, Warden=%s, FH=%s, Chaos=%s, Pulse=%s, RxSync=%s, MP=%s\n', ...
    on_off_text(eveEnabled), on_off_text(wardenEnabled), on_off_text(fhEnabled), ...
    on_off_text(chaosEnabled), pulseTxt, on_off_text(syncEnabled), on_off_text(mpEnabled));
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
    EbN0 = 10.^(EbN0dB/10);
    N0 = ebn0_to_n0(EbN0, modInfo.codeRate, modInfo.bitsPerSymbol, 1.0);
    [klSigVsNoise(ie), klNoiseVsSig(ie), klSym(ie)] = signal_noise_kl(txSymForChannel, N0, 128);

    fprintf('[SIM] >>> Eb/N0点 %d/%d: %.2f dB\n', ie, totalEbN0Points, EbN0dB);

    if eveEnabled
        EbN0dBEve = EbN0dB + double(p.eve.ebN0dBOffset);
        EbN0Eve = 10.^(EbN0dBEve/10);
        N0Eve = ebn0_to_n0(EbN0Eve, modInfo.codeRate, modInfo.bitsPerSymbol, 1.0);
        fprintf('[SIM]     Eve等效Eb/N0: %.2f dB\n', EbN0dBEve);
    end

    if wardenEnabled
        EbN0dBWarden = wardenEbN0dBList(ie);
        EbN0Warden = 10.^(EbN0dBWarden / 10);
        N0Warden = ebn0_to_n0(EbN0Warden, modInfo.codeRate, modInfo.bitsPerSymbol, 1.0);
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
        det = warden_energy_detector(txSymForChannel, N0Warden, channelSample, maxDelaySamples, wardenCfg);
        clear wardenRngScope
        wardenPointDetections{ie} = det;
    end


    nErr = zeros(numel(methods), 1);
    nTot = zeros(numel(methods), 1);
    packetFrontEndBobAcc = 0;
    packetHeaderBobAcc = 0;
    packetSuccessBobAcc = zeros(numel(methods), 1);
    metricAccComm = init_image_metric_acc_local(numel(methods));
    metricAccComp = init_image_metric_acc_local(numel(methods));


    if eveEnabled
        nErrEve = zeros(numel(methods), 1);
        nTotEve = zeros(numel(methods), 1);
        packetFrontEndEveAcc = 0;
        packetHeaderEveAcc = 0;
        packetSuccessEveAcc = zeros(numel(methods), 1);
        metricAccCommEve = init_image_metric_acc_local(numel(methods));
        metricAccCompEve = init_image_metric_acc_local(numel(methods));
    end

    % --- 帧循环：每个Eb/N0点仿真多帧 ---
    totalPayloadBits = numel(payloadBits);
    for frameIdx = 1:p.sim.nFramesPerPoint
        globalFrameIdx = globalFrameIdx + 1;
        syncCfgUse = p.rxSync;
        if ~isfield(syncCfgUse, "minSearchIndex"); syncCfgUse.minSearchIndex = 1; end
        if ~isfield(syncCfgUse, "maxSearchIndex") || ~isfinite(double(syncCfgUse.maxSearchIndex))
            mpExtra = 0;
            if isfield(p, "channel") && isfield(p.channel, "multipath") ...
                    && isfield(p.channel.multipath, "enable") && p.channel.multipath.enable ...
                    && ( ...
                        (isfield(p.channel.multipath, "pathDelaysSymbols") && ~isempty(p.channel.multipath.pathDelaysSymbols)) || ...
                        (isfield(p.channel.multipath, "pathDelays") && ~isempty(p.channel.multipath.pathDelays)) )
                if isfield(p.channel.multipath, "pathDelaysSymbols") && ~isempty(p.channel.multipath.pathDelaysSymbols)
                    mpExtra = max(double(p.channel.multipath.pathDelaysSymbols(:)));
                else
                    mpExtra = max(double(p.channel.multipath.pathDelays(:)));
                end
            end
            if isfield(p, "channel") && isfield(p.channel, "maxDelaySymbols")
                syncCfgUse.maxSearchIndex = double(p.channel.maxDelaySymbols) + mpExtra + 6;
            else
                syncCfgUse.maxSearchIndex = inf;
            end
        end

        if p.sim.nFramesPerPoint <= 20 || frameIdx == 1 || frameIdx == p.sim.nFramesPerPoint || mod(frameIdx, frameLogStep) == 0
            fprintf('[SIM]     帧 %d/%d (总进度 %d/%d, %.1f%%)\n', ...
                frameIdx, p.sim.nFramesPerPoint, globalFrameIdx, totalFrames, ...
                100 * globalFrameIdx / max(totalFrames, 1));
        end

        % 当前帧：先做一次“同步+PHY提取”（所有方法共享），再按方法解调/译码（可并行）。
        phyHeaderTemplate = empty_phy_header_local();
        bobNom = struct();
        bobNom.ok = false(nPackets, 1);
        bobNom.headerOk = false(nPackets, 1);
        bobNom.phy = repmat(phyHeaderTemplate, nPackets, 1);
        bobNom.rxState = cell(nPackets, 1);
        bobNom.rData = cell(nPackets, 1);
        bobNom.rDataPrepared = cell(nPackets, 1);
        bobNom.preambleRx = cell(nPackets, 1);
        bobNom.preambleRef = cell(nPackets, 1);

        eveNom = struct();
        if eveEnabled
            eveNom.ok = false(nPackets, 1);
            eveNom.headerOk = false(nPackets, 1);
            eveNom.phy = repmat(phyHeaderTemplate, nPackets, 1);
            eveNom.rxState = cell(nPackets, 1);
            eveNom.rData = cell(nPackets, 1);
            eveNom.rDataPrepared = cell(nPackets, 1);
            eveNom.preambleRx = cell(nPackets, 1);
            eveNom.preambleRef = cell(nPackets, 1);
        end

        % ============ 分包发收（同步+PHY提取） ============
        phyHeaderSymLen = phy_header_symbol_length(p.frame, p.fec);
        bobSyncCtrl = init_packet_sync_ctrl_local();
        if eveEnabled
            eveSyncCtrl = init_packet_sync_ctrl_local();
        end
        frameDelaySym = randi([0, p.channel.maxDelaySymbols], 1, 1);
        frameDelay = round(double(frameDelaySym) * waveform.sps);
        channelSampleBob = local_freeze_channel_realization_local(channelSample);
        if eveEnabled
            channelSampleEve = local_freeze_channel_realization_local(channelSample);
        end

        for pktIdx = 1:nPackets
            pkt = txPackets(pktIdx);

            % 同一帧内固定传播时延，避免每个分包都经历一次新的起始时刻跳变。
            tx = [zeros(frameDelay, 1); pkt.txSymForChannel];

            rx = channel_bg_impulsive(tx, N0, channelSampleBob);
            rx = pulse_rx_to_symbol_rate(rx, waveform);

            if eveEnabled
                rxEve = channel_bg_impulsive(tx, N0Eve, channelSampleEve);
                rxEve = pulse_rx_to_symbol_rate(rxEve, waveform);
            end

            bobPhy = phyHeaderTemplate;
            rxStateBobNominal = [];
            rDataBobNominal = complex(zeros(0, 1));
            rPreBobNominal = complex(zeros(0, 1));
            bobHeaderOk = false;
            [startIdx, rxBobSync, syncSymBob, bobSyncCtrl, bobOk] = acquire_packet_sync_local(rx, syncCfgUse, p, pktIdx, firstSyncSym, shortSyncSym, bobSyncCtrl);
            if bobOk
                preLen = numel(syncSymBob);
                [rPreBob, preOk] = extract_fractional_block(rxBobSync, startIdx, preLen, syncCfgUse, struct('type', 'BPSK'));
                if preOk
                    rPreBobNominal = rPreBob;
                end
                phyStart = startIdx + preLen;
                [rPhyBobRaw, bobOk] = extract_fractional_block(rxBobSync, phyStart, phyHeaderSymLen, syncCfgUse, struct('type', 'BPSK'));

                % 多径信道估计 + 线性均衡（先救PHY头，避免“整包判失败”导致BER饱和）
                eqBob = struct();
                eqBobOk = false;
                rPhyBob = rPhyBobRaw;
                if bobOk && preOk && local_multipath_eq_enabled_local(p)
                    chLenSymbols = local_multipath_channel_len_symbols_local(p.channel, waveform);
                    eqCfg = p.rxSync.multipathEq;
                    [eqBob, eqBobOk] = multipath_equalizer_from_preamble(syncSymBob(:), rPreBob, eqCfg, N0, chLenSymbols);
                    if eqBobOk
                        yPrePhy = [rPreBob; rPhyBobRaw];
                        yEq = local_apply_equalizer_block_local(yPrePhy, eqBob);
                        rPreBobNominal = yEq(1:preLen);
                        rPhyBob = yEq(preLen+1:end);
                    end
                end

                if bobOk
                    bobPhyBits = decode_phy_header_symbols(rPhyBob, p.frame, p.fec, p.softMetric);
                    [bobPhyParsed, bobOk] = parse_phy_header_bits(bobPhyBits, p.frame);
                    if bobOk
                        bobPhy = bobPhyParsed;
                        bobHeaderOk = true;
                    end
                end
                if bobOk
                    rxStateBobNominal = derive_rx_packet_state_local( ...
                        p, double(bobPhy.packetIndex), local_packet_data_bits_len_from_header_local(p, double(bobPhy.packetIndex), bobPhy));
                    dataStart = phyStart + phyHeaderSymLen;
                    [rDataBobRaw, bobOk] = extract_fractional_block(rxBobSync, dataStart, rxStateBobNominal.nDataSym, syncCfgUse, p.mod);
                    if bobOk && eqBobOk
                        yAll = [rPreBob; rPhyBobRaw; rDataBobRaw];
                        yEqAll = local_apply_equalizer_block_local(yAll, eqBob);
                        rDataBobNominal = yEqAll(preLen + phyHeaderSymLen + 1:end);
                    else
                        rDataBobNominal = rDataBobRaw;
                    end
                end
            end
            bobNom.ok(pktIdx) = bobOk;
            bobNom.headerOk(pktIdx) = bobHeaderOk;
            if bobOk
                bobNom.phy(pktIdx) = bobPhy;
                bobNom.rxState{pktIdx} = rxStateBobNominal;
                bobNom.rData{pktIdx} = [];
                if ~isempty(rPreBobNominal)
                    bobNom.preambleRx{pktIdx} = fit_complex_length_local(rPreBobNominal, numel(syncSymBob));
                    bobNom.preambleRef{pktIdx} = syncSymBob(:);
                end
                hopInfoBob = struct('enable', false);
                if fhEnabled && isfield(rxStateBobNominal, "hopInfo")
                    hopInfoBob = rxStateBobNominal.hopInfo;
                end
                bobNom.rDataPrepared{pktIdx} = local_prepare_data_symbols_local( ...
                    rDataBobNominal, rxStateBobNominal, hopInfoBob, p, fhEnabled);
            end

            if eveEnabled
                eveOk = false;
                evePhy = phyHeaderTemplate;
                rxStateEveNominal = [];
                rDataEveNominal = complex(zeros(0, 1));
                rPreEveNominal = complex(zeros(0, 1));
                eveHeaderOk = false;
                [startIdxEve, rxEveSync, syncSymEve, eveSyncCtrl, eveOk] = acquire_packet_sync_local(rxEve, syncCfgUse, p, pktIdx, firstSyncSym, shortSyncSym, eveSyncCtrl);
                if eveOk
                    preLenEve = numel(syncSymEve);
                    [rPreEve, preOkEve] = extract_fractional_block(rxEveSync, startIdxEve, preLenEve, syncCfgUse, struct('type', 'BPSK'));
                    if preOkEve
                        rPreEveNominal = rPreEve;
                    end
                    phyStartEve = startIdxEve + preLenEve;
                    [rPhyEveRaw, eveOk] = extract_fractional_block(rxEveSync, phyStartEve, phyHeaderSymLen, syncCfgUse, struct('type', 'BPSK'));

                    eqEve = struct();
                    eqEveOk = false;
                    rPhyEve = rPhyEveRaw;
                    if eveOk && preOkEve && local_multipath_eq_enabled_local(p)
                        chLenSymbols = local_multipath_channel_len_symbols_local(p.channel, waveform);
                        eqCfg = p.rxSync.multipathEq;
                        [eqEve, eqEveOk] = multipath_equalizer_from_preamble(syncSymEve(:), rPreEve, eqCfg, N0Eve, chLenSymbols);
                        if eqEveOk
                            yPrePhy = [rPreEve; rPhyEveRaw];
                            yEq = local_apply_equalizer_block_local(yPrePhy, eqEve);
                            rPreEveNominal = yEq(1:preLenEve);
                            rPhyEve = yEq(preLenEve+1:end);
                        end
                    end

                    if eveOk
                        evePhyBits = decode_phy_header_symbols(rPhyEve, p.frame, p.fec, p.softMetric);
                        [evePhyParsed, eveOk] = parse_phy_header_bits(evePhyBits, p.frame);
                        if eveOk
                            evePhy = evePhyParsed;
                            eveHeaderOk = true;
                        end
                    end
                    if eveOk
                        rxStateEveNominal = derive_rx_packet_state_local( ...
                            p, double(evePhy.packetIndex), local_packet_data_bits_len_from_header_local(p, double(evePhy.packetIndex), evePhy));
                        dataStartEve = phyStartEve + phyHeaderSymLen;
                        [rDataEveRaw, eveOk] = extract_fractional_block(rxEveSync, dataStartEve, rxStateEveNominal.nDataSym, syncCfgUse, p.mod);
                        if eveOk && eqEveOk
                            yAll = [rPreEve; rPhyEveRaw; rDataEveRaw];
                            yEqAll = local_apply_equalizer_block_local(yAll, eqEve);
                            rDataEveNominal = yEqAll(preLenEve + phyHeaderSymLen + 1:end);
                        else
                            rDataEveNominal = rDataEveRaw;
                        end
                    end
                end
                eveNom.ok(pktIdx) = eveOk;
                eveNom.headerOk(pktIdx) = eveHeaderOk;
                if eveOk
                    eveNom.phy(pktIdx) = evePhy;
                    eveNom.rxState{pktIdx} = rxStateEveNominal;
                    eveNom.rData{pktIdx} = [];
                    if ~isempty(rPreEveNominal)
                        eveNom.preambleRx{pktIdx} = fit_complex_length_local(rPreEveNominal, numel(syncSymEve));
                        eveNom.preambleRef{pktIdx} = syncSymEve(:);
                    end
                    hopInfoEvePrep = struct('enable', false);
                    if fhEnabled
                        hopInfoEvePrep = eve_hop_info_local(rxStateEveNominal, fhAssumptionEve);
                    end
                    eveNom.rDataPrepared{pktIdx} = local_prepare_data_symbols_local( ...
                        rDataEveNominal, rxStateEveNominal, hopInfoEvePrep, p, fhEnabled);
                end
            end
        end
        packetFrontEndBobAcc = packetFrontEndBobAcc + mean(double(bobNom.ok));
        packetHeaderBobAcc = packetHeaderBobAcc + mean(double(bobNom.headerOk));
        if eveEnabled
            packetFrontEndEveAcc = packetFrontEndEveAcc + mean(double(eveNom.ok));
            packetHeaderEveAcc = packetHeaderEveAcc + mean(double(eveNom.headerOk));
        end

        % ============ 按方法解调/译码与统计（可并行） ============
        useParallelMethods = simUseParallel && simParallelMode == "methods";
        EbN0dBEveLocal = NaN;
        if eveEnabled
            EbN0dBEveLocal = EbN0dBEve;
        end
        captureExample = (frameIdx == 1 && ie == exampleIdx);
        [bobFrame, eveFrame] = local_decode_frame_methods_local( ...
            methods, txPktIndex, txPayloadBits, bobNom, eveNom, p, fhEnabled, ...
            packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
            packetConcealActive, packetConcealMode, imgTx, meta, totalPayloadBits, ...
            eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosEncInfoEve, ...
            captureExample, EbN0dB, EbN0dBEveLocal, useParallelMethods);

        nErr = nErr + bobFrame.nErr;
        nTot = nTot + bobFrame.nTot;
        packetSuccessBobAcc = packetSuccessBobAcc + bobFrame.packetSuccessRate;
        for im = 1:numel(methods)
            metricAccComm = accumulate_image_metric_acc_local(metricAccComm, im, ...
                bobFrame.metricsComm.mse(im), bobFrame.metricsComm.psnr(im), bobFrame.metricsComm.ssim(im));
            metricAccComp = accumulate_image_metric_acc_local(metricAccComp, im, ...
                bobFrame.metricsComp.mse(im), bobFrame.metricsComp.psnr(im), bobFrame.metricsComp.ssim(im));
            if captureExample && ~isempty(bobFrame.example{im})
                example.(methods(im)) = bobFrame.example{im};
            end
        end

        if eveEnabled
            nErrEve = nErrEve + eveFrame.nErr;
            nTotEve = nTotEve + eveFrame.nTot;
            packetSuccessEveAcc = packetSuccessEveAcc + eveFrame.packetSuccessRate;
            for im = 1:numel(methods)
                metricAccCommEve = accumulate_image_metric_acc_local(metricAccCommEve, im, ...
                    eveFrame.metricsComm.mse(im), eveFrame.metricsComm.psnr(im), eveFrame.metricsComm.ssim(im));
                metricAccCompEve = accumulate_image_metric_acc_local(metricAccCompEve, im, ...
                    eveFrame.metricsComp.mse(im), eveFrame.metricsComp.psnr(im), eveFrame.metricsComp.ssim(im));
                if captureExample && ~isempty(eveFrame.example{im})
                    exampleEve.(methods(im)) = eveFrame.example{im};
                end
            end
        end
    end

    % --- 当前Eb/N0点的性能统计 ---
    ber(:, ie) = nErr ./ max(nTot, 1);
    packetFrontEndBobVals(ie) = packetFrontEndBobAcc / p.sim.nFramesPerPoint;
    packetHeaderBobVals(ie) = packetHeaderBobAcc / p.sim.nFramesPerPoint;
    packetSuccessBobVals(:, ie) = packetSuccessBobAcc / p.sim.nFramesPerPoint;

    [mseOutComm, psnrOutComm, ssimOutComm] = finalize_image_metric_acc_local(metricAccComm);
    [mseOutComp, psnrOutComp, ssimOutComp] = finalize_image_metric_acc_local(metricAccComp);
    mseCommVals(:, ie) = mseOutComm;
    psnrCommVals(:, ie) = psnrOutComm;
    ssimCommVals(:, ie) = ssimOutComm;
    mseCompVals(:, ie) = mseOutComp;
    psnrCompVals(:, ie) = psnrOutComp;
    ssimCompVals(:, ie) = ssimOutComp;


    if eveEnabled
        berEve(:, ie) = nErrEve ./ max(nTotEve, 1);
        packetFrontEndEveVals(ie) = packetFrontEndEveAcc / p.sim.nFramesPerPoint;
        packetHeaderEveVals(ie) = packetHeaderEveAcc / p.sim.nFramesPerPoint;
        packetSuccessEveVals(:, ie) = packetSuccessEveAcc / p.sim.nFramesPerPoint;

        [mseOutCommEve, psnrOutCommEve, ssimOutCommEve] = finalize_image_metric_acc_local(metricAccCommEve);
        [mseOutCompEve, psnrOutCompEve, ssimOutCompEve] = finalize_image_metric_acc_local(metricAccCompEve);
        mseCommEveVals(:, ie) = mseOutCommEve;
        psnrCommEveVals(:, ie) = psnrOutCommEve;
        ssimCommEveVals(:, ie) = ssimOutCommEve;
        mseCompEveVals(:, ie) = mseOutCompEve;
        psnrCompEveVals(:, ie) = psnrOutCompEve;
        ssimCompEveVals(:, ie) = ssimOutCompEve;
    end

    fprintf('[SIM] <<< Eb/N0点 %.2f dB 完成, 用时 %.2fs\n', EbN0dB, toc(pointTic));
    fprintf('[SIM]     Bob BER: %s\n', format_metric_pairs(methods, ber(:, ie)));
    if eveEnabled
        fprintf('[SIM]     Eve BER: %s\n', format_metric_pairs(methods, berEve(:, ie)));
    end
    fprintf('\n');
end

%% 仿真评估与结果汇总（SIMULATION EVALUATION）
fprintf('[SIM] 开始频谱估计与结果汇总...\n');

% 波形/频谱（单次突发，无信道，基于真实发射采样波形）
[psd, freqHz, bw99Hz, etaBpsHz, spectrumInfo] = estimate_spectrum( ...
    txSymForChannel, modInfo, waveform, struct("payloadBits", numel(payloadBits)));

results = struct();
results.params = p;
results.ebN0dB = EbN0dBList;
results.methods = methods;
results.ber = ber;
results.packetDiagnostics = struct();
results.packetDiagnostics.bob = struct( ...
    "frontEndSuccessRate", packetFrontEndBobVals, ...
    "headerSuccessRate", packetHeaderBobVals, ...
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
    results.eve = struct();
    results.eve.ebN0dB = eveEbN0dBList;
    results.eve.ber = berEve;
    results.eve.packetDiagnostics = struct( ...
        "frontEndSuccessRate", packetFrontEndEveVals, ...
        "headerSuccessRate", packetHeaderEveVals, ...
        "payloadSuccessRate", packetSuccessEveVals);
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
    results.eve.scrambleAssumption = string(p.eve.scrambleAssumption);
end

if wardenEnabled
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

function [bobFrame, eveFrame] = local_decode_frame_methods_local( ...
    methods, txPktIndex, txPayloadBits, bobNom, eveNom, p, fhEnabled, ...
    packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
    packetConcealActive, packetConcealMode, imgTx, metaTx, totalPayloadBitsTx, ...
    eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosEncInfoEve, ...
    captureExample, EbN0dB, EbN0dBEve, useParallelMethods)

nMethods = numel(methods);
nPackets = numel(txPktIndex);

nErrBob = zeros(nMethods, 1);
nTotBob = zeros(nMethods, 1);
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
            [bobRes, eveRes] = local_decode_single_method_local( ...
                methods(im), txPktIndex, txPayloadBits, bobNom, eveNom, p, fhEnabled, ...
                packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
                packetConcealActive, packetConcealMode, imgTx, metaTx, totalPayloadBitsTx, ...
                eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosEncInfoEve, ...
                captureExample, EbN0dB, EbN0dBEve, nPackets);

            nErrBob(im) = bobRes.nErr;
            nTotBob(im) = bobRes.nTot;
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
        [bobRes, eveRes] = local_decode_single_method_local( ...
            methods(im), txPktIndex, txPayloadBits, bobNom, eveNom, p, fhEnabled, ...
            packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
            packetConcealActive, packetConcealMode, imgTx, metaTx, totalPayloadBitsTx, ...
            eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosEncInfoEve, ...
            captureExample, EbN0dB, EbN0dBEve, nPackets);

        nErrBob(im) = bobRes.nErr;
        nTotBob(im) = bobRes.nTot;
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
bobFrame.packetSuccessRate = packetSuccessBob;
bobFrame.metricsComm = struct("mse", mseCommBob, "psnr", psnrCommBob, "ssim", ssimCommBob);
bobFrame.metricsComp = struct("mse", mseCompBob, "psnr", psnrCompBob, "ssim", ssimCompBob);
bobFrame.example = exampleBob;

eveFrame = struct();
if eveEnabled
    eveFrame.nErr = nErrEve;
    eveFrame.nTot = nTotEve;
    eveFrame.packetSuccessRate = packetSuccessEve;
    eveFrame.metricsComm = struct("mse", mseCommEve, "psnr", psnrCommEve, "ssim", ssimCommEve);
    eveFrame.metricsComp = struct("mse", mseCompEve, "psnr", psnrCompEve, "ssim", ssimCompEve);
    eveFrame.example = exampleEve;
end
end

function [bobRes, eveRes] = local_decode_single_method_local( ...
    methodName, txPktIndex, txPayloadBits, bobNom, eveNom, p, fhEnabled, ...
    packetIndependentBitChaos, chaosEnabled, chaosEncInfo, ...
    packetConcealActive, packetConcealMode, imgTx, metaTx, totalPayloadBitsTx, ...
    eveEnabled, scrambleAssumptionEve, fhAssumptionEve, chaosAssumptionEve, chaosEncInfoEve, ...
    captureExample, EbN0dB, EbN0dBEve, nPackets)

% -------- Bob --------
sessionBob = local_init_rx_session_local(p, metaTx, nPackets);
payloadFrameBob = zeros(totalPayloadBitsTx, 1, "uint8");
packetOkBob = false(1, nPackets);
nErrBob = 0;
nTotBob = 0;
calStateBob = local_init_threshold_calibration_state_local(methodName, p.mitigation);

        for pktIdx = 1:nPackets
            txPayload = txPayloadBits{pktIdx};
            if bobNom.ok(pktIdx)
                phy = bobNom.phy(pktIdx);
                rxState = bobNom.rxState{pktIdx};
                if isempty(rxState)
                    rxState = derive_rx_packet_state_local( ...
                        p, double(phy.packetIndex), local_packet_data_bits_len_from_header_local(p, double(phy.packetIndex), phy));
                end
        rData = [];
        if isfield(bobNom, "rDataPrepared") && numel(bobNom.rDataPrepared) >= pktIdx && ~isempty(bobNom.rDataPrepared{pktIdx})
            rData = fit_complex_length_local(bobNom.rDataPrepared{pktIdx}, rxState.nDataSym);
        else
            rData = fit_complex_length_local(bobNom.rData{pktIdx}, rxState.nDataSym);
            if fhEnabled
                rData = fh_demodulate(rData, rxState.hopInfo);
            end
            if p.rxSync.carrierPll.enable
                rData = carrier_pll_sync(rData, p.mod, p.rxSync.carrierPll);
            end
        end

        calStateBob = local_update_threshold_from_preamble_local( ...
            calStateBob, bobNom.preambleRx{pktIdx}, bobNom.preambleRef{pktIdx});
        mitBob = local_apply_threshold_calibration_local(p.mitigation, calStateBob);
        [rMit, reliability] = mitigate_impulses(rData, methodName, mitBob);
        demodSoft = demodulate_to_softbits(rMit, p.mod, p.fec, p.softMetric, reliability);
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
            calStateBob = local_update_threshold_from_packet_local( ...
                calStateBob, rData, packetDataBitsRx, rxState.scrambleCfg, rxState, p);
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
    payloadBitsRxDec = decrypt_payload_packets_rx_local(payloadFrameBob, packetOkBob, p, totalPayloadBitsBob, "known");
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
    bobRes.example.frontEndSuccessRate = mean(double(bobNom.ok));
    bobRes.example.headerSuccessRate = mean(double(bobNom.headerOk));
    bobRes.example.imgRxComm = imgRxComm;
    bobRes.example.imgRxCompensated = imgRxComp;
    bobRes.example.imgRx = imgRxComp;
    bobRes.example.packetSuccessRate = bobRes.packetSuccessRate;
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
calStateEve = local_init_threshold_calibration_state_local(methodName, p.mitigation);

    for pktIdx = 1:nPackets
        txPayload = txPayloadBits{pktIdx};
        if eveNom.ok(pktIdx)
            phy = eveNom.phy(pktIdx);
            rxState = eveNom.rxState{pktIdx};
            if isempty(rxState)
                rxState = derive_rx_packet_state_local( ...
                    p, double(phy.packetIndex), local_packet_data_bits_len_from_header_local(p, double(phy.packetIndex), phy));
            end
        rData = [];
        if isfield(eveNom, "rDataPrepared") && numel(eveNom.rDataPrepared) >= pktIdx && ~isempty(eveNom.rDataPrepared{pktIdx})
            rData = fit_complex_length_local(eveNom.rDataPrepared{pktIdx}, rxState.nDataSym);
        else
            rData = fit_complex_length_local(eveNom.rData{pktIdx}, rxState.nDataSym);
            if fhEnabled
                hopInfoEve = eve_hop_info_local(rxState, fhAssumptionEve);
                rData = fh_demodulate(rData, hopInfoEve);
            end
            if p.rxSync.carrierPll.enable
                rData = carrier_pll_sync(rData, p.mod, p.rxSync.carrierPll);
            end
        end
        scrambleCfgEve = eve_scramble_cfg_local(rxState.scrambleCfg, scrambleAssumptionEve);

        calStateEve = local_update_threshold_from_preamble_local( ...
            calStateEve, eveNom.preambleRx{pktIdx}, eveNom.preambleRef{pktIdx});
        mitEve = local_apply_threshold_calibration_local(p.mitigation, calStateEve);
        [rMitEve, reliabilityEve] = mitigate_impulses(rData, methodName, mitEve);
        demodSoftEve = demodulate_to_softbits(rMitEve, p.mod, p.fec, p.softMetric, reliabilityEve);
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
            calStateEve = local_update_threshold_from_packet_local( ...
                calStateEve, rData, packetDataBitsEve, scrambleCfgEve, rxState, p);
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
    payloadBitsEveDec = decrypt_payload_packets_rx_local(payloadFrameEve, packetOkEve, p, totalPayloadBitsEve, chaosAssumptionEve);
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
    eveRes.example.frontEndSuccessRate = mean(double(eveNom.ok));
    eveRes.example.headerSuccessRate = mean(double(eveNom.headerOk));
    eveRes.example.packetSuccessRate = eveRes.packetSuccessRate;
    eveRes.example.imgRxComm = imgEveComm;
    eveRes.example.imgRxCompensated = imgEveComp;
    eveRes.example.imgRx = imgEveComp;
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

function tf = local_multipath_eq_enabled_local(p)
tf = false;
if ~isfield(p, "rxSync") || ~isstruct(p.rxSync) || ~isfield(p.rxSync, "multipathEq") ...
        || ~isstruct(p.rxSync.multipathEq) || ~isfield(p.rxSync.multipathEq, "enable") || ~p.rxSync.multipathEq.enable
    return;
end
if ~isfield(p, "channel") || ~isstruct(p.channel) || ~isfield(p.channel, "multipath") || ~isstruct(p.channel.multipath) ...
        || ~isfield(p.channel.multipath, "enable") || ~p.channel.multipath.enable
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

function yPrep = local_prepare_data_symbols_local(rData, rxState, hopInfoUsed, p, fhEnabled)
% Prepare per-packet data symbols (dehop -> carrier PLL).
%
% Multipath equalization has already been applied at the nominal Rx stage on
% the full [preamble; PHY; data] block to avoid edge transients. Here we only
% apply the hop derotation and the (optional) carrier PLL once per packet.
r = fit_complex_length_local(rData, rxState.nDataSym);

if fhEnabled
    r = fh_demodulate(r, hopInfoUsed);
end

if isfield(p, "rxSync") && isfield(p.rxSync, "carrierPll") && isfield(p.rxSync.carrierPll, "enable") ...
        && p.rxSync.carrierPll.enable
    r = carrier_pll_sync(r, p.mod, p.rxSync.carrierPll);
end

yPrep = r;
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
    allowSessionRefresh = (packetIndex == 1) || (is_long_sync_packet(p.frame, packetIndex) && repeat_session_header_on_resync_local(p.frame));
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

function payloadBitsOut = decrypt_payload_packets_rx_local(payloadBitsIn, packetOk, p, totalPayloadBits, assumption)
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
        infoUse = perturb_chaos_enc_info(infoUse, pktIdx);
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
    if ctrl.shortSyncMisses >= max_short_sync_misses_local(p.rxSync)
        ctrl.forceLongSearch = true;
    end
end
end

function tf = repeat_session_header_on_resync_local(frameCfg)
tf = false;
if isfield(frameCfg, "repeatSessionHeaderOnResync") && ~isempty(frameCfg.repeatSessionHeaderOnResync)
    tf = logical(frameCfg.repeatSessionHeaderOnResync);
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

function [wardenEbN0dBList, referenceLink] = local_resolve_warden_ebn0_list(bobEbN0dBList, eveEnabled, eveEbN0dBList, wardenCfg)
referenceLink = "bob";
if isfield(wardenCfg, "referenceLink")
    referenceLink = lower(string(wardenCfg.referenceLink));
end

switch referenceLink
    case "bob"
        wardenEbN0dBList = bobEbN0dBList;
    case "eve"
        if eveEnabled && ~isempty(eveEbN0dBList)
            wardenEbN0dBList = eveEbN0dBList;
        else
            referenceLink = "bob";
            wardenEbN0dBList = bobEbN0dBList;
        end
    case "independent"
        offsetDb = -10;
        if isfield(wardenCfg, "ebN0dBOffset")
            offsetDb = double(wardenCfg.ebN0dBOffset);
        end
        wardenEbN0dBList = bobEbN0dBList + offsetDb;
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
