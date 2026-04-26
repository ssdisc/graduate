function captureStage = rx_run_capture_stage(ctx)
%RX_RUN_CAPTURE_STAGE Run sample capture/synchronization for one packet.

front = capture_synced_block_from_samples( ...
    ctx.rxSamples(:), ctx.pkt.syncSym(:), ctx.expectedLen, ctx.syncCfg, ctx.runtimeCfg.mitigation, ...
    ctx.runtimeCfg.mod, ctx.waveform, ctx.sampleAction, local_capture_bootstrap_chain_local(ctx.method), ctx.fhCaptureCfg);

frontEndOk = logical(front.ok);
ySymRaw = complex(zeros(ctx.expectedLen, 1));
symbolReliabilityFront = zeros(ctx.expectedLen, 1);
if frontEndOk
    ySymRaw = rx_fit_complex_length(front.rFull, ctx.expectedLen);
    symbolReliabilityFront = rx_expand_reliability(front.reliabilityFull, ctx.expectedLen);
end

captureStage = struct( ...
    "front", front, ...
    "frontEndOk", frontEndOk, ...
    "ySymRaw", ySymRaw, ...
    "symbolReliabilityFront", symbolReliabilityFront);
end

function bootstrapChain = local_capture_bootstrap_chain_local(method)
method = lower(string(method));
if any(method == ["blanking" "clipping" "ml_blanking" "ml_cnn" "ml_cnn_hard" "ml_gru" "ml_gru_hard"])
    bootstrapChain = "raw";
    return;
end
bootstrapChain = "raw";
end
