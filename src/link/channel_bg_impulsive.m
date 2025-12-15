function [y, impMask] = channel_bg_impulsive(x, N0, ch)
%CHANNEL_BG_IMPULSIVE  AWGN + 伯努利-高斯脉冲噪声信道。

x = x(:);
nBg = sqrt(N0/2) * (randn(size(x)) + 1j*randn(size(x)));

impMask = rand(size(x)) < ch.impulseProb;
N0imp = ch.impulseToBgRatio * N0;
nImp = sqrt(N0imp/2) * (randn(size(x)) + 1j*randn(size(x)));

y = x + nBg + impMask .* nImp;
end
