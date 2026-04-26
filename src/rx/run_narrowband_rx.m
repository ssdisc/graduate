function rxResult = run_narrowband_rx(rxSamples, txArtifacts, rxCfg)
%RUN_NARROWBAND_RX Dedicated narrowband receiver entry contract.

arguments
    rxSamples
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

ctx = rx_prepare_packet_context("narrowband", rxSamples, txArtifacts, rxCfg);
captureStage = rx_run_capture_stage(ctx);

if captureStage.frontEndOk
    [headerSym, dataSym, symbolReliability, frontEndDiag] = local_narrowband_control_stage_local(ctx, captureStage);
else
    [headerSym, dataSym, symbolReliability, frontEndDiag] = local_failed_frontend_placeholder_local(ctx.pkt);
end

headerResult = rx_decode_common_phy_header(ctx, headerSym);
packetDataBitsRx = uint8([]);
symbolReliabilityData = zeros(0, 1);
profileDiag = struct();
if frontEndDiag.ok && headerResult.ok
    [packetDataBitsRx, symbolReliabilityData, profileDiag] = local_decode_narrowband_payload_local(ctx, dataSym, symbolReliability);
end

rxResult = rx_finalize_packet_result( ...
    ctx, captureStage, frontEndDiag, headerResult, packetDataBitsRx, symbolReliabilityData, profileDiag);
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_narrowband_control_stage_local(ctx, captureStage)
headerStart = numel(ctx.pkt.syncSym) + 1;
headerStop = headerStart + double(ctx.pkt.nPhyHeaderSymTx) - 1;
dataStart = headerStop + 1;

symbolReliabilityFull = rx_expand_reliability(captureStage.symbolReliabilityFront, numel(captureStage.ySymRaw));
headerSym = captureStage.ySymRaw(headerStart:headerStop);
dataSym = captureStage.ySymRaw(dataStart:end);
symbolReliability = symbolReliabilityFull(dataStart:end);
diagOut = struct("ok", true, "frontEndMethod", "protected_control");
end

function [packetDataBitsRx, symbolReliabilityData, profileDiag] = local_decode_narrowband_payload_local(ctx, dataSym, symbolReliability)
symbolReliabilityData = rx_expand_reliability(symbolReliability, numel(dataSym));
[dataSymPrep, reliabilityNow, profileDiag] = narrowband_profile_frontend(dataSym(:), ctx.pkt, ctx.runtimeCfg, ctx.method);
symbolReliabilityData = min(symbolReliabilityData, rx_expand_reliability(reliabilityNow, numel(dataSymPrep)));

[dataSymUse, symbolReliabilityData] = rx_combine_payload_diversity_symbols(dataSymPrep, symbolReliabilityData, ctx.pkt);
profileDiag.payloadDiversityEnabled = isfield(ctx.pkt, "payloadDiversityInfo") ...
    && isstruct(ctx.pkt.payloadDiversityInfo) ...
    && isfield(ctx.pkt.payloadDiversityInfo, "enable") ...
    && logical(ctx.pkt.payloadDiversityInfo.enable);

packetDataBitsRx = rx_decode_packet_bits_common(dataSymUse, symbolReliabilityData, ctx.pkt, ctx.runtimeCfg);
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_failed_frontend_placeholder_local(pkt)
headerSym = complex(zeros(double(pkt.nPhyHeaderSymTx), 1));
dataSym = complex(zeros(double(pkt.nDataSymTx), 1));
symbolReliability = zeros(double(pkt.nDataSymTx), 1);
diagOut = struct("ok", false, "reason", "capture_failed");
end
