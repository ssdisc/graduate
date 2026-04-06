function s = make_summary(results)
%MAKE_SUMMARY  生成用于控制台显示的紧凑摘要。
%
% 输入:
%   results - 仿真结果结构体
%             .methods, .ebN0dB, .ber
%             .imageMetrics.communication/.compensated（或兼容字段.mse/.psnr/.ssim）
%             .kl（含signalVsNoise/noiseVsSignal/symmetric）
%             .spectrum（含bw99Hz, etaBpsHz）, .tx（可选）, .linkBudget（可选）
%             .eve（可选）, .covert.warden（可选）
%
% 输出:
%   s - 摘要结构体（便于控制台展示）

s = struct();
s.methods = results.methods;
s.ebN0dB = results.ebN0dB;
[commMetrics, compMetrics] = local_get_image_metrics(results);
s.berAtMaxEbN0 = results.ber(:, end);
s.mseAtMaxEbN0 = commMetrics.mse(:, end);
s.psnrAtMaxEbN0 = commMetrics.psnr(:, end);
s.ssimAtMaxEbN0 = commMetrics.ssim(:, end);
s.commMseAtMaxEbN0 = commMetrics.mse(:, end);
s.commPsnrAtMaxEbN0 = commMetrics.psnr(:, end);
s.commSsimAtMaxEbN0 = commMetrics.ssim(:, end);
s.compMseAtMaxEbN0 = compMetrics.mse(:, end);
s.compPsnrAtMaxEbN0 = compMetrics.psnr(:, end);
s.compSsimAtMaxEbN0 = compMetrics.ssim(:, end);
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
    if isfield(results.eve, "assumptions")
        s.eveAssumptions = results.eve.assumptions;
    end
    [commMetricsEve, compMetricsEve] = local_get_image_metrics(results.eve);
    s.eveBerAtMaxEbN0 = results.eve.ber(:, end);
    s.eveMseAtMaxEbN0 = commMetricsEve.mse(:, end);
    s.evePsnrAtMaxEbN0 = commMetricsEve.psnr(:, end);
    s.eveSsimAtMaxEbN0 = commMetricsEve.ssim(:, end);
    s.eveCommMseAtMaxEbN0 = commMetricsEve.mse(:, end);
    s.eveCommPsnrAtMaxEbN0 = commMetricsEve.psnr(:, end);
    s.eveCommSsimAtMaxEbN0 = commMetricsEve.ssim(:, end);
    s.eveCompMseAtMaxEbN0 = compMetricsEve.mse(:, end);
    s.eveCompPsnrAtMaxEbN0 = compMetricsEve.psnr(:, end);
    s.eveCompSsimAtMaxEbN0 = compMetricsEve.ssim(:, end);
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
end

function [commMetrics, compMetrics] = local_get_image_metrics(results)
commMetrics = struct("mse", results.mse, "psnr", results.psnr, "ssim", results.ssim);
compMetrics = commMetrics;

if isfield(results, "imageMetrics") && isstruct(results.imageMetrics)
    if isfield(results.imageMetrics, "communication")
        commMetrics = results.imageMetrics.communication;
    end
    if isfield(results.imageMetrics, "compensated")
        compMetrics = results.imageMetrics.compensated;
    end
end

if isfield(results, "mseCompensated")
    compMetrics.mse = results.mseCompensated;
end
if isfield(results, "psnrCompensated")
    compMetrics.psnr = results.psnrCompensated;
end
if isfield(results, "ssimCompensated")
    compMetrics.ssim = results.ssimCompensated;
end
end

function layerName = local_get_primary_warden_layer(w)
layerName = "energyNp";
if isfield(w, "primaryLayer") && strlength(string(w.primaryLayer)) > 0
    layerName = string(w.primaryLayer);
end
end
