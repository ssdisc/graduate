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

% 用于信道/频谱/监视者评估的整段突发
txSymForChannel = txPlan.txBurstForChannel;
txSymForSpectrum = txPlan.txBurstForSpectrum;
modInfo = txPlan.modInfo;

%% 仿真参数初始化与配置

EbN0dBList = p.sim.ebN0dBList(:).';%仿真不同Eb/N0点，列向量
methods = string(p.mitigation.methods(:).');%仿真不同脉冲噪声抑制方法，列向量

ber = nan(numel(methods), numel(EbN0dBList)); %比特错误率（BER）统计
mseVals = nan(numel(methods), numel(EbN0dBList)); %均方误差（MSE）评估图像质量
psnrVals = nan(numel(methods), numel(EbN0dBList));%峰值信噪比（PSNR）评估图像质量
ssimVals = nan(numel(methods), numel(EbN0dBList));%结构相似性指数（SSIM）评估图像质量
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
chaosAssumptionEve = "none";
chaosEncInfoEve = struct('enabled', false, 'mode', "none");
if eveEnabled
    if ~isfield(p.eve, "ebN0dBOffset"); p.eve.ebN0dBOffset = -6; end
    if ~isfield(p.eve, "scrambleAssumption"); p.eve.scrambleAssumption = "wrong_key"; end

    eveEbN0dBList = EbN0dBList + double(p.eve.ebN0dBOffset);
    berEve = nan(numel(methods), numel(EbN0dBList));
    mseEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimEveVals = nan(numel(methods), numel(EbN0dBList));
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
if wardenEnabled
    wardenThreshold = nan(1, numel(EbN0dBList)); %能量检测阈值
    wardenPfaEst = nan(1, numel(EbN0dBList)); %实测虚警率
    wardenPdEst = nan(1, numel(EbN0dBList)); %实测检测率
    wardenPeEst = nan(1, numel(EbN0dBList)); %实测错误率（误检为有信号）
    wardenNObs = nan(1, numel(EbN0dBList)); %每点观测符号数
    wardenPfaTarget = NaN; %目标虚警率（如果仿真中未指定，则使用实测值）
    wardenNTrials = NaN; %蒙特卡洛试验次数（如果仿真中未指定，则使用仿真中实际的试验次数）
end

% 波形成型启用时，将“按符号配置”的信道参数映射到“按采样配置”。
channelSample = adapt_channel_for_sps(p.channel, waveform.sps);
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
dllEnabled = isfield(p.rxSync, "timingDll") && isfield(p.rxSync.timingDll, "enable") ...
    && p.rxSync.timingDll.enable;
syncEnabled = p.rxSync.compensateCarrier || p.rxSync.fineSearchRadius > 0 || ...
    p.rxSync.enableFractionalTiming || p.rxSync.carrierPll.enable || dllEnabled;
mpEnabled = isfield(p.channel, "multipath") && isfield(p.channel.multipath, "enable") && p.channel.multipath.enable;
dopplerEnabled = isfield(p.channel, "doppler") && isfield(p.channel.doppler, "enable") && p.channel.doppler.enable;
pathLossEnabled = isfield(p.channel, "pathLoss") && isfield(p.channel.pathLoss, "enable") && p.channel.pathLoss.enable;
if waveform.enable
    pulseTxt = sprintf('ON(sps=%d)', waveform.sps);
else
    pulseTxt = 'OFF';
end
fprintf('[SIM] Eve=%s, Warden=%s, FH=%s, Chaos=%s, Pulse=%s, RxSync=%s, MP=%s, Doppler=%s, PathLoss=%s\n', ...
    on_off_text(eveEnabled), on_off_text(wardenEnabled), on_off_text(fhEnabled), ...
    on_off_text(chaosEnabled), pulseTxt, on_off_text(syncEnabled), ...
    on_off_text(mpEnabled), on_off_text(dopplerEnabled), on_off_text(pathLossEnabled));
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
        if eveEnabled
            det = warden_energy_detector(txSymForChannel, N0Eve, channelSample, maxDelaySamples, p.covert.warden);
        else
            det = warden_energy_detector(txSymForChannel, N0, channelSample, maxDelaySamples, p.covert.warden);
        end
        if isnan(wardenPfaTarget); wardenPfaTarget = det.pfaTarget; end
        if isnan(wardenNTrials); wardenNTrials = det.nTrials; end
        wardenThreshold(ie) = det.threshold;
        wardenPfaEst(ie) = det.pfaEst;
        wardenPdEst(ie) = det.pdEst;
        wardenPeEst(ie) = det.peEst;
        wardenNObs(ie) = det.nObs;
    end


    nErr = zeros(numel(methods), 1);
    nTot = zeros(numel(methods), 1);
    mseAcc = zeros(numel(methods), 1);
    psnrAcc = zeros(numel(methods), 1);
    ssimAcc = zeros(numel(methods), 1);
    nMse = zeros(numel(methods), 1);
    nPsnr = zeros(numel(methods), 1);
    nSsim = zeros(numel(methods), 1);


    if eveEnabled
        nErrEve = zeros(numel(methods), 1);
        nTotEve = zeros(numel(methods), 1);
        mseAccEve = zeros(numel(methods), 1);
        psnrAccEve = zeros(numel(methods), 1);
        ssimAccEve = zeros(numel(methods), 1);
        nMseEve = zeros(numel(methods), 1);
        nPsnrEve = zeros(numel(methods), 1);
        nSsimEve = zeros(numel(methods), 1);
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
                    && isfield(p.channel.multipath, "pathDelays") && ~isempty(p.channel.multipath.pathDelays)
                mpExtra = max(double(p.channel.multipath.pathDelays(:)));
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

        % 当前帧的重组缓存（按方法分开）
        bobPayloadFrame = cell(numel(methods), 1);
        bobPacketOk = false(numel(methods), nPackets);
        bobSession = repmat(rx_session_empty_local(), numel(methods), 1);
        for im = 1:numel(methods)
            bobPayloadFrame{im} = zeros(totalPayloadBits, 1, "uint8");
        end
        if eveEnabled
            evePayloadFrame = cell(numel(methods), 1);
            evePacketOk = false(numel(methods), nPackets);
            eveSession = repmat(rx_session_empty_local(), numel(methods), 1);
            for im = 1:numel(methods)
                evePayloadFrame{im} = zeros(totalPayloadBits, 1, "uint8");
            end
        end

        % ============ 分包发收 ============
        phyHeaderSymLen = phy_header_symbol_length_local(p.frame);
        bobSyncCtrl = init_packet_sync_ctrl_local();
        if eveEnabled
            eveSyncCtrl = init_packet_sync_ctrl_local();
        end

        for pktIdx = 1:nPackets
            pkt = txPackets(pktIdx);

            % 加入随机传播时延
            delaySym = randi([0, p.channel.maxDelaySymbols], 1, 1);
            delay = round(double(delaySym) * waveform.sps);
            tx = [zeros(delay, 1); pkt.txSymForChannel];

            rx = channel_bg_impulsive(tx, N0, channelSample);
            rx = pulse_rx_to_symbol_rate(rx, waveform);

            if eveEnabled
                rxEve = channel_bg_impulsive(tx, N0Eve, channelSample);
                rxEve = pulse_rx_to_symbol_rate(rxEve, waveform);
            end

            bobOk = false;
            bobPhy = struct();
            rDataBobNominal = complex(zeros(0, 1));
            [startIdx, rxBobSync, syncSymBob, bobSyncCtrl, bobOk] = acquire_packet_sync_local(rx, syncCfgUse, p, pktIdx, firstSyncSym, shortSyncSym, bobSyncCtrl);
            if bobOk
                phyStart = startIdx + numel(syncSymBob);
                [rPhyBob, bobOk] = extract_fractional_block(rxBobSync, phyStart, phyHeaderSymLen, syncCfgUse, struct('type', 'BPSK'));
                if bobOk
                    bobPhyBits = decode_phy_header_symbols_local(rPhyBob, p.frame);
                    [bobPhy, bobOk] = parse_phy_header_bits(bobPhyBits, p.frame);
                end
                if bobOk
                    rxStateBobNominal = derive_rx_packet_state_local(p, double(bobPhy.packetIndex), double(bobPhy.packetDataBytes) * 8);
                    dataStart = phyStart + phyHeaderSymLen;
                    [rDataBobNominal, bobOk] = extract_fractional_block(rxBobSync, dataStart, rxStateBobNominal.nDataSym, syncCfgUse, p.mod);
                end
            end

            eveOk = false;
            evePhy = struct();
            rDataEveNominal = complex(zeros(0, 1));
            if eveEnabled
                [startIdxEve, rxEveSync, syncSymEve, eveSyncCtrl, eveOk] = acquire_packet_sync_local(rxEve, syncCfgUse, p, pktIdx, firstSyncSym, shortSyncSym, eveSyncCtrl);
                if eveOk
                    phyStartEve = startIdxEve + numel(syncSymEve);
                    [rPhyEve, eveOk] = extract_fractional_block(rxEveSync, phyStartEve, phyHeaderSymLen, syncCfgUse, struct('type', 'BPSK'));
                    if eveOk
                        evePhyBits = decode_phy_header_symbols_local(rPhyEve, p.frame);
                        [evePhy, eveOk] = parse_phy_header_bits(evePhyBits, p.frame);
                    end
                    if eveOk
                        rxStateEveNominal = derive_rx_packet_state_local(p, double(evePhy.packetIndex), double(evePhy.packetDataBytes) * 8);
                        dataStartEve = phyStartEve + phyHeaderSymLen;
                        [rDataEveNominal, eveOk] = extract_fractional_block(rxEveSync, dataStartEve, rxStateEveNominal.nDataSym, syncCfgUse, p.mod);
                    end
                end
            end

            % 对不同脉冲抑制方法分别解调与统计
            for im = 1:numel(methods)
                if bobOk
                    rxStateBob = derive_rx_packet_state_local(p, double(bobPhy.packetIndex), double(bobPhy.packetDataBytes) * 8);
                    rDataBob = fit_complex_length_local(rDataBobNominal, rxStateBob.nDataSym);
                    if fhEnabled
                        rDataBob = fh_demodulate(rDataBob, rxStateBob.hopInfo);
                    end
                    if p.rxSync.carrierPll.enable
                        rDataBob = carrier_pll_sync(rDataBob, p.mod, p.rxSync.carrierPll);
                    end
                    [rMit, reliability] = mitigate_impulses(rDataBob, methods(im), p.mitigation);
                    demodSoft = demodulate_to_softbits(rMit, p.mod, p.fec, p.softMetric, reliability);
                    demodDeint = deinterleave_bits(demodSoft, rxStateBob.intState, p.interleaver);
                    dataBitsRxScr = fec_decode(demodDeint, p.fec);
                    packetDataBitsRx = descramble_bits(dataBitsRxScr, rxStateBob.scrambleCfg);
                    packetDataBitsRx = fit_bits_length(packetDataBitsRx, rxStateBob.packetDataBitsLen);

                    [payloadPktRx, bobSessionNext, packetInfoBob, okPacket] = recover_payload_packet_local(packetDataBitsRx, bobPhy, bobSession(im), p);
                    if okPacket
                        bobSession(im) = bobSessionNext;
                        if packetInfoBob.packetIndex == pkt.packetIndex
                            payloadPktTx = pkt.payloadBits;
                            nCompare = min(numel(payloadPktRx), numel(payloadPktTx));
                            if nCompare > 0
                                nErr(im) = nErr(im) + sum(payloadPktRx(1:nCompare) ~= payloadPktTx(1:nCompare));
                                nTot(im) = nTot(im) + nCompare;
                            end
                            if numel(payloadPktRx) < numel(payloadPktTx)
                                nErr(im) = nErr(im) + (numel(payloadPktTx) - numel(payloadPktRx));
                                nTot(im) = nTot(im) + (numel(payloadPktTx) - numel(payloadPktRx));
                            end
                        else
                            nErr(im) = nErr(im) + numel(pkt.payloadBits);
                            nTot(im) = nTot(im) + numel(pkt.payloadBits);
                        end
                        bobPayloadFrame{im}(packetInfoBob.range.startBit:packetInfoBob.range.endBit) = fit_bits_length(payloadPktRx, packetInfoBob.range.nBits);
                        bobPacketOk(im, packetInfoBob.packetIndex) = true;
                    else
                        nErr(im) = nErr(im) + numel(pkt.payloadBits);
                        nTot(im) = nTot(im) + numel(pkt.payloadBits);
                    end
                else
                    nErr(im) = nErr(im) + numel(pkt.payloadBits);
                    nTot(im) = nTot(im) + numel(pkt.payloadBits);
                end

                if eveEnabled
                    if eveOk
                        rxStateEve = derive_rx_packet_state_local(p, double(evePhy.packetIndex), double(evePhy.packetDataBytes) * 8);
                        rDataEve = fit_complex_length_local(rDataEveNominal, rxStateEve.nDataSym);
                        if fhEnabled
                            hopInfoEve = eve_hop_info_local(rxStateEve, fhAssumptionEve);
                            rDataEve = fh_demodulate(rDataEve, hopInfoEve);
                        end
                        if p.rxSync.carrierPll.enable
                            rDataEve = carrier_pll_sync(rDataEve, p.mod, p.rxSync.carrierPll);
                        end
                        scrambleCfgEve = eve_scramble_cfg_local(rxStateEve.scrambleCfg, scrambleAssumptionEve);
                        [rMitEve, reliabilityEve] = mitigate_impulses(rDataEve, methods(im), p.mitigation);
                        demodSoftEve = demodulate_to_softbits(rMitEve, p.mod, p.fec, p.softMetric, reliabilityEve);
                        demodDeintEve = deinterleave_bits(demodSoftEve, rxStateEve.intState, p.interleaver);
                        dataBitsEveScr = fec_decode(demodDeintEve, p.fec);
                        packetDataBitsEve = descramble_bits(dataBitsEveScr, scrambleCfgEve);
                        packetDataBitsEve = fit_bits_length(packetDataBitsEve, rxStateEve.packetDataBitsLen);

                        [payloadPktEve, eveSessionNext, packetInfoEve, okPacketEve] = recover_payload_packet_local(packetDataBitsEve, evePhy, eveSession(im), p);
                        if okPacketEve
                            eveSession(im) = eveSessionNext;
                            if packetInfoEve.packetIndex == pkt.packetIndex
                                payloadPktTx = pkt.payloadBits;
                                nCompareEve = min(numel(payloadPktEve), numel(payloadPktTx));
                                if nCompareEve > 0
                                    nErrEve(im) = nErrEve(im) + sum(payloadPktEve(1:nCompareEve) ~= payloadPktTx(1:nCompareEve));
                                    nTotEve(im) = nTotEve(im) + nCompareEve;
                                end
                                if numel(payloadPktEve) < numel(payloadPktTx)
                                    nErrEve(im) = nErrEve(im) + (numel(payloadPktTx) - numel(payloadPktEve));
                                    nTotEve(im) = nTotEve(im) + (numel(payloadPktTx) - numel(payloadPktEve));
                                end
                            else
                                nErrEve(im) = nErrEve(im) + numel(pkt.payloadBits);
                                nTotEve(im) = nTotEve(im) + numel(pkt.payloadBits);
                            end
                            evePayloadFrame{im}(packetInfoEve.range.startBit:packetInfoEve.range.endBit) = fit_bits_length(payloadPktEve, packetInfoEve.range.nBits);
                            evePacketOk(im, packetInfoEve.packetIndex) = true;
                        else
                            nErrEve(im) = nErrEve(im) + numel(pkt.payloadBits);
                            nTotEve(im) = nTotEve(im) + numel(pkt.payloadBits);
                        end
                    else
                        nErrEve(im) = nErrEve(im) + numel(pkt.payloadBits);
                        nTotEve(im) = nTotEve(im) + numel(pkt.payloadBits);
                    end
                end
            end
        end

        for im = 1:numel(methods)
            payloadBitsRxFrame = bobPayloadFrame{im};
            metaBobUse = meta;
            totalPayloadBitsBob = totalPayloadBits;
            rxLayoutBob = derive_packet_layout_local(totalPayloadBitsBob, p);
            if bobSession(im).known
                metaBobUse = bobSession(im).meta;
                totalPayloadBitsBob = bobSession(im).totalPayloadBits;
                rxLayoutBob = derive_packet_layout_local(totalPayloadBitsBob, p);
            end
            if packetIndependentBitChaos && chaosEnabled
                payloadBitsRxDec = decrypt_payload_packets_rx_local(payloadBitsRxFrame, bobPacketOk(im, :), p, totalPayloadBitsBob, "known");
                imgRx = payload_bits_to_image(payloadBitsRxDec, metaBobUse, p.payload);
            elseif chaosEnabled && isfield(chaosEncInfo, "enabled") && chaosEncInfo.enabled
                if isfield(chaosEncInfo, "mode") && lower(string(chaosEncInfo.mode)) == "payload_bits"
                    payloadBitsRxDec = chaos_decrypt_bits(payloadBitsRxFrame, chaosEncInfo);
                    imgRx = payload_bits_to_image(payloadBitsRxDec, metaBobUse, p.payload);
                else
                    imgRxEnc = payload_bits_to_image(payloadBitsRxFrame, metaBobUse, p.payload);
                    imgRx = chaos_decrypt(imgRxEnc, chaosEncInfo);
                end
            else
                imgRx = payload_bits_to_image(payloadBitsRxFrame, metaBobUse, p.payload);
            end
            if packetConcealEnable && nPackets > 1
                imgRx = conceal_image_from_packets(imgRx, bobPacketOk(im, :), rxLayoutBob, metaBobUse, p.payload, packetConcealMode);
            end

            [psnrNow, ssimNow, mseNow] = image_quality(imgTx, imgRx);
            if isfinite(mseNow)
                mseAcc(im) = mseAcc(im) + mseNow;
                nMse(im) = nMse(im) + 1;
            end
            if ~isnan(psnrNow)
                psnrAcc(im) = psnrAcc(im) + psnrNow;
                nPsnr(im) = nPsnr(im) + 1;
            end
            if isfinite(ssimNow)
                ssimAcc(im) = ssimAcc(im) + ssimNow;
                nSsim(im) = nSsim(im) + 1;
            end

            if frameIdx == 1 && ie == exampleIdx
                example.(methods(im)).EbN0dB = EbN0dB;
                example.(methods(im)).imgRx = imgRx;
                example.(methods(im)).packetSuccessRate = mean(bobPacketOk(im, :));
            end
        end

        if eveEnabled
            for im = 1:numel(methods)
                payloadBitsEveFrame = evePayloadFrame{im};
                metaEveUse = meta;
                totalPayloadBitsEve = totalPayloadBits;
                rxLayoutEve = derive_packet_layout_local(totalPayloadBitsEve, p);
                if eveSession(im).known
                    metaEveUse = eveSession(im).meta;
                    totalPayloadBitsEve = eveSession(im).totalPayloadBits;
                    rxLayoutEve = derive_packet_layout_local(totalPayloadBitsEve, p);
                end
                if packetIndependentBitChaos && chaosEnabled && chaosAssumptionEve ~= "none"
                    payloadBitsEveDec = decrypt_payload_packets_rx_local(payloadBitsEveFrame, evePacketOk(im, :), p, totalPayloadBitsEve, chaosAssumptionEve);
                    imgEve = payload_bits_to_image(payloadBitsEveDec, metaEveUse, p.payload);
                elseif chaosEnabled && isfield(chaosEncInfoEve, "enabled") && chaosEncInfoEve.enabled
                    if isfield(chaosEncInfoEve, "mode") && lower(string(chaosEncInfoEve.mode)) == "payload_bits"
                        payloadBitsEveDec = chaos_decrypt_bits(payloadBitsEveFrame, chaosEncInfoEve);
                        imgEve = payload_bits_to_image(payloadBitsEveDec, metaEveUse, p.payload);
                    else
                        imgEveEnc = payload_bits_to_image(payloadBitsEveFrame, metaEveUse, p.payload);
                        imgEve = chaos_decrypt(imgEveEnc, chaosEncInfoEve);
                    end
                else
                    imgEve = payload_bits_to_image(payloadBitsEveFrame, metaEveUse, p.payload);
                end
                if packetConcealEnable && nPackets > 1
                    imgEve = conceal_image_from_packets(imgEve, evePacketOk(im, :), rxLayoutEve, metaEveUse, p.payload, packetConcealMode);
                end

                [psnrNowEve, ssimNowEve, mseNowEve] = image_quality(imgTx, imgEve);
                if isfinite(mseNowEve)
                    mseAccEve(im) = mseAccEve(im) + mseNowEve;
                    nMseEve(im) = nMseEve(im) + 1;
                end
                if ~isnan(psnrNowEve)
                    psnrAccEve(im) = psnrAccEve(im) + psnrNowEve;
                    nPsnrEve(im) = nPsnrEve(im) + 1;
                end
                if isfinite(ssimNowEve)
                    ssimAccEve(im) = ssimAccEve(im) + ssimNowEve;
                    nSsimEve(im) = nSsimEve(im) + 1;
                end

                if frameIdx == 1 && ie == exampleIdx
                    exampleEve.(methods(im)).EbN0dB = EbN0dBEve;
                    exampleEve.(methods(im)).headerOk = all(evePacketOk(im, :));
                    exampleEve.(methods(im)).packetSuccessRate = mean(evePacketOk(im, :));
                    exampleEve.(methods(im)).imgRx = imgEve;
                end
            end
        end
    end

    % --- 当前Eb/N0点的性能统计 ---
    ber(:, ie) = nErr ./ max(nTot, 1);

    mseOut = nan(numel(methods), 1);
    psnrOut = nan(numel(methods), 1);
    ssimOut = nan(numel(methods), 1);
    validMse = nMse > 0;
    validPsnr = nPsnr > 0;
    validSsim = nSsim > 0;
    mseOut(validMse) = mseAcc(validMse) ./ nMse(validMse);
    psnrOut(validPsnr) = psnrAcc(validPsnr) ./ nPsnr(validPsnr);
    ssimOut(validSsim) = ssimAcc(validSsim) ./ nSsim(validSsim);
    mseVals(:, ie) = mseOut;
    psnrVals(:, ie) = psnrOut;
    ssimVals(:, ie) = ssimOut;


    if eveEnabled
        berEve(:, ie) = nErrEve ./ max(nTotEve, 1);

        mseOutEve = nan(numel(methods), 1);
        psnrOutEve = nan(numel(methods), 1);
        ssimOutEve = nan(numel(methods), 1);
        validMseEve = nMseEve > 0;
        validPsnrEve = nPsnrEve > 0;
        validSsimEve = nSsimEve > 0;
        mseOutEve(validMseEve) = mseAccEve(validMseEve) ./ nMseEve(validMseEve);
        psnrOutEve(validPsnrEve) = psnrAccEve(validPsnrEve) ./ nPsnrEve(validPsnrEve);
        ssimOutEve(validSsimEve) = ssimAccEve(validSsimEve) ./ nSsimEve(validSsimEve);
        mseEveVals(:, ie) = mseOutEve;
        psnrEveVals(:, ie) = psnrOutEve;
        ssimEveVals(:, ie) = ssimOutEve;
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

% 波形/频谱（单次突发，无信道）
[psd, freqHz, bw99Hz, etaBpsHz] = estimate_spectrum(txSymForSpectrum, modInfo);

results = struct();
results.params = p;
results.ebN0dB = EbN0dBList;
results.methods = methods;
results.ber = ber;
results.mse = mseVals;
results.psnr = psnrVals;
results.ssim = ssimVals;
results.example = example;
results.spectrum = struct("freqHz", freqHz, "psd", psd, "bw99Hz", bw99Hz, "etaBpsHz", etaBpsHz);
results.kl = struct("ebN0dB", EbN0dBList, ...
    "signalVsNoise", klSigVsNoise, ...
    "noiseVsSignal", klNoiseVsSig, ...
    "symmetric", klSym);


if eveEnabled
    results.eve = struct();
    results.eve.ebN0dB = eveEbN0dBList;
    results.eve.ber = berEve;
    results.eve.mse = mseEveVals;
    results.eve.psnr = psnrEveVals;
    results.eve.ssim = ssimEveVals;
    results.eve.example = exampleEve;
    results.eve.scrambleAssumption = string(p.eve.scrambleAssumption);
end

if wardenEnabled
    results.covert = struct();
    results.covert.warden = struct();
    results.covert.warden.pfaTarget = wardenPfaTarget;
    results.covert.warden.nObs = wardenNObs;
    results.covert.warden.nTrials = wardenNTrials;
    results.covert.warden.threshold = wardenThreshold;
    results.covert.warden.pfaEst = wardenPfaEst;
    results.covert.warden.pdEst = wardenPdEst;
    results.covert.warden.peEst = wardenPeEst;
    results.covert.warden.ebN0dB = EbN0dBList;
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

function session = rx_session_empty_local()
session = struct();
session.known = false;
session.totalPayloadBits = NaN;
session.totalPackets = NaN;
session.meta = struct();
end

function session = learn_rx_session_local(metaRx)
session = rx_session_empty_local();
session.known = true;
session.totalPayloadBits = double(metaRx.totalPayloadBytes) * 8;
session.totalPackets = double(metaRx.totalPackets);
session.meta = metaRx;
end

function state = derive_rx_packet_state_local(p, pktIdx, packetDataBitsLen)
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

packetDataBitsLen = double(phyHeader.packetDataBytes) * 8;
packetDataBitsRx = fit_bits_length(packetDataBitsRx, packetDataBitsLen);
ok = packet_data_crc_valid_local(packetDataBitsRx, phyHeader);
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

function ok = packet_data_crc_valid_local(packetDataBitsRx, phyHeader)
needBits = double(phyHeader.packetDataBytes) * 8;
if numel(packetDataBitsRx) < needBits
    ok = false;
    return;
end
crcNow = crc16_ccitt_bits(packetDataBitsRx(1:needBits));
ok = uint16(phyHeader.packetDataCrc16) == uint16(crcNow);
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

function repeat = phy_header_repeat_local(frameCfg)
repeat = 3;
if isfield(frameCfg, "phyHeaderRepeat") && ~isempty(frameCfg.phyHeaderRepeat)
    repeat = max(1, round(double(frameCfg.phyHeaderRepeat)));
end
end

function nBits = phy_header_length_bits_local(~)
nBits = 16 + 8 + 16 + 16 + 16 + 16;
end

function nSym = phy_header_symbol_length_local(frameCfg)
nSym = phy_header_length_bits_local(frameCfg) * phy_header_repeat_local(frameCfg);
end

function ctrl = init_packet_sync_ctrl_local()
ctrl = struct();
ctrl.forceLongSearch = true;
ctrl.shortSyncMisses = 0;
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
    candidateKinds = ["long"];
elseif isLongPkt
    candidateKinds = ["long"];
else
    candidateKinds = ["short"];
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

function bits = decode_phy_header_symbols_local(rSym, frameCfg)
repeat = phy_header_repeat_local(frameCfg);
rSym = rSym(:);
if repeat <= 1
    bits = uint8(real(rSym) < 0);
else
    nGroups = floor(numel(rSym) / repeat);
    if nGroups <= 0
        bits = uint8([]);
        return;
    end
    votes = reshape(real(rSym(1:nGroups * repeat)) < 0, repeat, nGroups);
    bits = uint8(sum(votes, 1) >= ceil(repeat / 2)).';
end
bits = fit_bits_length(bits, phy_header_length_bits_local(frameCfg));
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
