function rxResult = run_narrowband_rx(rxSamples, txArtifacts, rxCfg)
%RUN_NARROWBAND_RX Dedicated narrowband receiver entry contract.

arguments
    rxSamples (:,1) double
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
profileDiag = struct();
symbolReliabilityData = rx_expand_reliability(symbolReliability, numel(dataSym));

if ctx.method == "fh_erasure"
    [reliabilityNow, erasureInfo] = local_narrowband_hop_reliability_local(dataSym(:), ctx.pkt, ctx.runtimeCfg);
    symbolReliabilityData = min(symbolReliabilityData, rx_expand_reliability(reliabilityNow, numel(dataSym)));
    profileDiag.hopReliability = erasureInfo.hopReliability;
    profileDiag.freqReliability = erasureInfo.freqReliability;
end

[dataSymUse, symbolReliabilityData] = rx_combine_payload_diversity_symbols(dataSym(:), symbolReliabilityData, ctx.pkt);
profileDiag.payloadDiversityEnabled = isfield(ctx.pkt, "payloadDiversityInfo") ...
    && isstruct(ctx.pkt.payloadDiversityInfo) ...
    && isfield(ctx.pkt.payloadDiversityInfo, "enable") ...
    && logical(ctx.pkt.payloadDiversityInfo.enable);

packetDataBitsRx = rx_decode_packet_bits_common(dataSymUse, symbolReliabilityData, ctx.pkt, ctx.runtimeCfg);
end

function [reliabilitySym, infoOut] = local_narrowband_hop_reliability_local(dataSym, pkt, runtimeCfg)
featureNames = ml_fh_erasure_feature_names();
ruleIdx = find(featureNames == "ruleReliability", 1, "first");
if isempty(ruleIdx)
    error("FH erasure feature set is missing ruleReliability.");
end

[featureMatrix, info] = ml_extract_fh_erasure_features(dataSym, pkt.hopInfo, runtimeCfg.mitigation.fhErasure, runtimeCfg.mod);
hopReliability = featureMatrix(:, ruleIdx);
reliabilitySym = repelem(hopReliability, round(double(pkt.hopInfo.hopLen)), 1);
reliabilitySym = rx_expand_reliability(reliabilitySym, numel(dataSym));

nFreqs = max(1, round(double(info.nFreqs)));
freqReliability = zeros(nFreqs, 1);
for freqIdx = 1:nFreqs
    use = info.freqIdx == freqIdx;
    if any(use)
        freqReliability(freqIdx) = median(hopReliability(use));
    else
        freqReliability(freqIdx) = 1;
    end
end
infoOut = struct( ...
    "hopReliability", hopReliability, ...
    "freqReliability", freqReliability, ...
    "featureInfo", info);
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_failed_frontend_placeholder_local(pkt)
headerSym = complex(zeros(double(pkt.nPhyHeaderSymTx), 1));
dataSym = complex(zeros(double(pkt.nDataSymTx), 1));
symbolReliability = zeros(double(pkt.nDataSymTx), 1);
diagOut = struct("ok", false, "reason", "capture_failed");
end
