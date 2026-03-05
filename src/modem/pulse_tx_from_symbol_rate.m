function y = pulse_tx_from_symbol_rate(sym, waveform)
% 发端：符号率 -> 成型后采样率。
sym = sym(:);
if ~waveform.enable
    y = sym;
    return;
end

% 保留完整滤波瞬态，接收端统一补偿总群时延。
y = upfirdn(sym, waveform.rrcTaps(:), waveform.sps, 1);
end

