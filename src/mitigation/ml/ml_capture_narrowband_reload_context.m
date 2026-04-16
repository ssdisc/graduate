function ctx = ml_capture_narrowband_reload_context(p)
%ML_CAPTURE_NARROWBAND_RELOAD_CONTEXT  Minimal reload context for narrowband action models.
arguments
    p (1,1) struct
end

fullCtx = ml_capture_training_context(p);

ctx = struct();
ctx.domain = fullCtx.domain;
ctx.rxArchitecture = fullCtx.rxArchitecture;
ctx.mod = fullCtx.mod;
ctx.waveform = fullCtx.waveform;
ctx.fh = fullCtx.fh;
ctx.frame = fullCtx.frame;
ctx.dsss = fullCtx.dsss;
ctx.scFde = fullCtx.scFde;
ctx.rxDiversity = fullCtx.rxDiversity;
ctx.rxSync = fullCtx.rxSync;
ctx.fftBandstop = local_fft_bandstop_context(p);
end

function ctx = local_fft_bandstop_context(p)
if ~(isfield(p, "mitigation") && isstruct(p.mitigation) ...
        && isfield(p.mitigation, "fftBandstop") && isstruct(p.mitigation.fftBandstop))
    error("ml_capture_narrowband_reload_context requires p.mitigation.fftBandstop.");
end
cfg = p.mitigation.fftBandstop;
ctx = struct( ...
    "peakRatio", local_scalar(cfg, "peakRatio"), ...
    "edgeRatio", local_scalar(cfg, "edgeRatio"), ...
    "maxBands", local_scalar(cfg, "maxBands"), ...
    "mergeGapBins", local_scalar(cfg, "mergeGapBins"), ...
    "padBins", local_scalar(cfg, "padBins"), ...
    "minBandBins", local_scalar(cfg, "minBandBins"), ...
    "smoothSpanBins", local_scalar(cfg, "smoothSpanBins"), ...
    "fftOversample", local_scalar(cfg, "fftOversample"), ...
    "maxBandwidthFrac", local_scalar(cfg, "maxBandwidthFrac"), ...
    "minFreqAbs", local_scalar(cfg, "minFreqAbs"), ...
    "suppressToFloor", local_logical(cfg, "suppressToFloor"));
end

function value = local_scalar(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("p.mitigation.fftBandstop.%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value))
    error("p.mitigation.fftBandstop.%s must be a finite scalar.", fieldName);
end
end

function value = local_logical(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("p.mitigation.fftBandstop.%s is required.", fieldName);
end
value = logical(s.(fieldName));
if ~isscalar(value)
    error("p.mitigation.fftBandstop.%s must be a logical scalar.", fieldName);
end
end
