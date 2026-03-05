function results = simulate(p)
%SIMULATE  端到端链路仿真，包含脉冲噪声抑制。
%
% 输入:
%   p - 仿真参数结构体（建议由default_params()生成）
%       .rngSeed, .sim, .source, .chaosEncrypt, .payload
%       .frame, .scramble, .fec, .interleaver, .mod, .fh
%       .rf, .channel, .mitigation, .softMetric, .rxSync
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
if ~isfield(p, "rf"); p.rf = struct(); end
if ~isfield(p.rf, "enable"); p.rf.enable = false; end
if ~isfield(p.rf, "ifFreqNorm"); p.rf.ifFreqNorm = 0.18; end
if ~isfield(p.rf, "txFreqNorm"); p.rf.txFreqNorm = p.rf.ifFreqNorm; end
if ~isfield(p.rf, "rxFreqNorm"); p.rf.rxFreqNorm = p.rf.ifFreqNorm; end
if ~isfield(p.rf, "txPhaseOffsetRad"); p.rf.txPhaseOffsetRad = 0; end
if ~isfield(p.rf, "rxPhaseOffsetRad"); p.rf.rxPhaseOffsetRad = 0; end

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

[~, preambleSym] = make_preamble(p.frame.preambleLength);%生成PN前导

% 发送端按包构建（最小分包：pktIdx/totalPkts/payloadLen/CRC16）
[txPackets, txPlan] = build_tx_packets(payloadBits, meta, p, preambleSym, packetIndependentBitChaos);
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

% 用于频谱/监视者评估的整段突发
txSymForChannel = txPlan.txBurstForEval;
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
    if ~isfield(p.eve, "rfFreqOffsetNorm"); p.eve.rfFreqOffsetNorm = 0.0; end

    eveEbN0dBList = EbN0dBList + double(p.eve.ebN0dBOffset);
    berEve = nan(numel(methods), numel(EbN0dBList));
    mseEveVals = nan(numel(methods), numel(EbN0dBList));
    psnrEveVals = nan(numel(methods), numel(EbN0dBList));
    ssimEveVals = nan(numel(methods), numel(EbN0dBList));
    exampleEve = struct();

    scrambleEve = p.scramble;
    switch lower(string(p.eve.scrambleAssumption))
        case "known"
            % 最佳情况截获：Eve知道扰码密钥
        case "none"
            scrambleEve.enable = false;
        case "wrong_key"
            scrambleEve.enable = true;
            scrambleEve.pnInit = circshift(scrambleEve.pnInit, 1);
            if all(scrambleEve.pnInit == 0)
                scrambleEve.pnInit(end) = 1;
            end
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

% Eve逐包解跳配置（与发送端分包序列对齐）
if eveEnabled
    hopInfoEveList = cell(nPackets, 1);
    if ~fhEnabled
        for ip = 1:nPackets
            hopInfoEveList{ip} = struct('enable', false);
        end
    else
        switch fhAssumptionEve
            case "known"
                for ip = 1:nPackets
                    hopInfoEveList{ip} = txPackets(ip).hopInfo;
                end
            case "none"
                for ip = 1:nPackets
                    hopInfoEveList{ip} = struct('enable', false);
                end
            case "partial"
                fhEve = make_partial_fh_config(p.fh);
                for ip = 1:nPackets
                    [~, hopInfoEveList{ip}] = fh_modulate(txPackets(ip).dataSymTx, fhEve);
                end
            otherwise
                error("Unknown eve.fhAssumption: %s", fhAssumptionEve);
        end
    end
end

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
syncEnabled = p.rxSync.compensateCarrier || p.rxSync.fineSearchRadius > 0 || ...
    p.rxSync.enableFractionalTiming || p.rxSync.carrierPll.enable;
mpEnabled = isfield(p.channel, "multipath") && isfield(p.channel.multipath, "enable") && p.channel.multipath.enable;
dopplerEnabled = isfield(p.channel, "doppler") && isfield(p.channel.doppler, "enable") && p.channel.doppler.enable;
pathLossEnabled = isfield(p.channel, "pathLoss") && isfield(p.channel.pathLoss, "enable") && p.channel.pathLoss.enable;
fprintf('[SIM] Eve=%s, Warden=%s, FH=%s, Chaos=%s, RF=%s, RxSync=%s, MP=%s, Doppler=%s, PathLoss=%s\n', ...
    on_off_text(eveEnabled), on_off_text(wardenEnabled), on_off_text(fhEnabled), ...
    on_off_text(chaosEnabled), on_off_text(p.rf.enable), on_off_text(syncEnabled), ...
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
            det = warden_energy_detector(txSymForChannel, N0Eve, p.channel, p.channel.maxDelaySymbols, p.covert.warden);
        else
            det = warden_energy_detector(txSymForChannel, N0, p.channel, p.channel.maxDelaySymbols, p.covert.warden);
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
        for im = 1:numel(methods)
            bobPayloadFrame{im} = zeros(totalPayloadBits, 1, "uint8");
        end
        if eveEnabled
            evePayloadFrame = cell(numel(methods), 1);
            evePacketOk = false(numel(methods), nPackets);
            for im = 1:numel(methods)
                evePayloadFrame{im} = zeros(totalPayloadBits, 1, "uint8");
            end
        end

        % ============ 分包发收 ============
        for pktIdx = 1:nPackets
            pkt = txPackets(pktIdx);

            % 信道
            delay = randi([0, p.channel.maxDelaySymbols], 1, 1);
            tx = [zeros(delay, 1); pkt.txSymForChannel];

            rxCh = channel_bg_impulsive(tx, N0, p.channel);
            if p.rf.enable
                rx = rf_downconvert(rxCh, p.rf);
            else
                rx = rxCh;
            end

            if eveEnabled
                rxEveCh = channel_bg_impulsive(tx, N0Eve, p.channel);
                if p.rf.enable
                    rfEve = p.rf;
                    rfEve.rxFreqNorm = p.rf.rxFreqNorm + double(p.eve.rfFreqOffsetNorm);
                    rxEve = rf_downconvert(rxEveCh, rfEve);
                else
                    rxEve = rxEveCh;
                end
            end

            % Bob同步与解跳
            bobOk = true;
            [startIdx, rxBobSync] = frame_sync(rx, preambleSym, syncCfgUse);
            if isempty(startIdx)
                bobOk = false;
                rData = complex(zeros(numel(pkt.dataSymTx), 1));
            else
                dataStart = startIdx + numel(preambleSym);
                [rData, bobOk] = extract_fractional_block(rxBobSync, dataStart, numel(pkt.dataSymTx));
            end
            if bobOk
                if fhEnabled
                    rData = fh_demodulate(rData, pkt.hopInfo);
                end
                if p.rxSync.carrierPll.enable
                    rData = carrier_pll_sync(rData, p.mod, p.rxSync.carrierPll);
                end
            end

            % Eve同步与解跳
            eveOk = false;
            if eveEnabled
                eveOk = true;
                [startIdxEve, rxEveSync] = frame_sync(rxEve, preambleSym, syncCfgUse);
                if isempty(startIdxEve)
                    eveOk = false;
                    rDataEve = complex(zeros(numel(pkt.dataSymTx), 1));
                else
                    dataStartEve = startIdxEve + numel(preambleSym);
                    [rDataEve, eveOk] = extract_fractional_block(rxEveSync, dataStartEve, numel(pkt.dataSymTx));
                end
                if eveOk
                    if fhEnabled
                        rDataEve = fh_demodulate(rDataEve, hopInfoEveList{pktIdx});
                    end
                    if p.rxSync.carrierPll.enable
                        rDataEve = carrier_pll_sync(rDataEve, p.mod, p.rxSync.carrierPll);
                    end
                end
            end

            % 各抑制方法解调与分包重组
            for im = 1:numel(methods)
                if bobOk
                    [rMit, reliability] = mitigate_impulses(rData, methods(im), p.mitigation);
                    demodSoft = demodulate_to_softbits(rMit, p.mod, p.fec, p.softMetric, reliability);
                    demodDeint = deinterleave_bits(demodSoft, pkt.intState, p.interleaver);
                    dataBitsRxScr = fec_decode(demodDeint, p.fec);
                    dataBitsRx = descramble_bits(dataBitsRxScr, p.scramble);

                    [payloadPktRx, metaRx, okHeader] = parse_frame_bits(dataBitsRx, p.frame.magic16);
                    okPacket = okHeader ...
                        && packet_header_valid(metaRx, pktIdx, nPackets, pkt.payloadBytes, meta.payloadBytes) ...
                        && packet_crc_valid(payloadPktRx, metaRx);
                    if okPacket
                        payloadPktRx = payloadPktRx(1:min(end, numel(pkt.payloadBits)));
                        payloadPktTx = pkt.payloadBits(1:numel(payloadPktRx));
                        nErr(im) = nErr(im) + sum(payloadPktRx ~= payloadPktTx);
                        nTot(im) = nTot(im) + numel(payloadPktTx);
                        if numel(payloadPktRx) < numel(pkt.payloadBits)
                            nErr(im) = nErr(im) + (numel(pkt.payloadBits) - numel(payloadPktRx));
                            nTot(im) = nTot(im) + (numel(pkt.payloadBits) - numel(payloadPktRx));
                        end
                        bobPayloadFrame{im}(pkt.startBit:pkt.endBit) = fit_bits_length(payloadPktRx, numel(pkt.payloadBits));
                        bobPacketOk(im, pktIdx) = true;
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
                        [rMitEve, reliabilityEve] = mitigate_impulses(rDataEve, methods(im), p.mitigation);
                        demodSoftEve = demodulate_to_softbits(rMitEve, p.mod, p.fec, p.softMetric, reliabilityEve);
                        demodDeintEve = deinterleave_bits(demodSoftEve, pkt.intState, p.interleaver);
                        dataBitsEveScr = fec_decode(demodDeintEve, p.fec);
                        dataBitsEve = descramble_bits(dataBitsEveScr, scrambleEve);

                        [payloadPktEve, metaEve, okHeaderEve] = parse_frame_bits(dataBitsEve, p.frame.magic16);
                        okPacketEve = okHeaderEve ...
                            && packet_header_valid(metaEve, pktIdx, nPackets, pkt.payloadBytes, meta.payloadBytes) ...
                            && packet_crc_valid(payloadPktEve, metaEve);
                        if okPacketEve
                            payloadPktEve = payloadPktEve(1:min(end, numel(pkt.payloadBits)));
                            payloadPktTx = pkt.payloadBits(1:numel(payloadPktEve));
                            nErrEve(im) = nErrEve(im) + sum(payloadPktEve ~= payloadPktTx);
                            nTotEve(im) = nTotEve(im) + numel(payloadPktTx);
                            if numel(payloadPktEve) < numel(pkt.payloadBits)
                                nErrEve(im) = nErrEve(im) + (numel(pkt.payloadBits) - numel(payloadPktEve));
                                nTotEve(im) = nTotEve(im) + (numel(pkt.payloadBits) - numel(payloadPktEve));
                            end
                            evePayloadFrame{im}(pkt.startBit:pkt.endBit) = fit_bits_length(payloadPktEve, numel(pkt.payloadBits));
                            evePacketOk(im, pktIdx) = true;
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

        % 帧级图像重建与质量评价（分包重组后）
        for im = 1:numel(methods)
            payloadBitsRxFrame = bobPayloadFrame{im};
            if packetIndependentBitChaos && chaosEnabled
                payloadBitsRxDec = decrypt_payload_packets(payloadBitsRxFrame, bobPacketOk(im, :), txPackets, "known");
                imgRx = payload_bits_to_image(payloadBitsRxDec, meta, p.payload);
            elseif chaosEnabled && isfield(chaosEncInfo, "enabled") && chaosEncInfo.enabled
                if isfield(chaosEncInfo, "mode") && lower(string(chaosEncInfo.mode)) == "payload_bits"
                    payloadBitsRxDec = chaos_decrypt_bits(payloadBitsRxFrame, chaosEncInfo);
                    imgRx = payload_bits_to_image(payloadBitsRxDec, meta, p.payload);
                else
                    imgRxEnc = payload_bits_to_image(payloadBitsRxFrame, meta, p.payload);
                    imgRx = chaos_decrypt(imgRxEnc, chaosEncInfo);
                end
            else
                imgRx = payload_bits_to_image(payloadBitsRxFrame, meta, p.payload);
            end
            if packetConcealEnable && nPackets > 1
                imgRx = conceal_image_from_packets(imgRx, bobPacketOk(im, :), txPackets, meta, p.payload, packetConcealMode);
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
                if packetIndependentBitChaos && chaosEnabled && chaosAssumptionEve ~= "none"
                    payloadBitsEveDec = decrypt_payload_packets(payloadBitsEveFrame, evePacketOk(im, :), txPackets, chaosAssumptionEve);
                    imgEve = payload_bits_to_image(payloadBitsEveDec, meta, p.payload);
                elseif chaosEnabled && isfield(chaosEncInfoEve, "enabled") && chaosEncInfoEve.enabled
                    if isfield(chaosEncInfoEve, "mode") && lower(string(chaosEncInfoEve.mode)) == "payload_bits"
                        payloadBitsEveDec = chaos_decrypt_bits(payloadBitsEveFrame, chaosEncInfoEve);
                        imgEve = payload_bits_to_image(payloadBitsEveDec, meta, p.payload);
                    else
                        imgEveEnc = payload_bits_to_image(payloadBitsEveFrame, meta, p.payload);
                        imgEve = chaos_decrypt(imgEveEnc, chaosEncInfoEve);
                    end
                else
                    imgEve = payload_bits_to_image(payloadBitsEveFrame, meta, p.payload);
                end
                if packetConcealEnable && nPackets > 1
                    imgEve = conceal_image_from_packets(imgEve, evePacketOk(im, :), txPackets, meta, p.payload, packetConcealMode);
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
[psd, freqHz, bw99Hz, etaBpsHz] = estimate_spectrum(txSymForChannel, modInfo);

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

function txt = on_off_text(flag)
if flag
    txt = 'ON';
else
    txt = 'OFF';
end
end

function txt = format_metric_pairs(methods, values)
pairs = cell(1, numel(methods));
for k = 1:numel(methods)
    pairs{k} = sprintf('%s=%.3e', char(methods(k)), values(k));
end
txt = strjoin(pairs, ', ');
end

function [blk, ok] = extract_fractional_block(x, startPos, nSamp)
% 从可能带分数起点的位置提取定长序列。
x = x(:);
if nSamp <= 0 || isempty(x)
    blk = complex(zeros(0, 1));
    ok = false;
    return;
end
t = startPos + (0:nSamp-1).';
% 允许轻微越界（线性外推为0），避免分数定时下末尾判定失败
guard = 2;
if t(1) < 1 - guard || t(end) > numel(x) + guard
    blk = complex(zeros(nSamp, 1));
    ok = false;
    return;
end
idx = (1:numel(x)).';
blk = interp1(idx, x, t, "linear", 0);
ok = all(isfinite(blk)) && any(abs(blk) > 0);
end

function codec = get_payload_codec(payload)
codec = "raw";
if isfield(payload, "codec") && strlength(string(payload.codec)) > 0
    codec = lower(string(payload.codec));
end
switch codec
    case {"raw", "none"}
        codec = "raw";
    case {"dct", "dct8", "dct_lossy"}
        codec = "dct";
    otherwise
        codec = "raw";
end
end

function [txPackets, plan] = build_tx_packets(payloadBits, meta, p, preambleSym, packetIndependentBitChaos)
% 按配置将整图载荷切分为多个分包并构建发送符号。
payloadBits = uint8(payloadBits(:) ~= 0);
totalBits = numel(payloadBits);
if nargin < 5
    packetIndependentBitChaos = false;
end

packetEnable = false;
pktBitsPerPacket = totalBits;
if isfield(p, "packet") && isstruct(p.packet) && isfield(p.packet, "enable") && p.packet.enable
    packetEnable = true;
    if isfield(p.packet, "payloadBitsPerPacket") && ~isempty(p.packet.payloadBitsPerPacket)
        pktBitsPerPacket = max(8, round(double(p.packet.payloadBitsPerPacket)));
    else
        pktBitsPerPacket = 4096;
    end
end

% 分包以字节对齐，便于payloadBytes/CRC统计
pktBitsPerPacket = 8 * floor(pktBitsPerPacket / 8);
if pktBitsPerPacket <= 0
    pktBitsPerPacket = 8;
end
if ~packetEnable
    pktBitsPerPacket = max(pktBitsPerPacket, totalBits);
end

nPackets = max(1, ceil(totalBits / pktBitsPerPacket));
if nPackets > 65535
    error("分包数量过大(%d)，超出uint16可表示范围。", nPackets);
end

fhEnabled = isfield(p, 'fh') && isfield(p.fh, 'enable') && p.fh.enable;
packetChaosEnable = packetIndependentBitChaos && isfield(p, "chaosEncrypt") ...
    && isfield(p.chaosEncrypt, "enable") && p.chaosEncrypt.enable;
txPackets = repmat(struct(), nPackets, 1);
txBurstParts = cell(nPackets, 1);
modInfoRef = struct();
headerLenBits = 0;

for pktIdx = 1:nPackets
    startBit = (pktIdx - 1) * pktBitsPerPacket + 1;
    endBit = min(pktIdx * pktBitsPerPacket, totalBits);
    payloadPktPlain = payloadBits(startBit:endBit);
    payloadPkt = payloadPktPlain;
    chaosEncInfoPkt = struct('enabled', false, 'mode', "none");
    if packetChaosEnable
        chaosPktCfg = derive_packet_chaos_cfg(p.chaosEncrypt, pktIdx);
        [payloadPkt, chaosEncInfoPkt] = chaos_encrypt_bits(payloadPktPlain, chaosPktCfg);
    end
    payloadPktBytes = ceil(numel(payloadPkt) / 8);
    if payloadPktBytes > 65535
        error("单包payload过大(%d bytes)，超出uint16可表示范围。", payloadPktBytes);
    end

    metaPkt = meta;
    metaPkt.totalPayloadBytes = uint32(meta.payloadBytes);
    metaPkt.packetIndex = uint16(pktIdx);
    metaPkt.totalPackets = uint16(nPackets);
    metaPkt.packetPayloadBytes = uint16(payloadPktBytes);
    metaPkt.packetCrc16 = crc16_ccitt_bits(payloadPkt);
    [headerBits, ~] = build_header_bits(metaPkt, p.frame.magic16);
    headerLenBits = numel(headerBits);

    dataBitsTx = [headerBits; payloadPkt];
    dataBitsTxScr = scramble_bits(dataBitsTx, p.scramble);
    codedBits = fec_encode(dataBitsTxScr, p.fec);
    [codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);
    [dataSymTx, modInfo] = modulate_bits(codedBitsInt, p.mod);
    modInfoRef = modInfo;

    if fhEnabled
        [dataSymHop, hopInfo] = fh_modulate(dataSymTx, p.fh);
    else
        dataSymHop = dataSymTx;
        hopInfo = struct('enable', false);
    end

    txSymPkt = [preambleSym; dataSymHop];
    if isfield(p, "rf") && isfield(p.rf, "enable") && p.rf.enable
        txSymForChannel = rf_upconvert(txSymPkt, p.rf);
    else
        txSymForChannel = txSymPkt;
    end

    txPackets(pktIdx).startBit = startBit;
    txPackets(pktIdx).endBit = endBit;
    txPackets(pktIdx).payloadBitsPlain = payloadPktPlain;
    txPackets(pktIdx).payloadBits = payloadPkt;
    txPackets(pktIdx).payloadBytes = payloadPktBytes;
    txPackets(pktIdx).chaosEncInfo = chaosEncInfoPkt;
    txPackets(pktIdx).dataSymTx = dataSymTx;
    txPackets(pktIdx).hopInfo = hopInfo;
    txPackets(pktIdx).intState = intState;
    txPackets(pktIdx).txSymForChannel = txSymForChannel;
    txBurstParts{pktIdx} = txSymForChannel;
end

plan = struct();
plan.packetEnable = packetEnable;
plan.nPackets = nPackets;
plan.headerLenBits = headerLenBits;
plan.fhEnabled = fhEnabled;
plan.packetChaosEnable = packetChaosEnable;
plan.modInfo = modInfoRef;
plan.txBurstForEval = vertcat(txBurstParts{:});
end

function ok = packet_header_valid(metaRx, packetIndex, totalPackets, packetPayloadBytes, totalPayloadBytes)
% 校验分包头关键信息是否与当前上下文一致。
ok = true;
needFields = ["packetIndex", "totalPackets", "packetPayloadBytes", "totalPayloadBytes"];
for k = 1:numel(needFields)
    if ~isfield(metaRx, needFields(k))
        ok = false;
        return;
    end
end

if double(metaRx.packetIndex) ~= double(packetIndex)
    ok = false;
    return;
end
if double(metaRx.totalPackets) ~= double(totalPackets)
    ok = false;
    return;
end
if double(metaRx.packetPayloadBytes) ~= double(packetPayloadBytes)
    ok = false;
    return;
end
if double(metaRx.totalPayloadBytes) ~= double(totalPayloadBytes)
    ok = false;
    return;
end
end

function ok = packet_crc_valid(payloadBitsRx, metaRx)
% 校验分包CRC16。
if ~isfield(metaRx, "packetCrc16") || ~isfield(metaRx, "packetPayloadBytes")
    ok = true; % 兼容旧头
    return;
end
needBits = double(metaRx.packetPayloadBytes) * 8;
if numel(payloadBitsRx) < needBits
    ok = false;
    return;
end
payloadUse = payloadBitsRx(1:needBits);
crcNow = crc16_ccitt_bits(payloadUse);
ok = uint16(metaRx.packetCrc16) == uint16(crcNow);
end

function bitsOut = fit_bits_length(bitsIn, targetLen)
bitsIn = uint8(bitsIn(:) ~= 0);
targetLen = max(0, round(double(targetLen)));
if numel(bitsIn) >= targetLen
    bitsOut = bitsIn(1:targetLen);
else
    bitsOut = [bitsIn; zeros(targetLen - numel(bitsIn), 1, "uint8")];
end
end

function encPkt = derive_packet_chaos_cfg(encBase, pktIdx)
% 从主混沌密钥派生每包独立参数，避免包间复用同一初值。
encPkt = encBase;
if ~isfield(encPkt, "enable")
    encPkt.enable = true;
end
if ~isfield(encPkt, "chaosMethod") || strlength(string(encPkt.chaosMethod)) == 0
    encPkt.chaosMethod = "logistic";
end
if ~isfield(encPkt, "chaosParams") || ~isstruct(encPkt.chaosParams)
    encPkt.chaosParams = struct();
end

delta = 1e-10 * (double(pktIdx) + 1);
if ~isfield(encPkt.chaosParams, "x0") || isempty(encPkt.chaosParams.x0)
    encPkt.chaosParams.x0 = 0.1234567890123456;
end
encPkt.chaosParams.x0 = wrap_unit_interval(double(encPkt.chaosParams.x0) + delta);
if isfield(encPkt.chaosParams, "y0") && ~isempty(encPkt.chaosParams.y0)
    encPkt.chaosParams.y0 = wrap_unit_interval(double(encPkt.chaosParams.y0) + 2 * delta);
end
end

function payloadBitsOut = decrypt_payload_packets(payloadBitsIn, packetOk, txPackets, assumption)
% 逐包独立解密，避免密文扩散跨包影响。
payloadBitsOut = uint8(payloadBitsIn(:) ~= 0);
nPacketsLocal = numel(txPackets);
ok = normalize_packet_ok(packetOk, nPacketsLocal);
assumption = lower(string(assumption));

for pktIdx = 1:nPacketsLocal
    if ~ok(pktIdx)
        continue;
    end
    pkt = txPackets(pktIdx);
    if ~isfield(pkt, "chaosEncInfo") || ~isfield(pkt.chaosEncInfo, "enabled") || ~pkt.chaosEncInfo.enabled
        continue;
    end
    if assumption == "none"
        continue;
    end

    infoUse = pkt.chaosEncInfo;
    if assumption == "wrong_key"
        infoUse = perturb_chaos_enc_info(infoUse, pktIdx);
    elseif assumption ~= "known"
        error("Unknown chaos assumption: %s", assumption);
    end

    seg = payloadBitsOut(pkt.startBit:pkt.endBit);
    segDec = chaos_decrypt_bits(seg, infoUse);
    payloadBitsOut(pkt.startBit:pkt.endBit) = fit_bits_length(segDec, numel(seg));
end
end

function infoOut = perturb_chaos_enc_info(infoIn, pktIdx)
% Eve错钥场景：对每包混沌初值施加轻微扰动。
infoOut = infoIn;
if ~isfield(infoOut, "chaosParams") || ~isstruct(infoOut.chaosParams)
    infoOut.chaosParams = struct();
end
delta = 7e-10 * (double(pktIdx) + 1);
if isfield(infoOut.chaosParams, "x0") && ~isempty(infoOut.chaosParams.x0)
    infoOut.chaosParams.x0 = wrap_unit_interval(double(infoOut.chaosParams.x0) + delta);
end
if isfield(infoOut.chaosParams, "y0") && ~isempty(infoOut.chaosParams.y0)
    infoOut.chaosParams.y0 = wrap_unit_interval(double(infoOut.chaosParams.y0) + 2 * delta);
end
end

function imgOut = conceal_image_from_packets(imgIn, packetOk, txPackets, meta, payload, mode)
% 在图像域/块域做丢包补偿，避免直接在密文比特流上估计。
img = uint8(imgIn);
mode = lower(string(mode));

nPacketsLocal = numel(txPackets);
ok = normalize_packet_ok(packetOk, nPacketsLocal);
if nPacketsLocal <= 1 || all(ok)
    imgOut = img;
    return;
end

codec = get_payload_codec(payload);
if codec == "dct"
    mask = build_dct_pixel_mask_from_packets(ok, txPackets, meta, payload);
else
    mask = build_raw_pixel_mask_from_packets(ok, txPackets, meta);
end

imgOut = inpaint_image_by_mask(img, mask, mode);
end

function ok = normalize_packet_ok(packetOk, nPacketsLocal)
ok = logical(packetOk(:).');
if numel(ok) < nPacketsLocal
    ok = [ok, false(1, nPacketsLocal - numel(ok))];
elseif numel(ok) > nPacketsLocal
    ok = ok(1:nPacketsLocal);
end
end

function mask = build_raw_pixel_mask_from_packets(packetOk, txPackets, meta)
rows = double(meta.rows);
cols = double(meta.cols);
ch = double(meta.channels);
nElems = rows * cols * ch;

maskLinear = false(nElems, 1);
for pktIdx = 1:numel(txPackets)
    if packetOk(pktIdx)
        continue;
    end
    startByte = floor((double(txPackets(pktIdx).startBit) - 1) / 8) + 1;
    endByte = ceil(double(txPackets(pktIdx).endBit) / 8);
    startByte = max(1, min(nElems, startByte));
    endByte = max(1, min(nElems, endByte));
    if endByte >= startByte
        maskLinear(startByte:endByte) = true;
    end
end

if ch == 1
    mask = reshape(maskLinear, rows, cols);
else
    mask = reshape(maskLinear, rows, cols, ch);
end
end

function mask = build_dct_pixel_mask_from_packets(packetOk, txPackets, meta, payload)
rows = double(meta.rows);
cols = double(meta.cols);
ch = double(meta.channels);

dctCfg = struct();
if isfield(payload, "dct") && isstruct(payload.dct)
    dctCfg = payload.dct;
end
if ~isfield(dctCfg, "blockSize"); dctCfg.blockSize = 8; end
if ~isfield(dctCfg, "keepRows"); dctCfg.keepRows = 4; end
if ~isfield(dctCfg, "keepCols"); dctCfg.keepCols = 4; end
dctCfg.blockSize = max(2, round(double(dctCfg.blockSize)));
dctCfg.keepRows = max(1, round(double(dctCfg.keepRows)));
dctCfg.keepCols = max(1, round(double(dctCfg.keepCols)));
dctCfg.keepRows = min(dctCfg.keepRows, dctCfg.blockSize);
dctCfg.keepCols = min(dctCfg.keepCols, dctCfg.blockSize);

B = dctCfg.blockSize;
nBr = ceil(rows / B);
nBc = ceil(cols / B);
nBlocksPerCh = nBr * nBc;
totalBlocks = nBlocksPerCh * ch;
bytesPerBlock = dctCfg.keepRows * dctCfg.keepCols * 2;

maskBlocks = false(nBr, nBc, ch);
for pktIdx = 1:numel(txPackets)
    if packetOk(pktIdx)
        continue;
    end
    startByte = floor((double(txPackets(pktIdx).startBit) - 1) / 8) + 1;
    endByte = ceil(double(txPackets(pktIdx).endBit) / 8);
    startBlk = floor((startByte - 1) / bytesPerBlock) + 1;
    endBlk = floor((endByte - 1) / bytesPerBlock) + 1;
    startBlk = max(1, min(totalBlocks, startBlk));
    endBlk = max(1, min(totalBlocks, endBlk));

    for blk = startBlk:endBlk
        cc = floor((blk - 1) / nBlocksPerCh) + 1;
        local = mod(blk - 1, nBlocksPerCh) + 1;
        br = floor((local - 1) / nBc) + 1;
        bc = mod(local - 1, nBc) + 1;
        maskBlocks(br, bc, cc) = true;
    end
end

if ch == 1
    mask = false(rows, cols);
else
    mask = false(rows, cols, ch);
end

for cc = 1:ch
    for br = 1:nBr
        rIdx = (br-1)*B + (1:B);
        rIdx = rIdx(rIdx <= rows);
        for bc = 1:nBc
            if ~maskBlocks(br, bc, cc)
                continue;
            end
            cIdx = (bc-1)*B + (1:B);
            cIdx = cIdx(cIdx <= cols);
            if ch == 1
                mask(rIdx, cIdx) = true;
            else
                mask(rIdx, cIdx, cc) = true;
            end
        end
    end
end
end

function imgOut = inpaint_image_by_mask(imgIn, mask, mode)
img = double(imgIn);
if ndims(img) == 2
    img = reshape(img, size(img, 1), size(img, 2), 1);
end
if ndims(mask) == 2
    mask = reshape(mask, size(mask, 1), size(mask, 2), 1);
end

ch = size(img, 3);
for cc = 1:ch
    img(:, :, cc) = inpaint_plane(img(:, :, cc), logical(mask(:, :, min(cc, size(mask, 3)))), mode);
end

img = uint8(min(max(round(img), 0), 255));
if size(imgIn, 3) == 1
    imgOut = img(:, :, 1);
else
    imgOut = img;
end
end

function planeOut = inpaint_plane(planeIn, missingMask, mode)
known = ~missingMask;
plane = double(planeIn);
if all(known(:))
    planeOut = plane;
    return;
end
if ~any(known(:))
    planeOut = plane;
    return;
end

mode = lower(string(mode));
maxIter = size(plane, 1) + size(plane, 2);

for it = 1:maxIter
    missing = ~known;
    if ~any(missing(:))
        break;
    end

    leftKnown = [known(:, 1), known(:, 1:end-1)];
    rightKnown = [known(:, 2:end), known(:, end)];
    upKnown = [known(1, :); known(1:end-1, :)];
    downKnown = [known(2:end, :); known(end, :)];

    leftVal = [plane(:, 1), plane(:, 1:end-1)];
    rightVal = [plane(:, 2:end), plane(:, end)];
    upVal = [plane(1, :); plane(1:end-1, :)];
    downVal = [plane(2:end, :); plane(end, :)];

    neighCount = double(leftKnown) + double(rightKnown) + double(upKnown) + double(downKnown);
    canFill = missing & (neighCount > 0);
    if ~any(canFill(:))
        break;
    end

    fillVals = zeros(size(plane));
    switch mode
        case "nearest"
            assigned = false(size(plane));
            cand = canFill & leftKnown;
            fillVals(cand) = leftVal(cand);
            assigned = assigned | cand;

            cand = canFill & ~assigned & rightKnown;
            fillVals(cand) = rightVal(cand);
            assigned = assigned | cand;

            cand = canFill & ~assigned & upKnown;
            fillVals(cand) = upVal(cand);
            assigned = assigned | cand;

            cand = canFill & ~assigned & downKnown;
            fillVals(cand) = downVal(cand);
            assigned = assigned | cand;

            rem = canFill & ~assigned;
            if any(rem(:))
                sumVals = double(leftKnown) .* leftVal + double(rightKnown) .* rightVal + ...
                    double(upKnown) .* upVal + double(downKnown) .* downVal;
                fillVals(rem) = sumVals(rem) ./ max(neighCount(rem), 1);
            end

        otherwise % "blend"
            sumVals = double(leftKnown) .* leftVal + double(rightKnown) .* rightVal + ...
                double(upKnown) .* upVal + double(downKnown) .* downVal;
            fillVals(canFill) = sumVals(canFill) ./ max(neighCount(canFill), 1);
    end

    plane(canFill) = fillVals(canFill);
    known(canFill) = true;
end

if any(~known(:))
    fillVal = mean(plane(known));
    plane(~known) = fillVal;
end

planeOut = plane;
end

function fhOut = make_partial_fh_config(fhIn)
% 构造Eve“部分已知”场景：扰动序列种子/频点映射。
fhOut = fhIn;
seqType = "pn";
if isfield(fhOut, "sequenceType")
    seqType = lower(string(fhOut.sequenceType));
end
switch seqType
    case "pn"
        if isfield(fhOut, "pnInit") && ~isempty(fhOut.pnInit)
            fhOut.pnInit = circshift(fhOut.pnInit, 2);
            if all(fhOut.pnInit == 0)
                fhOut.pnInit(1) = 1;
            end
        end
    case {"chaos", "chaotic"}
        if ~isfield(fhOut, "chaosMethod") || strlength(string(fhOut.chaosMethod)) == 0
            fhOut.chaosMethod = "logistic";
        end
        if ~isfield(fhOut, "chaosParams") || ~isstruct(fhOut.chaosParams)
            fhOut.chaosParams = struct();
        end
        chaosMethod = lower(string(fhOut.chaosMethod));
        switch chaosMethod
            case {"logistic", "tent"}
                if ~isfield(fhOut.chaosParams, "x0") || isempty(fhOut.chaosParams.x0)
                    fhOut.chaosParams.x0 = 0.1234567890123456;
                end
                fhOut.chaosParams.x0 = wrap_unit_interval(double(fhOut.chaosParams.x0) + 1e-10);
            case "henon"
                if ~isfield(fhOut.chaosParams, "x0") || isempty(fhOut.chaosParams.x0)
                    fhOut.chaosParams.x0 = 0.1;
                end
                if ~isfield(fhOut.chaosParams, "y0") || isempty(fhOut.chaosParams.y0)
                    fhOut.chaosParams.y0 = 0.1;
                end
                fhOut.chaosParams.x0 = wrap_unit_interval(double(fhOut.chaosParams.x0) + 1e-10);
                fhOut.chaosParams.y0 = wrap_unit_interval(double(fhOut.chaosParams.y0) + 2e-10);
            otherwise
                if isfield(fhOut.chaosParams, "x0") && ~isempty(fhOut.chaosParams.x0)
                    fhOut.chaosParams.x0 = wrap_unit_interval(double(fhOut.chaosParams.x0) + 1e-10);
                end
        end
    otherwise
        if isfield(fhOut, "freqSet") && numel(fhOut.freqSet) > 1
            fhOut.freqSet = circshift(fhOut.freqSet, 1);
        end
end
end

function x = wrap_unit_interval(x)
x = mod(double(x), 1.0);
if x <= 0
    x = x + eps;
elseif x >= 1
    x = 1 - eps;
end
end

function [klSN, klNS, klSymVal] = signal_noise_kl(sig, N0, nBins)
% 比较跳频信号幅度分布与背景噪声幅度（Rayleigh）分布。
sig = sig(:);
if isempty(sig) || ~isfinite(N0) || N0 <= 0
    klSN = NaN;
    klNS = NaN;
    klSymVal = NaN;
    return;
end

magSig = abs(double(sig));
if all(~isfinite(magSig))
    klSN = NaN;
    klNS = NaN;
    klSymVal = NaN;
    return;
end
magSig = magSig(isfinite(magSig));
if isempty(magSig)
    klSN = NaN;
    klNS = NaN;
    klSymVal = NaN;
    return;
end

sigma = sqrt(max(double(N0), eps) / 2);
rMax = max(max(magSig) * 1.05, 6 * sigma);
if ~isfinite(rMax) || rMax <= 0
    klSN = NaN;
    klNS = NaN;
    klSymVal = NaN;
    return;
end

nBins = max(16, round(double(nBins)));
edges = linspace(0, rMax, nBins + 1);
pSig = histcounts(magSig, edges, "Normalization", "probability");

centers = 0.5 * (edges(1:end-1) + edges(2:end));
binWidth = diff(edges);
pNoisePdf = (centers ./ (sigma.^2)) .* exp(-(centers.^2) ./ (2 * sigma.^2));
pNoise = pNoisePdf .* binWidth;

epsProb = 1e-12;
pSig = pSig + epsProb;
pNoise = pNoise + epsProb;
pSig = pSig / sum(pSig);
pNoise = pNoise / sum(pNoise);

klSN = sum(pSig .* log(pSig ./ pNoise));
klNS = sum(pNoise .* log(pNoise ./ pSig));
klSymVal = 0.5 * (klSN + klNS);
end
