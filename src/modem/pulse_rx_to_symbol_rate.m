function ySym = pulse_rx_to_symbol_rate(ySample, waveform)
% 收端：匹配滤波 + 降采样回符号率。
y = ySample(:);
if ~waveform.enable
    ySym = y;
    return;
end

if waveform.rxMatchedFilter
    yMf = filter(waveform.rrcTaps(:), 1, y);
    totalGd = 2 * waveform.groupDelaySamples;
    if numel(yMf) <= totalGd
        ySym = complex(zeros(0, 1));
        return;
    end
    yMf = yMf(totalGd+1:end);
else
    yMf = y;
end

ySym = yMf(1:waveform.sps:end);
end

