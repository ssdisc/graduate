function [psd, f, bw99, eta] = estimate_spectrum(sym, modInfo)
%ESTIMATE_SPECTRUM  估计PSD和99%占用带宽。
%
% 输入:
%   sym     - 基带符号序列
%   modInfo - 调制信息结构体
%             .bitsPerSymbol - 每符号比特数
%             .codeRate      - 码率
%
% 输出:
%   psd  - 功率谱密度估计
%   f    - 频率轴（Hz）
%   bw99 - 99%占用带宽（Hz）
%   eta  - 频谱效率（bit/s/Hz）

Rs = 10e3;      % 参考图的符号速率（Hz）
sps = 8;        % 每符号采样数
rolloff = 0.25; % 滚降系数
span = 10;      % 符号数
Fs = Rs * sps;  % 采样频率

rrc = rcosdesign(rolloff, span, sps, "sqrt");
wave = upfirdn(sym(:), rrc, sps, 1);

[psd, f] = pwelch(wave, 4096, [], 4096, Fs, "centered");
try
    [bwTmp, flo, ~] = obw(wave, Fs); % 默认是99%占用带宽
    % 对于实值基带，obw()报告单边带宽；转换为双边。
    if isreal(wave) && flo >= 0
        bw99 = 2 * bwTmp;
    else
        bw99 = bwTmp;
    end
catch
    bw99 = NaN;
end

Rb = Rs * modInfo.bitsPerSymbol * modInfo.codeRate; % 信息比特率
eta = Rb / bw99;
end

