function waveform = resolve_waveform_cfg(p)
% 统一解析波形成型参数，默认保持1 sps直通。
waveform = struct();
waveform.enable = false;
waveform.sampleRateHz = 10e3;
waveform.symbolRateHz = 10e3;
waveform.sps = 1;
waveform.rolloff = 0.25;
waveform.spanSymbols = 10;
waveform.rxMatchedFilter = true;
symbolRateProvided = NaN;
symbolRateProvidedPresent = false;

if isfield(p, "waveform") && isstruct(p.waveform)
    w = p.waveform;
    if isfield(w, "enable"); waveform.enable = logical(w.enable); end
    if isfield(w, "sampleRateHz"); waveform.sampleRateHz = max(eps, double(w.sampleRateHz)); end
    if isfield(w, "symbolRateHz")
        symbolRateProvided = double(w.symbolRateHz);
        symbolRateProvidedPresent = true;
    end
    if isfield(w, "sps"); waveform.sps = max(1, round(double(w.sps))); end
    if isfield(w, "rolloff"); waveform.rolloff = max(0, min(double(w.rolloff), 1)); end
    if isfield(w, "spanSymbols"); waveform.spanSymbols = max(2, round(double(w.spanSymbols))); end
    if isfield(w, "rxMatchedFilter"); waveform.rxMatchedFilter = logical(w.rxMatchedFilter); end
end

if ~(isfinite(double(waveform.sampleRateHz)) && double(waveform.sampleRateHz) > 0)
    error("waveform.sampleRateHz must be a positive finite scalar.");
end
if ~(isscalar(waveform.sps) && isfinite(double(waveform.sps)) && double(waveform.sps) >= 1)
    error("waveform.sps must be a positive integer scalar.");
end
waveform.sps = max(1, round(double(waveform.sps)));

if ~waveform.enable || waveform.sps <= 1
    waveform.enable = false;
    waveform.sps = 1;
    waveform.rolloff = 0.0;
    waveform.spanSymbols = 2;
    waveform.rrcTaps = 1;
    waveform.groupDelaySamples = 0;
    waveform.symbolRateHz = waveform.sampleRateHz;
    return;
end

waveform.symbolRateHz = waveform.sampleRateHz / waveform.sps;
if symbolRateProvidedPresent
    if ~(isfinite(symbolRateProvided) && symbolRateProvided > 0)
        error("waveform.symbolRateHz must be a positive finite scalar when provided.");
    end
    if abs(symbolRateProvided - waveform.symbolRateHz) > max(1e-9, 1e-9 * waveform.symbolRateHz)
        error("waveform.symbolRateHz is now derived from waveform.sampleRateHz / waveform.sps. Expected %.12g, got %.12g.", ...
            waveform.symbolRateHz, symbolRateProvided);
    end
end

if mod(waveform.spanSymbols, 2) ~= 0
    waveform.spanSymbols = waveform.spanSymbols + 1; % 对称RRC常用偶数跨度
end
waveform.rrcTaps = rcosdesign(waveform.rolloff, waveform.spanSymbols, waveform.sps, "sqrt");
waveform.groupDelaySamples = floor((numel(waveform.rrcTaps) - 1) / 2);
end

