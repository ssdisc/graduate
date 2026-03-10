function s = make_summary(results)
%MAKE_SUMMARY  生成用于控制台显示的紧凑摘要。
%
% 输入:
%   results - 仿真结果结构体
%             .methods, .ebN0dB, .ber
%             .imageMetrics.communication/.compensated（或兼容字段.mse/.psnr/.ssim）
%             .kl（含signalVsNoise/noiseVsSignal/symmetric）
%             .spectrum（含bw99Hz, etaBpsHz）
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
s.klSymAtMaxEbN0 = results.kl.symmetric(end);

if isfield(results, "eve")
    s.eveEbN0dB = results.eve.ebN0dB;
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
end

if isfield(results, "covert") && isfield(results.covert, "warden")
    w = results.covert.warden;
    s.wardenPdAtMaxPoint = w.pdEst(end);
    s.wardenPeAtMaxPoint = w.peEst(end);
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
