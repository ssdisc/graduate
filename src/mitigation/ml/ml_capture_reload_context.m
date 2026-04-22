function ctx = ml_capture_reload_context(p)
%ML_CAPTURE_RELOAD_CONTEXT  提取决定是否需要重训的最小上下文子集。
arguments
    p (1,1) struct
end

fullCtx = ml_capture_training_context(p);
impulseProfile = ml_require_impulse_offline_training_profile(p);

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
ctx.impulseOfflineProfile = struct( ...
    "profileName", impulseProfile.profileName, ...
    "scenario", impulseProfile.scenario);
end
