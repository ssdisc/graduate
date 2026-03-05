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

[~, preambleSym] = make_preamble(p.frame.preambleLength);%生成PN前导

% 发送端按包构建（最小分包：pktIdx/totalPkts/payloadLen/CRC16）
[txPackets, txPlan] = build_tx_packets(payloadBits, meta, p, preambleSym, packetIndependentBitChaos, waveform);
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

% 波形成型启用时，将“按符号配置”的信道参数映射到“按采样配置”。
channelSample = adapt_channel_for_sps(p.channel, waveform.sps);
maxDelaySamples = max(0, round(double(p.channel.maxDelaySymbols) * waveform.sps));

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
            delaySym = randi([0, p.channel.maxDelaySymbols], 1, 1);
            delay = round(double(delaySym) * waveform.sps);
            tx = [zeros(delay, 1); pkt.txSymForChannel];

            rx = channel_bg_impulsive(tx, N0, channelSample);
            rx = pulse_rx_to_symbol_rate(rx, waveform);

            if eveEnabled
                rxEve = channel_bg_impulsive(tx, N0Eve, channelSample);
                rxEve = pulse_rx_to_symbol_rate(rxEve, waveform);
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

