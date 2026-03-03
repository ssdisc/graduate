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
% 返回包含BER/PSNR/PSD结果的结构体，启用时保存图形。

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

% 混沌加密（图像层面）
chaosEnabled = isfield(p, 'chaosEncrypt') && isfield(p.chaosEncrypt, 'enable') && p.chaosEncrypt.enable;
if chaosEnabled
    [imgTxEnc, chaosEncInfo] = chaos_encrypt(imgTx, p.chaosEncrypt);
else
    imgTxEnc = imgTx;
    chaosEncInfo = struct('enabled', false);
end 

[payloadBits, meta] = image_to_payload_bits(imgTxEnc, p.payload);%将图像转换为比特流载荷，并生成元数据（尺寸等）

[~, preambleSym] = make_preamble(p.frame.preambleLength);%生成PN前导
[headerBits, ~] = build_header_bits(meta, p.frame.magic16);%构建帧头比特流

dataBitsTx = [headerBits; payloadBits]; %帧头+载荷比特流
dataBitsTxScr = scramble_bits(dataBitsTx, p.scramble);%扰码（白化/轻量加密）

codedBits = fec_encode(dataBitsTxScr, p.fec);%信道编码（卷积码）
[codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);%块交织

[dataSymTx, modInfo] = modulate_bits(codedBitsInt, p.mod);%调制（BPSK/QPSK/16QAM等）
% 跳频调制（仅对数据符号，前导不跳频以便同步）

fhEnabled = isfield(p, 'fh') && isfield(p.fh, 'enable') && p.fh.enable;
if fhEnabled
    [dataSymTx, hopInfo] = fh_modulate(dataSymTx, p.fh);
else
    hopInfo = struct('enable', false);
end

txSym = [preambleSym; dataSymTx];%串联前导和数据符号形成完整帧
if p.rf.enable
    txSymForChannel = rf_upconvert(txSym, p.rf);
else
    txSymForChannel = txSym;
end

%% 仿真参数初始化与配置

EbN0dBList = p.sim.ebN0dBList(:).';%仿真不同Eb/N0点，列向量
methods = string(p.mitigation.methods(:).');%仿真不同脉冲噪声抑制方法，列向量

ber = nan(numel(methods), numel(EbN0dBList)); %比特错误率（BER）统计
psnrVals = nan(numel(methods), numel(EbN0dBList));%峰值信噪比（PSNR）评估图像质量
ssimVals = nan(numel(methods), numel(EbN0dBList));%结构相似性指数（SSIM）评估图像质量


example = struct();
headerLenBits = numel(headerBits);
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
if eveEnabled
    if ~isfield(p.eve, "ebN0dBOffset"); p.eve.ebN0dBOffset = -6; end
    if ~isfield(p.eve, "scrambleAssumption"); p.eve.scrambleAssumption = "wrong_key"; end
    if ~isfield(p.eve, "rfFreqOffsetNorm"); p.eve.rfFreqOffsetNorm = 0.0; end

    eveEbN0dBList = EbN0dBList + double(p.eve.ebN0dBOffset);
    berEve = nan(numel(methods), numel(EbN0dBList));
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

    % Eve对跳频的知识
    if ~isfield(p.eve, 'fhAssumption'); p.eve.fhAssumption = "none"; end
    switch lower(string(p.eve.fhAssumption))
        case "known"
            % Eve知道跳频序列，使用相同的hopInfo
            hopInfoEve = hopInfo;
        case "none"
            % Eve不知道跳频，不解跳
            hopInfoEve = struct('enable', false);
        case "partial"
            % Eve使用错误的跳频初始状态
            if fhEnabled
                fhEve = p.fh;
                fhEve.pnInit = circshift(fhEve.pnInit, 2);
                if all(fhEve.pnInit == 0)
                    fhEve.pnInit(1) = 1;
                end
                [~, hopInfoEve] = fh_modulate(dataSymTx, fhEve);
            else
                hopInfoEve = struct('enable', false);
            end
        otherwise
            error("Unknown eve.fhAssumption: %s", string(p.eve.fhAssumption));
    end

    % Eve对混沌加密的知识
    if ~isfield(p.eve, 'chaosAssumption'); p.eve.chaosAssumption = "none"; end
    switch lower(string(p.eve.chaosAssumption))
        case "known"
            % Eve知道混沌密钥（最佳截获情况）
            chaosEncInfoEve = chaosEncInfo;
        case "none"
            % Eve不知道混沌加密，不解密（看到的是加密图像）
            chaosEncInfoEve = struct('enabled', false);
        case "wrong_key"
            % Eve使用错误的混沌密钥
            if chaosEnabled
                chaosEncInfoEve = chaosEncInfo;
                chaosEncInfoEve.chaosParams.x0 = chaosEncInfo.chaosParams.x0 + 1e-10;  % 微小扰动
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
    psnrAcc = zeros(numel(methods), 1);
    ssimAcc = zeros(numel(methods), 1);
    nPsnr = zeros(numel(methods), 1);
    nSsim = zeros(numel(methods), 1);


    if eveEnabled
        nErrEve = zeros(numel(methods), 1);
        nTotEve = zeros(numel(methods), 1);
        psnrAccEve = zeros(numel(methods), 1);
        ssimAccEve = zeros(numel(methods), 1);
        nPsnrEve = zeros(numel(methods), 1);
        nSsimEve = zeros(numel(methods), 1);
    end

    % --- 帧循环：每个Eb/N0点仿真多帧 ---
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

        % ============ 信道（CHANNEL） ============
        delay = randi([0, p.channel.maxDelaySymbols], 1, 1);
        tx = [zeros(delay, 1); txSymForChannel];

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
        % ============ 接收端（RECEIVER）：Bob（合法接收方） ============
        bobOk = true;
        [startIdx, rxBobSync] = frame_sync(rx, preambleSym, syncCfgUse);
        if isempty(startIdx)
            bobOk = false;
        else
            dataStart = startIdx + numel(preambleSym);
            [rData, bobOk] = extract_fractional_block(rxBobSync, dataStart, numel(dataSymTx));
        end
        if bobOk
            % 跳频解调（Bob知道跳频序列）
            if fhEnabled
                rData = fh_demodulate(rData, hopInfo);
            end
            % 决策导向载波PLL跟踪残余相位/频偏
            if p.rxSync.carrierPll.enable
                rData = carrier_pll_sync(rData, p.mod, p.rxSync.carrierPll);
            end
        else
            fprintf('[SIM][WARN] Bob帧同步失败: Eb/N0=%.2f dB, frame=%d\n', EbN0dB, frameIdx);
            nErr = nErr + numel(payloadBits);
            nTot = nTot + numel(payloadBits);
        end

        % ============ 接收端（RECEIVER）：Eve（窃听方） ============
        eveOk = false;
        if eveEnabled
            eveOk = true;
            [startIdxEve, rxEveSync] = frame_sync(rxEve, preambleSym, syncCfgUse);
            if isempty(startIdxEve)
                eveOk = false;
            else
                dataStartEve = startIdxEve + numel(preambleSym);
                [rDataEve, eveOk] = extract_fractional_block(rxEveSync, dataStartEve, numel(dataSymTx));
            end
            if eveOk
                % Eve的跳频解调（根据Eve的知识假设）
                if fhEnabled
                    rDataEve = fh_demodulate(rDataEve, hopInfoEve);
                end
                if p.rxSync.carrierPll.enable
                    rDataEve = carrier_pll_sync(rDataEve, p.mod, p.rxSync.carrierPll);
                end
            else
                fprintf('[SIM][WARN] Eve帧同步失败: Eb/N0=%.2f dB(Eve=%.2f dB), frame=%d\n', ...
                    EbN0dB, EbN0dBEve, frameIdx);
                nErrEve = nErrEve + numel(payloadBits);
                nTotEve = nTotEve + numel(payloadBits);
            end
        end

        % --- 遍历不同脉冲抑制方法进行接收端处理 ---
        for im = 1:numel(methods)
            if bobOk
                % -- Bob接收端：脉冲抑制、解调、解码、解密 --
                [rMit, reliability] = mitigate_impulses(rData, methods(im), p.mitigation);
                demodSoft = demodulate_to_softbits(rMit, p.mod, p.fec, p.softMetric, reliability);%软判决解调，生成带可靠性加权的Viterbi输入度量
                demodDeint = deinterleave_bits(demodSoft, intState, p.interleaver);%逆交织
                dataBitsRxScr = fec_decode(demodDeint, p.fec);%FEC解码（卷积码）
                dataBitsRx = descramble_bits(dataBitsRxScr, p.scramble);%解扰（与发送端相同的扰码配置）


                [payloadBitsRx, metaRx, okHeader] = parse_frame_bits(dataBitsRx, p.frame.magic16);%解析帧比特流，提取载荷比特和元数据（如图像尺寸等），并验证帧头（使用magic16作为同步标志）
                if ~okHeader
                    nErr(im) = nErr(im) + numel(payloadBits);
                    nTot(im) = nTot(im) + numel(payloadBits);
                else
                    payloadBitsRx = payloadBitsRx(1:min(end, numel(payloadBits)));%截断接收的载荷比特以匹配发送的载荷比特长度
                    payloadBitsTxTrunc = payloadBits(1:numel(payloadBitsRx));%截断发送的载荷比特以匹配接收的载荷比特长度（如果接收的载荷比特较少）

                    nErr(im) = nErr(im) + sum(payloadBitsRx ~= payloadBitsTxTrunc);
                    nTot(im) = nTot(im) + numel(payloadBitsTxTrunc);

                    imgRxEnc = payload_bits_to_image(payloadBitsRx, metaRx);

                    % 混沌解密（Bob知道密钥）
                    if chaosEnabled
                        imgRx = chaos_decrypt(imgRxEnc, chaosEncInfo);
                    else
                        imgRx = imgRxEnc;
                    end

                    [psnrNow, ssimNow] = image_quality(imgTx, imgRx);
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
                    end
                end
            end

            if eveEnabled && eveOk
                % -- Eve接收端：脉冲抑制、解调、解码（使用其知识假设） --
                [rMitEve, reliabilityEve] = mitigate_impulses(rDataEve, methods(im), p.mitigation);

                demodSoftEve = demodulate_to_softbits(rMitEve, p.mod, p.fec, p.softMetric, reliabilityEve);
                demodDeintEve = deinterleave_bits(demodSoftEve, intState, p.interleaver);

                dataBitsEveScr = fec_decode(demodDeintEve, p.fec);
                dataBitsEve = descramble_bits(dataBitsEveScr, scrambleEve);

                [payloadBitsEve, metaEve, okHeaderEve] = parse_frame_bits(dataBitsEve, p.frame.magic16);
                if okHeaderEve
                    metaUse = metaEve;
                else
                    metaUse = meta;
                    if numel(dataBitsEve) > headerLenBits
                        payloadBitsEve = dataBitsEve(headerLenBits+1:end);
                    else
                        payloadBitsEve = uint8([]);
                    end
                end

                payloadBitsEve = payloadBitsEve(1:min(end, numel(payloadBits)));
                payloadBitsTxTrunc = payloadBits(1:numel(payloadBitsEve));

                nErrEve(im) = nErrEve(im) + sum(payloadBitsEve ~= payloadBitsTxTrunc);
                nTotEve(im) = nTotEve(im) + numel(payloadBitsTxTrunc);

                imgEveEnc = payload_bits_to_image(payloadBitsEve, metaUse);

                % Eve的混沌解密（根据Eve的知识假设）
                if chaosEnabled && chaosEncInfoEve.enabled
                    imgEve = chaos_decrypt(imgEveEnc, chaosEncInfoEve);
                else
                    imgEve = imgEveEnc;  % Eve不解密或不知道密钥
                end

                [psnrNowEve, ssimNowEve] = image_quality(imgTx, imgEve);
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
                    exampleEve.(methods(im)).headerOk = okHeaderEve;
                    exampleEve.(methods(im)).imgRx = imgEve;
                end
            end
        end
    end

    % --- 当前Eb/N0点的性能统计 ---
    ber(:, ie) = nErr ./ max(nTot, 1);

    psnrOut = nan(numel(methods), 1);
    ssimOut = nan(numel(methods), 1);
    validPsnr = nPsnr > 0;
    validSsim = nSsim > 0;
    psnrOut(validPsnr) = psnrAcc(validPsnr) ./ nPsnr(validPsnr);
    ssimOut(validSsim) = ssimAcc(validSsim) ./ nSsim(validSsim);
    psnrVals(:, ie) = psnrOut;
    ssimVals(:, ie) = ssimOut;


    if eveEnabled
        berEve(:, ie) = nErrEve ./ max(nTotEve, 1);

        psnrOutEve = nan(numel(methods), 1);
        ssimOutEve = nan(numel(methods), 1);
        validPsnrEve = nPsnrEve > 0;
        validSsimEve = nSsimEve > 0;
        psnrOutEve(validPsnrEve) = psnrAccEve(validPsnrEve) ./ nPsnrEve(validPsnrEve);
        ssimOutEve(validSsimEve) = ssimAccEve(validSsimEve) ./ nSsimEve(validSsimEve);
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
results.psnr = psnrVals;
results.ssim = ssimVals;
results.example = example;
results.spectrum = struct("freqHz", freqHz, "psd", psd, "bw99Hz", bw99Hz, "etaBpsHz", etaBpsHz);


if eveEnabled
    results.eve = struct();
    results.eve.ebN0dB = eveEbN0dBList;
    results.eve.ber = berEve;
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
