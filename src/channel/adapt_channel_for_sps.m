function chOut = adapt_channel_for_sps(chIn, sps)
% 将“按符号归一化”的信道配置映射到“按采样归一化”。
chOut = chIn;
sps = max(1, round(double(sps)));
if sps <= 1
    return;
end

if isfield(chOut, "impulseProb")
    pSym = max(0, min(1, double(chOut.impulseProb)));
    chOut.impulseProb = 1 - (1 - pSym)^(1 / sps);
end

if isfield(chOut, "multipath") && isstruct(chOut.multipath) ...
        && isfield(chOut.multipath, "pathDelays") && ~isempty(chOut.multipath.pathDelays)
    chOut.multipath.pathDelays = round(double(chOut.multipath.pathDelays(:)) * sps);
end

if isfield(chOut, "doppler") && isstruct(chOut.doppler)
    if isfield(chOut.doppler, "maxNorm")
        chOut.doppler.maxNorm = double(chOut.doppler.maxNorm) / sps;
    end
    if isfield(chOut.doppler, "commonNorm")
        chOut.doppler.commonNorm = double(chOut.doppler.commonNorm) / sps;
    end
    if isfield(chOut.doppler, "pathNorm") && ~isempty(chOut.doppler.pathNorm)
        chOut.doppler.pathNorm = double(chOut.doppler.pathNorm(:)) / sps;
    end
end

if isfield(chOut, "singleTone") && isstruct(chOut.singleTone) ...
        && isfield(chOut.singleTone, "normFreq")
    chOut.singleTone.normFreq = double(chOut.singleTone.normFreq) / sps;
end

if isfield(chOut, "narrowband") && isstruct(chOut.narrowband)
    if isfield(chOut.narrowband, "centerFreq")
        chOut.narrowband.centerFreq = double(chOut.narrowband.centerFreq) / sps;
    end
    if isfield(chOut.narrowband, "bandwidth")
        chOut.narrowband.bandwidth = max(double(chOut.narrowband.bandwidth) / sps, 1e-3);
    end
end

if isfield(chOut, "sweep") && isstruct(chOut.sweep)
    if isfield(chOut.sweep, "startFreq")
        chOut.sweep.startFreq = double(chOut.sweep.startFreq) / sps;
    end
    if isfield(chOut.sweep, "stopFreq")
        chOut.sweep.stopFreq = double(chOut.sweep.stopFreq) / sps;
    end
    if isfield(chOut.sweep, "periodSymbols")
        chOut.sweep.periodSamples = max(2, round(double(chOut.sweep.periodSymbols) * sps));
    elseif isfield(chOut.sweep, "periodSamples")
        chOut.sweep.periodSamples = max(2, round(double(chOut.sweep.periodSamples)));
    end
end

if isfield(chOut, "syncImpairment") && isstruct(chOut.syncImpairment) ...
        && isfield(chOut.syncImpairment, "cfoNorm")
    chOut.syncImpairment.cfoNorm = double(chOut.syncImpairment.cfoNorm) / sps;
end
end

