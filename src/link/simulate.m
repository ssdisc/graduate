function results = simulate(p)
%SIMULATE  端到端链路仿真，包含脉冲噪声抑制和图像降噪。
%
% 返回包含BER/PSNR/PSD结果的结构体，启用时保存图形。
% 支持接收端图像降噪增强（通过p.denoise.enable启用）。

arguments
    p (1,1) struct
end

rng(p.rngSeed);
set(0, 'DefaultFigureVisible', 'off');

% 检查是否启用图像降噪
denoiseEnabled = isfield(p, 'denoise') && isfield(p.denoise, 'enable') && p.denoise.enable;
if denoiseEnabled
    if isfield(p.denoise, 'model') && ~isempty(p.denoise.model) && p.denoise.model.trained
        denoiseModel = p.denoise.model;
    else
        denoiseModel = ml_image_denoise_model();
        denoiseModel.trained = false;
    end
end

imgTx = load_source_image(p.source);
[payloadBits, meta] = image_to_payload_bits(imgTx, p.payload);

[~, preambleSym] = make_preamble(p.frame.preambleLength);
[headerBits, ~] = build_header_bits(meta, p.frame.magic16);

dataBitsTx = [headerBits; payloadBits];
dataBitsTxScr = scramble_bits(dataBitsTx, p.scramble);

codedBits = fec_encode(dataBitsTxScr, p.fec);
[codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);

[dataSymTx, modInfo] = modulate_bits(codedBitsInt, p.mod);

% 跳频调制（仅对数据符号，前导不跳频以便同步）
fhEnabled = isfield(p, 'fh') && isfield(p.fh, 'enable') && p.fh.enable;
if fhEnabled
    [dataSymTx, hopInfo] = fh_modulate(dataSymTx, p.fh);
else
    hopInfo = struct('enable', false);
end

txSym = [preambleSym; dataSymTx];

EbN0dBList = p.sim.ebN0dBList(:).';
methods = string(p.mitigation.methods(:).');

ber = nan(numel(methods), numel(EbN0dBList));
psnrVals = nan(numel(methods), numel(EbN0dBList));
ssimVals = nan(numel(methods), numel(EbN0dBList));

% 降噪后的PSNR/SSIM（如果启用）
if denoiseEnabled
    psnrDenoised = nan(numel(methods), numel(EbN0dBList));
    ssimDenoised = nan(numel(methods), numel(EbN0dBList));
end

example = struct();
headerLenBits = numel(headerBits);
exampleIdx = ceil(numel(EbN0dBList)/2);

eveEnabled = isfield(p, "eve") && isfield(p.eve, "enable") && p.eve.enable;
if eveEnabled
    if ~isfield(p.eve, "ebN0dBOffset"); p.eve.ebN0dBOffset = -6; end
    if ~isfield(p.eve, "scrambleAssumption"); p.eve.scrambleAssumption = "wrong_key"; end

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
end

wardenEnabled = isfield(p, "covert") && isfield(p.covert, "enable") && p.covert.enable ...
    && isfield(p.covert, "warden") && isfield(p.covert.warden, "enable") && p.covert.warden.enable;
if wardenEnabled
    wardenThreshold = nan(1, numel(EbN0dBList));
    wardenPfaEst = nan(1, numel(EbN0dBList));
    wardenPdEst = nan(1, numel(EbN0dBList));
    wardenPeEst = nan(1, numel(EbN0dBList));
    wardenNObs = nan(1, numel(EbN0dBList));
    wardenPfaTarget = NaN;
    wardenNTrials = NaN;
end

for ie = 1:numel(EbN0dBList)
    EbN0dB = EbN0dBList(ie);
    EbN0 = 10.^(EbN0dB/10);
    N0 = ebn0_to_n0(EbN0, modInfo.codeRate, modInfo.bitsPerSymbol, 1.0);

    if eveEnabled
        EbN0dBEve = EbN0dB + double(p.eve.ebN0dBOffset);
        EbN0Eve = 10.^(EbN0dBEve/10);
        N0Eve = ebn0_to_n0(EbN0Eve, modInfo.codeRate, modInfo.bitsPerSymbol, 1.0);
    end

    if wardenEnabled
        if eveEnabled
            det = warden_energy_detector(txSym, N0Eve, p.channel, p.channel.maxDelaySymbols, p.covert.warden);
        else
            det = warden_energy_detector(txSym, N0, p.channel, p.channel.maxDelaySymbols, p.covert.warden);
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

    % 降噪后的累加器
    if denoiseEnabled
        psnrAccDen = zeros(numel(methods), 1);
        ssimAccDen = zeros(numel(methods), 1);
        nPsnrDen = zeros(numel(methods), 1);
        nSsimDen = zeros(numel(methods), 1);
    end

    if eveEnabled
        nErrEve = zeros(numel(methods), 1);
        nTotEve = zeros(numel(methods), 1);
        psnrAccEve = zeros(numel(methods), 1);
        ssimAccEve = zeros(numel(methods), 1);
        nPsnrEve = zeros(numel(methods), 1);
        nSsimEve = zeros(numel(methods), 1);
    end

    for frameIdx = 1:p.sim.nFramesPerPoint
        delay = randi([0, p.channel.maxDelaySymbols], 1, 1);
        tx = [zeros(delay, 1); txSym];

        rx = channel_bg_impulsive(tx, N0, p.channel);
        if eveEnabled
            rxEve = channel_bg_impulsive(tx, N0Eve, p.channel);
        end

        bobOk = true;
        startIdx = frame_sync(rx, preambleSym);
        if isempty(startIdx)
            bobOk = false;
        else
            dataStart = startIdx + numel(preambleSym);
            dataStop = dataStart + numel(dataSymTx) - 1;
            if dataStop > numel(rx)
                bobOk = false;
            end
        end
        if bobOk
            rData = rx(dataStart:dataStop);
            % 跳频解调（Bob知道跳频序列）
            if fhEnabled
                rData = fh_demodulate(rData, hopInfo);
            end
        else
            nErr = nErr + numel(payloadBits);
            nTot = nTot + numel(payloadBits);
        end

        eveOk = false;
        if eveEnabled
            eveOk = true;
            startIdxEve = frame_sync(rxEve, preambleSym);
            if isempty(startIdxEve)
                eveOk = false;
            else
                dataStartEve = startIdxEve + numel(preambleSym);
                dataStopEve = dataStartEve + numel(dataSymTx) - 1;
                if dataStopEve > numel(rxEve)
                    eveOk = false;
                end
            end
            if eveOk
                rDataEve = rxEve(dataStartEve:dataStopEve);
                % Eve的跳频解调（根据Eve的知识假设）
                if fhEnabled
                    rDataEve = fh_demodulate(rDataEve, hopInfoEve);
                end
            else
                nErrEve = nErrEve + numel(payloadBits);
                nTotEve = nTotEve + numel(payloadBits);
            end
        end

        for im = 1:numel(methods)
            if bobOk
                [rMit, reliability] = mitigate_impulses(rData, methods(im), p.mitigation);

                demodSoft = demodulate_to_softbits(rMit, p.mod, p.fec, p.softMetric, reliability);
                demodDeint = deinterleave_bits(demodSoft, intState, p.interleaver);

                dataBitsRxScr = fec_decode(demodDeint, p.fec);
                dataBitsRx = descramble_bits(dataBitsRxScr, p.scramble);

                [payloadBitsRx, metaRx, okHeader] = parse_frame_bits(dataBitsRx, p.frame.magic16);
                if ~okHeader
                    nErr(im) = nErr(im) + numel(payloadBits);
                    nTot(im) = nTot(im) + numel(payloadBits);
                else
                    payloadBitsRx = payloadBitsRx(1:min(end, numel(payloadBits)));
                    payloadBitsTxTrunc = payloadBits(1:numel(payloadBitsRx));

                    nErr(im) = nErr(im) + sum(payloadBitsRx ~= payloadBitsTxTrunc);
                    nTot(im) = nTot(im) + numel(payloadBitsTxTrunc);

                    imgRx = payload_bits_to_image(payloadBitsRx, metaRx);

                    [psnrNow, ssimNow] = image_quality(imgTx, imgRx);
                    if ~isnan(psnrNow)
                        psnrAcc(im) = psnrAcc(im) + psnrNow;
                        nPsnr(im) = nPsnr(im) + 1;
                    end
                    if isfinite(ssimNow)
                        ssimAcc(im) = ssimAcc(im) + ssimNow;
                        nSsim(im) = nSsim(im) + 1;
                    end

                    % 图像降噪增强
                    if denoiseEnabled && denoiseModel.trained
                        imgRxDen = ml_image_denoise(imgRx, denoiseModel);
                        [psnrDen, ssimDen] = image_quality(imgTx, imgRxDen);
                        if ~isnan(psnrDen)
                            psnrAccDen(im) = psnrAccDen(im) + psnrDen;
                            nPsnrDen(im) = nPsnrDen(im) + 1;
                        end
                        if isfinite(ssimDen)
                            ssimAccDen(im) = ssimAccDen(im) + ssimDen;
                            nSsimDen(im) = nSsimDen(im) + 1;
                        end
                    else
                        imgRxDen = imgRx;
                    end

                    if frameIdx == 1 && ie == exampleIdx
                        example.(methods(im)).EbN0dB = EbN0dB;
                        example.(methods(im)).imgRx = imgRx;
                        if denoiseEnabled
                            example.(methods(im)).imgRxDenoised = imgRxDen;
                        end
                    end
                end
            end

            if eveEnabled && eveOk
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

                imgEve = payload_bits_to_image(payloadBitsEve, metaUse);

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

    ber(:, ie) = nErr ./ max(nTot, 1);

    psnrOut = nan(numel(methods), 1);
    ssimOut = nan(numel(methods), 1);
    validPsnr = nPsnr > 0;
    validSsim = nSsim > 0;
    psnrOut(validPsnr) = psnrAcc(validPsnr) ./ nPsnr(validPsnr);
    ssimOut(validSsim) = ssimAcc(validSsim) ./ nSsim(validSsim);
    psnrVals(:, ie) = psnrOut;
    ssimVals(:, ie) = ssimOut;

    % 降噪后的PSNR/SSIM
    if denoiseEnabled
        psnrOutDen = nan(numel(methods), 1);
        ssimOutDen = nan(numel(methods), 1);
        validPsnrDen = nPsnrDen > 0;
        validSsimDen = nSsimDen > 0;
        psnrOutDen(validPsnrDen) = psnrAccDen(validPsnrDen) ./ nPsnrDen(validPsnrDen);
        ssimOutDen(validSsimDen) = ssimAccDen(validSsimDen) ./ nSsimDen(validSsimDen);
        psnrDenoised(:, ie) = psnrOutDen;
        ssimDenoised(:, ie) = ssimOutDen;
    end

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
end

% 波形/频谱（单次突发，无信道）
[psd, freqHz, bw99Hz, etaBpsHz] = estimate_spectrum(txSym, modInfo);

results = struct();
results.params = p;
results.ebN0dB = EbN0dBList;
results.methods = methods;
results.ber = ber;
results.psnr = psnrVals;
results.ssim = ssimVals;
results.example = example;
results.spectrum = struct("freqHz", freqHz, "psd", psd, "bw99Hz", bw99Hz, "etaBpsHz", etaBpsHz);

% 添加降噪结果
if denoiseEnabled
    results.denoise = struct();
    results.denoise.enabled = true;
    results.denoise.modelTrained = denoiseModel.trained;
    results.denoise.psnr = psnrDenoised;
    results.denoise.ssim = ssimDenoised;
    % 计算降噪增益
    results.denoise.psnrGain = psnrDenoised - psnrVals;
    results.denoise.ssimGain = ssimDenoised - ssimVals;
else
    results.denoise = struct('enabled', false);
end

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
    outDir = make_results_dir(p.sim.resultsDir);
    save(fullfile(outDir, "results.mat"), "-struct", "results");
    save_figures(outDir, imgTx, results);
end

end
