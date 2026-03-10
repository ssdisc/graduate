function waveform = resolve_waveform_cfg(p)
% 统一解析波形成型参数，默认保持1 sps直通。
waveform = struct();
waveform.enable = false;
waveform.symbolRateHz = 10e3;
waveform.sps = 1;
waveform.rolloff = 0.25;
waveform.spanSymbols = 10;
waveform.rxMatchedFilter = true;

if isfield(p, "waveform") && isstruct(p.waveform)
    w = p.waveform;
    if isfield(w, "enable"); waveform.enable = logical(w.enable); end
    if isfield(w, "symbolRateHz"); waveform.symbolRateHz = max(eps, double(w.symbolRateHz)); end
    if isfield(w, "sps"); waveform.sps = max(1, round(double(w.sps))); end
    if isfield(w, "rolloff"); waveform.rolloff = max(0, min(double(w.rolloff), 1)); end
    if isfield(w, "spanSymbols"); waveform.spanSymbols = max(2, round(double(w.spanSymbols))); end
    if isfield(w, "rxMatchedFilter"); waveform.rxMatchedFilter = logical(w.rxMatchedFilter); end
end

if ~waveform.enable || waveform.sps <= 1
    waveform.enable = false;
    waveform.sps = 1;
    waveform.rolloff = 0.0;
    waveform.spanSymbols = 2;
    waveform.rrcTaps = 1;
    waveform.groupDelaySamples = 0;
    waveform.sampleRateHz = waveform.symbolRateHz;
    return;
end

if mod(waveform.spanSymbols, 2) ~= 0
    waveform.spanSymbols = waveform.spanSymbols + 1; % 对称RRC常用偶数跨度
end
waveform.rrcTaps = rcosdesign(waveform.rolloff, waveform.spanSymbols, waveform.sps, "sqrt");
waveform.groupDelaySamples = floor((numel(waveform.rrcTaps) - 1) / 2);
waveform.sampleRateHz = waveform.symbolRateHz * waveform.sps;
end

