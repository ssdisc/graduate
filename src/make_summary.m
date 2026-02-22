function s = make_summary(results)
%MAKE_SUMMARY  生成用于控制台显示的紧凑摘要。
%
% 输入:
%   results - 仿真结果结构体
%             .methods, .ebN0dB, .ber, .psnr, .ssim
%             .spectrum（含bw99Hz, etaBpsHz）
%             .eve（可选）, .covert.warden（可选）
%
% 输出:
%   s - 摘要结构体（便于控制台展示）

s = struct();
s.methods = results.methods;
s.ebN0dB = results.ebN0dB;
s.berAtMaxEbN0 = results.ber(:, end);
s.psnrAtMaxEbN0 = results.psnr(:, end);

if isfield(results, "eve")
    s.eveEbN0dB = results.eve.ebN0dB;
    s.eveBerAtMaxEbN0 = results.eve.ber(:, end);
    s.evePsnrAtMaxEbN0 = results.eve.psnr(:, end);
end

if isfield(results, "covert") && isfield(results.covert, "warden")
    w = results.covert.warden;
    s.wardenPdAtMaxPoint = w.pdEst(end);
    s.wardenPeAtMaxPoint = w.peEst(end);
end

s.spectrum99ObwHz = results.spectrum.bw99Hz;
s.spectralEfficiency = results.spectrum.etaBpsHz;
end
