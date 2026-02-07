function [y, impMask] = channel_bg_impulsive(x, N0, ch)
%CHANNEL_BG_IMPULSIVE  AWGN + 伯努利-高斯脉冲噪声信道。
%
% 输入:
%   x  - 输入符号（列向量）
%   N0 - 背景噪声功率谱密度
%   ch - 信道参数结构体
%        .impulseProb      - 脉冲噪声出现概率
%        .impulseToBgRatio - 脉冲噪声功率与背景噪声功率比
%
% 输出:
%   y       - 加噪后符号
%   impMask - 脉冲样本掩码（logical）

x = x(:);
nBg = sqrt(N0/2) * (randn(size(x)) + 1j*randn(size(x)));

impMask = rand(size(x)) < ch.impulseProb;
N0imp = ch.impulseToBgRatio * N0;
nImp = sqrt(N0imp/2) * (randn(size(x)) + 1j*randn(size(x)));

y = x + nBg + impMask .* nImp;
end
