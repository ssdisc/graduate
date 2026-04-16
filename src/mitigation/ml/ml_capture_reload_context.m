function ctx = ml_capture_reload_context(p)
%ML_CAPTURE_RELOAD_CONTEXT  提取决定是否需要重训的最小上下文子集。
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
ctx.channel = struct( ...
    "impulseProb", fullCtx.channel.impulseProb, ...
    "impulseToBgRatio", fullCtx.channel.impulseToBgRatio);
end
