function [txSym, rxSym, impSymMask] = ml_simulate_training_chain(txSym, p, N0)
%ML_SIMULATE_TRAINING_CHAIN  生成与主仿真一致的训练符号链路样本。
%
% 输入:
%   txSym      - 发端符号序列（列向量）
%   p          - default_params 风格配置
%   N0         - 背景噪声功率谱密度
%
% 输出:
%   txSym      - 对齐后的理想符号目标
%   rxSym      - 经过 waveform/channel/rx 处理后的接收符号
%   impSymMask - 对齐到符号率的脉冲影响掩码

txSym = txSym(:);
nSym = numel(txSym);

waveform = resolve_waveform_cfg(p);
channelSample = adapt_channel_for_sps(p.channel, waveform);

txChannelSym = txSym;
hopInfo = struct('enable', false);
if isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "enable") && p.fh.enable
    [txChannelSym, hopInfo] = fh_modulate(txChannelSym, p.fh);
end

txSample = pulse_tx_from_symbol_rate(txChannelSym, waveform);
[rxSample, impMaskSample] = channel_bg_impulsive(txSample, N0, channelSample);

rxSym = pulse_rx_to_symbol_rate(rxSample, waveform);
rxSym = local_fit_length(rxSym, nSym);

impScoreSym = pulse_rx_to_symbol_rate(double(impMaskSample(:)), waveform);
impScoreSym = local_fit_length(impScoreSym, nSym);
impSymMask = abs(impScoreSym) > 1e-9;

if isfield(hopInfo, "enable") && hopInfo.enable
    rxSym = fh_demodulate(rxSym, hopInfo);
end

if isfield(p, "rxSync") && isstruct(p.rxSync) ...
        && isfield(p.rxSync, "carrierPll") && isstruct(p.rxSync.carrierPll) ...
        && isfield(p.rxSync.carrierPll, "enable") && p.rxSync.carrierPll.enable
    rxSym = carrier_pll_sync(rxSym, p.mod, p.rxSync.carrierPll);
end
end

function y = local_fit_length(x, targetLen)
x = x(:);
targetLen = max(0, round(double(targetLen)));
if numel(x) >= targetLen
    y = x(1:targetLen);
else
    y = [x; complex(zeros(targetLen - numel(x), 1))];
end
end
