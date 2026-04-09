function chOut = adapt_channel_for_sps(chIn, waveformOrSps, fhRef)
%ADAPT_CHANNEL_FOR_SPS  将外部符号/相对频点口径的信道配置映射到采样级口径。
%
% 兼容两种输入：
%   waveform struct - 推荐，使用其中的sps/sampleRateHz做完整换算
%   sps scalar      - 兼容旧调用，仅处理符号类参数，不处理Hz字段

chOut = chIn;
sps = 1;
sampleRateHz = NaN;
waveform = struct();

if nargin < 2 || isempty(waveformOrSps)
    waveformOrSps = 1;
end
if nargin < 3 || isempty(fhRef)
    fhRef = struct();
end
if isstruct(waveformOrSps)
    waveform = waveformOrSps;
    if isfield(waveform, "sps")
        sps = max(1, round(double(waveform.sps)));
    end
    if isfield(waveform, "sampleRateHz")
        sampleRateHz = max(eps, double(waveform.sampleRateHz));
    elseif isfield(waveform, "symbolRateHz")
        sampleRateHz = max(eps, double(waveform.symbolRateHz) * sps);
    end
else
    sps = max(1, round(double(waveformOrSps)));
end

if sps <= 1
    sps = 1;
end

if isfield(chOut, "impulseProb")
    pSym = max(0, min(1, double(chOut.impulseProb)));
    chOut.impulseProb = 1 - (1 - pSym)^(1 / sps);
end

if isfield(chOut, "multipath") && isstruct(chOut.multipath)
    if isfield(chOut.multipath, "pathDelaysSymbols") && ~isempty(chOut.multipath.pathDelaysSymbols)
        chOut.multipath.pathDelays = round(double(chOut.multipath.pathDelaysSymbols(:)) * sps);
    elseif isfield(chOut.multipath, "pathDelays") && ~isempty(chOut.multipath.pathDelays)
        % 兼容旧字段：pathDelays视为已在采样域。
        chOut.multipath.pathDelays = round(double(chOut.multipath.pathDelays(:)));
    end
end

if isfield(chOut, "singleTone") && isstruct(chOut.singleTone)
    if isfield(chOut.singleTone, "freqHz") && ~isempty(chOut.singleTone.freqHz)
        require_sample_rate_local(sampleRateHz, "singleTone.freqHz");
        chOut.singleTone.normFreq = double(chOut.singleTone.freqHz) / sampleRateHz;
    elseif isfield(chOut.singleTone, "normFreq")
        % 兼容旧字段：normFreq视为已按采样率归一化。
        chOut.singleTone.normFreq = double(chOut.singleTone.normFreq);
    end
end

if isfield(chOut, "narrowband") && isstruct(chOut.narrowband)
    if isfield(chOut.narrowband, "centerFreqPoints") && ~isempty(chOut.narrowband.centerFreqPoints)
        require_sample_rate_local(sampleRateHz, "narrowband.centerFreqPoints");
        require_waveform_local(waveform, "narrowband.centerFreqPoints");
        spacingHz = fh_frequency_spacing_hz(fhRef, waveform);
        chOut.narrowband.centerFreq = double(chOut.narrowband.centerFreqPoints) * spacingHz / sampleRateHz;
    elseif isfield(chOut.narrowband, "centerFreq")
        chOut.narrowband.centerFreq = double(chOut.narrowband.centerFreq);
    else
        error("字段narrowband.centerFreqPoints需要显式给出。");
    end
    if isfield(chOut.narrowband, "bandwidthFreqPoints") && ~isempty(chOut.narrowband.bandwidthFreqPoints)
        require_sample_rate_local(sampleRateHz, "narrowband.bandwidthFreqPoints");
        require_waveform_local(waveform, "narrowband.bandwidthFreqPoints");
        spacingHz = fh_frequency_spacing_hz(fhRef, waveform);
        chOut.narrowband.bandwidth = max(double(chOut.narrowband.bandwidthFreqPoints) * spacingHz / sampleRateHz, 1e-3);
    elseif isfield(chOut.narrowband, "bandwidth")
        chOut.narrowband.bandwidth = max(double(chOut.narrowband.bandwidth), 1e-3);
    else
        error("字段narrowband.bandwidthFreqPoints需要显式给出。");
    end
end

if isfield(chOut, "sweep") && isstruct(chOut.sweep)
    if isfield(chOut.sweep, "startHz") && ~isempty(chOut.sweep.startHz)
        require_sample_rate_local(sampleRateHz, "sweep.startHz");
        chOut.sweep.startFreq = double(chOut.sweep.startHz) / sampleRateHz;
    elseif isfield(chOut.sweep, "startFreq")
        chOut.sweep.startFreq = double(chOut.sweep.startFreq);
    end
    if isfield(chOut.sweep, "stopHz") && ~isempty(chOut.sweep.stopHz)
        require_sample_rate_local(sampleRateHz, "sweep.stopHz");
        chOut.sweep.stopFreq = double(chOut.sweep.stopHz) / sampleRateHz;
    elseif isfield(chOut.sweep, "stopFreq")
        chOut.sweep.stopFreq = double(chOut.sweep.stopFreq);
    end
    if isfield(chOut.sweep, "periodSymbols")
        chOut.sweep.periodSamples = max(2, round(double(chOut.sweep.periodSymbols) * sps));
    elseif isfield(chOut.sweep, "periodSamples")
        chOut.sweep.periodSamples = max(2, round(double(chOut.sweep.periodSamples)));
    end
end

if isfield(chOut, "syncImpairment") && isstruct(chOut.syncImpairment)
    if isfield(chOut.syncImpairment, "timingOffsetSymbols") && ~isempty(chOut.syncImpairment.timingOffsetSymbols)
        chOut.syncImpairment.timingOffset = double(chOut.syncImpairment.timingOffsetSymbols) * sps;
    elseif isfield(chOut.syncImpairment, "timingOffset")
        chOut.syncImpairment.timingOffset = double(chOut.syncImpairment.timingOffset);
    end
end
end

function require_sample_rate_local(sampleRateHz, fieldName)
if ~(isfinite(sampleRateHz) && sampleRateHz > 0)
    error("字段%s需要有效的waveform.sampleRateHz支持。", fieldName);
end
end

function require_waveform_local(waveform, fieldName)
if ~isstruct(waveform) || ~(isfield(waveform, "symbolRateHz") && isfinite(double(waveform.symbolRateHz)) ...
        && double(waveform.symbolRateHz) > 0)
    error("字段%s需要包含有效symbolRateHz的waveform结构体支持。", fieldName);
end
end

