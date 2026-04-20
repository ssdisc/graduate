function s = make_summary(results)
%MAKE_SUMMARY  生成用于控制台显示的紧凑摘要。
%
% 输入:
%   results - 仿真结果结构体
%             .methods, .ebN0dB, .ber
%             .imageMetrics.resized/original.communication/.compensated
%             .kl（含signalVsNoise/noiseVsSignal/symmetric）
%             .spectrum（含bw99Hz, etaBpsHz）, .tx（可选）, .linkBudget（可选）
%             .eve（可选）, .covert.warden（可选）
%
% 输出:
%   s - 摘要结构体（便于控制台展示）

s = struct();
s.methods = results.methods;
s.ebN0dB = results.ebN0dB;
s.jsrDb = results.jsrDb;
if isfield(results, "scan")
    s.scan = results.scan;
end
if isfield(results, "params") && isfield(results.params, "outerRs")
    s.outerRs = results.params.outerRs;
end
if isfield(results, "params") && isfield(results.params, "dsss")
    s.dsss = results.params.dsss;
end
imageMetrics = local_get_image_metrics(results);
s.berAtMaxEbN0 = results.ber(:, end);
s.perAtMaxEbN0 = results.per(:, end);
s.originalCommMseAtMaxEbN0 = imageMetrics.original.communication.mse(:, end);
s.originalCommPsnrAtMaxEbN0 = imageMetrics.original.communication.psnr(:, end);
s.originalCommSsimAtMaxEbN0 = imageMetrics.original.communication.ssim(:, end);
s.originalCompMseAtMaxEbN0 = imageMetrics.original.compensated.mse(:, end);
s.originalCompPsnrAtMaxEbN0 = imageMetrics.original.compensated.psnr(:, end);
s.originalCompSsimAtMaxEbN0 = imageMetrics.original.compensated.ssim(:, end);
s.resizedCommMseAtMaxEbN0 = imageMetrics.resized.communication.mse(:, end);
s.resizedCommPsnrAtMaxEbN0 = imageMetrics.resized.communication.psnr(:, end);
s.resizedCommSsimAtMaxEbN0 = imageMetrics.resized.communication.ssim(:, end);
s.resizedCompMseAtMaxEbN0 = imageMetrics.resized.compensated.mse(:, end);
s.resizedCompPsnrAtMaxEbN0 = imageMetrics.resized.compensated.psnr(:, end);
s.resizedCompSsimAtMaxEbN0 = imageMetrics.resized.compensated.ssim(:, end);
s.lastPointEbN0dB = results.ebN0dB(end);
s.lastPointJsrDb = results.jsrDb(end);
s.packetConcealActive = false;
if isfield(results, "packetConceal") && isfield(results.packetConceal, "active")
    s.packetConcealActive = logical(results.packetConceal.active);
end
if isfield(results, "packetDiagnostics") && isfield(results.packetDiagnostics, "bob")
    bobDiag = results.packetDiagnostics.bob;
    if isfield(bobDiag, "frontEndSuccessRate")
        s.frontEndSuccessRateAtMaxEbN0 = bobDiag.frontEndSuccessRate(end);
    end
    if isfield(bobDiag, "headerSuccessRate")
        s.headerSuccessRateAtMaxEbN0 = bobDiag.headerSuccessRate(end);
    end
    if isfield(bobDiag, "payloadSuccessRate")
        s.payloadSuccessRateAtMaxEbN0 = bobDiag.payloadSuccessRate(:, end);
    end
end
s.klSymAtMaxEbN0 = results.kl.symmetric(end);
if isfield(results, "tx")
    s.txBurstDurationSec = results.tx.burstDurationSec;
    s.txBaseAveragePowerLin = results.tx.baseAveragePowerLin;
    s.txBaseAveragePowerDb = results.tx.baseAveragePowerDb;
    s.txAveragePowerLin = results.tx.averagePowerLin;
    s.txAveragePowerDb = results.tx.averagePowerDb;
    s.txPeakPowerLin = results.tx.peakPowerLin;
    s.txPeakPowerDb = results.tx.peakPowerDb;
    s.txConfiguredPowerLin = results.tx.configuredPowerLin;
    s.txConfiguredPowerDb = results.tx.configuredPowerDb;
    s.txPowerErrorLin = results.tx.powerErrorLin;
    s.txPowerErrorDb = results.tx.powerErrorDb;
end
if isfield(results, "linkBudget")
    if isfield(results.linkBudget, "bob") && isfield(results.linkBudget.bob, "txPowerDb")
        s.linkBudgetBobTxPowerDb = results.linkBudget.bob.txPowerDb;
    end
end

if isfield(results, "eve")
    s.eveEbN0dB = results.eve.ebN0dB;
    s.eveJsrDb = results.jsrDb;
    if isfield(results.eve, "assumptions")
        s.eveAssumptions = results.eve.assumptions;
    end
    imageMetricsEve = local_get_image_metrics(results.eve);
    s.eveBerAtMaxEbN0 = results.eve.ber(:, end);
    s.evePerAtMaxEbN0 = results.eve.per(:, end);
    s.eveOriginalCommMseAtMaxEbN0 = imageMetricsEve.original.communication.mse(:, end);
    s.eveOriginalCommPsnrAtMaxEbN0 = imageMetricsEve.original.communication.psnr(:, end);
    s.eveOriginalCommSsimAtMaxEbN0 = imageMetricsEve.original.communication.ssim(:, end);
    s.eveOriginalCompMseAtMaxEbN0 = imageMetricsEve.original.compensated.mse(:, end);
    s.eveOriginalCompPsnrAtMaxEbN0 = imageMetricsEve.original.compensated.psnr(:, end);
    s.eveOriginalCompSsimAtMaxEbN0 = imageMetricsEve.original.compensated.ssim(:, end);
    s.eveResizedCommMseAtMaxEbN0 = imageMetricsEve.resized.communication.mse(:, end);
    s.eveResizedCommPsnrAtMaxEbN0 = imageMetricsEve.resized.communication.psnr(:, end);
    s.eveResizedCommSsimAtMaxEbN0 = imageMetricsEve.resized.communication.ssim(:, end);
    s.eveResizedCompMseAtMaxEbN0 = imageMetricsEve.resized.compensated.mse(:, end);
    s.eveResizedCompPsnrAtMaxEbN0 = imageMetricsEve.resized.compensated.psnr(:, end);
    s.eveResizedCompSsimAtMaxEbN0 = imageMetricsEve.resized.compensated.ssim(:, end);
    if isfield(results.eve, "packetDiagnostics")
        eveDiag = results.eve.packetDiagnostics;
        if isfield(eveDiag, "frontEndSuccessRate")
            s.eveFrontEndSuccessRateAtMaxEbN0 = eveDiag.frontEndSuccessRate(end);
        end
        if isfield(eveDiag, "headerSuccessRate")
            s.eveHeaderSuccessRateAtMaxEbN0 = eveDiag.headerSuccessRate(end);
        end
        if isfield(eveDiag, "payloadSuccessRate")
            s.evePayloadSuccessRateAtMaxEbN0 = eveDiag.payloadSuccessRate(:, end);
        end
    end
end

if isfield(results, "covert") && isfield(results.covert, "warden")
    w = results.covert.warden;
    primaryLayer = local_get_primary_warden_layer(w);
    s.wardenPrimaryLayer = primaryLayer;
    primaryLayerField = char(primaryLayer);
    if isfield(w, "layers") && isfield(w.layers, primaryLayerField)
        layer = w.layers.(primaryLayerField);
        s.wardenPdAtMaxPoint = layer.pd(end);
        s.wardenPmdAtMaxPoint = layer.pmd(end);
        s.wardenXiAtMaxPoint = layer.xi(end);
        s.wardenPeAtMaxPoint = layer.pe(end);
    else
        s.wardenPdAtMaxPoint = w.pdEst(end);
        if isfield(w, "pmdEst")
            s.wardenPmdAtMaxPoint = w.pmdEst(end);
            s.wardenXiAtMaxPoint = w.xiEst(end);
        end
        s.wardenPeAtMaxPoint = w.peEst(end);
    end
    if isfield(w, "layers") && isfield(w.layers, "energyNp")
        s.wardenNpPdAtMaxPoint = w.layers.energyNp.pd(end);
        s.wardenNpPeAtMaxPoint = w.layers.energyNp.pe(end);
    end
    if isfield(w, "layers") && isfield(w.layers, "energyFhNarrow")
        s.wardenFhNarrowXiAtMaxPoint = w.layers.energyFhNarrow.xi(end);
        s.wardenFhNarrowPeAtMaxPoint = w.layers.energyFhNarrow.pe(end);
    end
    if isfield(w, "layers") && isfield(w.layers, "cyclostationaryOpt")
        s.wardenCycloXiAtMaxPoint = w.layers.cyclostationaryOpt.xi(end);
        s.wardenCycloPeAtMaxPoint = w.layers.cyclostationaryOpt.pe(end);
    end
end

s.spectrum99ObwHz = results.spectrum.bw99Hz;
s.spectralEfficiency = results.spectrum.etaBpsHz;
if isfield(results.spectrum, "burstBw99Hz")
    s.burstSpectrum99ObwHz = results.spectrum.burstBw99Hz;
end
if isfield(results.spectrum, "burstEtaBpsHz")
    s.burstSpectralEfficiency = results.spectrum.burstEtaBpsHz;
end
if isfield(results.spectrum, "basebandBw99Hz")
    s.basebandSpectrum99ObwHz = results.spectrum.basebandBw99Hz;
end
if isfield(results.spectrum, "basebandEtaBpsHz")
    s.basebandSpectralEfficiency = results.spectrum.basebandEtaBpsHz;
end
end

function imageMetrics = local_get_image_metrics(results)
if ~(isfield(results, "imageMetrics") && isstruct(results.imageMetrics))
    error("make_summary:MissingImageMetrics", "results.imageMetrics is required.");
end
requiredRefs = ["resized" "original"];
requiredStates = ["communication" "compensated"];
for refIdx = 1:numel(requiredRefs)
    refName = requiredRefs(refIdx);
    if ~(isfield(results.imageMetrics, refName) && isstruct(results.imageMetrics.(refName)))
        error("make_summary:MissingImageMetricReference", ...
            "results.imageMetrics.%s is required.", refName);
    end
    for stateIdx = 1:numel(requiredStates)
        stateName = requiredStates(stateIdx);
        if ~(isfield(results.imageMetrics.(refName), stateName) && isstruct(results.imageMetrics.(refName).(stateName)))
            error("make_summary:MissingImageMetricState", ...
                "results.imageMetrics.%s.%s is required.", refName, stateName);
        end
    end
end
imageMetrics = results.imageMetrics;
end

function layerName = local_get_primary_warden_layer(w)
layerName = "energyNp";
if isfield(w, "primaryLayer") && strlength(string(w.primaryLayer)) > 0
    layerName = string(w.primaryLayer);
end
end
