function [txClean, rxInput, impMask, impScore] = ml_simulate_training_chain(txSym, p, N0, targetLen)
%ML_SIMULATE_TRAINING_CHAIN  Generate paired raw-sample training windows on the new RX architecture.
%
% 输出:
%   txClean - 不含脉冲的“干净”复基带样本窗口（保留同一次随机噪声/干扰/信道实现）
%   rxInput - 含脉冲的接收复基带样本窗口
%   impMask - 样本级脉冲真值掩码
%   impScore- 样本级连续得分（当前直接等于 double(impMask)）

arguments
    txSym (:,1)
    p (1,1) struct
    N0 (1,1) double {mustBeNonnegative}
    targetLen (1,1) double {mustBeInteger, mustBePositive}
end

txSym = txSym(:);
targetLen = round(double(targetLen));

waveform = resolve_waveform_cfg(p);
channelSample = adapt_channel_for_sps(p.channel, waveform);

txChannelSym = txSym;
dsssCfg = derive_packet_dsss_cfg(p.dsss, 1, 0, numel(txSym));
[txChannelSym, ~] = dsss_spread(txChannelSym, dsssCfg);
if isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "enable") && p.fh.enable
    [txChannelSym, ~] = fh_modulate(txChannelSym, p.fh);
end

txSample = pulse_tx_from_symbol_rate(txChannelSym, waveform);
cleanChannel = channelSample;
cleanChannel.impulseProb = 0;

rngState = rng;
[rxInputFull, impMaskFull] = channel_bg_impulsive(txSample, N0, channelSample);
rng(rngState);
[txCleanFull, ~] = channel_bg_impulsive(txSample, N0, cleanChannel);
impScoreFull = abs(rxInputFull - txCleanFull) / sqrt(max(N0, eps));

[txClean, rxInput, impMask, impScore] = local_crop_training_window( ...
    txCleanFull, rxInputFull, logical(impMaskFull(:)), impScoreFull(:), waveform, targetLen);
end

function [txClean, rxInput, impMask, impScore] = local_crop_training_window(txCleanFull, rxInputFull, impMaskFull, impScoreFull, waveform, targetLen)
txCleanFull = txCleanFull(:);
rxInputFull = rxInputFull(:);
impMaskFull = logical(impMaskFull(:));
impScoreFull = double(impScoreFull(:));
if ~(numel(txCleanFull) == numel(rxInputFull) ...
        && numel(rxInputFull) == numel(impMaskFull) ...
        && numel(impMaskFull) == numel(impScoreFull))
    error("训练链输出长度不一致，无法裁剪统一窗口。");
end

guard = 0;
if isstruct(waveform) && isfield(waveform, "enable") && waveform.enable ...
        && isfield(waveform, "groupDelaySamples")
    guard = max(0, round(double(waveform.groupDelaySamples)));
end

startMin = 1 + guard;
startMax = numel(rxInputFull) - guard - targetLen + 1;
if startMax < startMin
    error("训练窗口长度 %d 超出可用采样长度 %d（guard=%d）。请增大训练符号数或减小 blockLen。", ...
        targetLen, numel(rxInputFull), guard);
end

if startMax == startMin
    startIdx = startMin;
else
    startIdx = randi([startMin, startMax], 1, 1);
end
stopIdx = startIdx + targetLen - 1;

txClean = txCleanFull(startIdx:stopIdx);
rxInput = rxInputFull(startIdx:stopIdx);
impMask = impMaskFull(startIdx:stopIdx);
impScore = impScoreFull(startIdx:stopIdx);
end
