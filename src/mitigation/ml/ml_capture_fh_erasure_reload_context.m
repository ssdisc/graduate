function ctx = ml_capture_fh_erasure_reload_context(p)
%ML_CAPTURE_FH_ERASURE_RELOAD_CONTEXT  Minimal reload context for FH-erasure ML models.
arguments
    p (1,1) struct
end

fullCtx = ml_capture_training_context(p);

ctx = struct();
ctx.domain = fullCtx.domain;
ctx.rxArchitecture = fullCtx.rxArchitecture;
ctx.trainingChainVersion = fullCtx.trainingChainVersion;
ctx.mod = fullCtx.mod;
ctx.waveform = fullCtx.waveform;
ctx.fh = fullCtx.fh;
ctx.frame = fullCtx.frame;
ctx.dsss = fullCtx.dsss;
ctx.packet = fullCtx.packet;
ctx.outerRs = fullCtx.outerRs;
ctx.scramble = fullCtx.scramble;
ctx.interleaver = fullCtx.interleaver;
ctx.fec = fullCtx.fec;
ctx.softMetric = fullCtx.softMetric;
ctx.scFde = fullCtx.scFde;
ctx.rxDiversity = fullCtx.rxDiversity;
ctx.rxSync = fullCtx.rxSync;
ctx.chaosEncrypt = fullCtx.chaosEncrypt;
ctx.fhErasure = local_fh_erasure_context(p);
end

function ctx = local_fh_erasure_context(p)
if ~(isfield(p, "mitigation") && isstruct(p.mitigation) ...
        && isfield(p.mitigation, "fhErasure") && isstruct(p.mitigation.fhErasure))
    error("ml_capture_fh_erasure_reload_context requires p.mitigation.fhErasure.");
end
cfg = p.mitigation.fhErasure;
ctx = struct( ...
    "freqPowerRatioThreshold", local_scalar(cfg, "freqPowerRatioThreshold"), ...
    "hopPowerRatioThreshold", local_scalar(cfg, "hopPowerRatioThreshold"), ...
    "minReliability", local_scalar(cfg, "minReliability"), ...
    "softSlope", local_scalar(cfg, "softSlope"), ...
    "maxErasedFreqFraction", local_scalar(cfg, "maxErasedFreqFraction"), ...
    "edgeGuardSymbols", local_scalar(cfg, "edgeGuardSymbols"), ...
    "attenuateSymbols", local_logical(cfg, "attenuateSymbols"));
end

function value = local_scalar(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("p.mitigation.fhErasure.%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value))
    error("p.mitigation.fhErasure.%s must be a finite scalar.", fieldName);
end
end

function value = local_logical(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("p.mitigation.fhErasure.%s is required.", fieldName);
end
value = logical(s.(fieldName));
if ~isscalar(value)
    error("p.mitigation.fhErasure.%s must be a logical scalar.", fieldName);
end
end
