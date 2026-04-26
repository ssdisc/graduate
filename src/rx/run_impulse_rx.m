function rxResult = run_impulse_rx(rxSamples, txArtifacts, rxCfg)
%RUN_IMPULSE_RX Dedicated impulse receiver entry contract.

arguments
    rxSamples
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

ctx = rx_prepare_packet_context("impulse", rxSamples, txArtifacts, rxCfg);
captureStage = rx_run_capture_stage(ctx);

if captureStage.frontEndOk
    [headerSym, dataSym, symbolReliability, frontEndDiag] = local_impulse_frontend_stage_local(ctx, captureStage);
else
    [headerSym, dataSym, symbolReliability, frontEndDiag] = local_failed_frontend_placeholder_local(ctx.pkt);
end

headerResult = rx_decode_common_phy_header(ctx, headerSym);
packetDataBitsRx = uint8([]);
symbolReliabilityData = zeros(0, 1);
profileDiag = struct();
if frontEndDiag.ok && headerResult.ok
    [packetDataBitsRx, symbolReliabilityData] = local_decode_impulse_payload_local(ctx, dataSym, symbolReliability);
end

rxResult = rx_finalize_packet_result( ...
    ctx, captureStage, frontEndDiag, headerResult, packetDataBitsRx, symbolReliabilityData, profileDiag);
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_impulse_frontend_stage_local(ctx, captureStage)
headerStart = numel(ctx.pkt.syncSym) + 1;
headerStop = headerStart + double(ctx.pkt.nPhyHeaderSymTx) - 1;
dataStart = headerStop + 1;

ySymUse = captureStage.ySymRaw;
symbolReliability = rx_expand_reliability(captureStage.symbolReliabilityFront, numel(ySymUse));
if ctx.method ~= "none"
    [ySymUse, reliabilityNow] = mitigate_impulses(captureStage.ySymRaw, ctx.method, ctx.runtimeCfg.mitigation);
    symbolReliability = min(symbolReliability, rx_expand_reliability(reliabilityNow, numel(ySymUse)));
end

headerSym = ySymUse(headerStart:headerStop);
dataSym = ySymUse(dataStart:end);
if ~(isfield(ctx, "fhCaptureCfg") && isstruct(ctx.fhCaptureCfg) ...
        && isfield(ctx.fhCaptureCfg, "enable") && logical(ctx.fhCaptureCfg.enable))
    dataSym = rx_dehop_payload_symbols(dataSym, ctx.pkt);
end
symbolReliability = symbolReliability(dataStart:end);
diagOut = struct("ok", true, "frontEndMethod", string(ctx.method));
end

function [packetDataBitsRx, symbolReliabilityData] = local_decode_impulse_payload_local(ctx, dataSym, symbolReliability)
symbolReliabilityData = rx_expand_reliability(symbolReliability, numel(dataSym));
packetDataBitsRx = rx_decode_packet_bits_common(dataSym(:), symbolReliabilityData, ctx.pkt, ctx.runtimeCfg);
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_failed_frontend_placeholder_local(pkt)
headerSym = complex(zeros(double(pkt.nPhyHeaderSymTx), 1));
dataSym = complex(zeros(double(pkt.nDataSymTx), 1));
symbolReliability = zeros(double(pkt.nDataSymTx), 1);
diagOut = struct("ok", false, "reason", "capture_failed");
end
