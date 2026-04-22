function ctx = ml_capture_selector_reload_context(p)
%ML_CAPTURE_SELECTOR_RELOAD_CONTEXT  Reload context for offline-trained adaptive front-end selectors.

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
ctx.selectorTrainingDomain = ml_require_selector_training_domain(p);
end
