function [packetDataBitsRx, decodeDiag] = rx_decode_packet_bits_common(dataSymUse, reliabilityUse, pkt, runtimeCfg)
%RX_DECODE_PACKET_BITS_COMMON Shared payload demod/FEC/descramble stage.

if ~(isfield(pkt, "intState") && isfield(pkt, "scrambleCfg") && isfield(pkt, "packetDataBits"))
    error("Packet context must provide intState, scrambleCfg, and packetDataBits.");
end

if isfield(pkt, "dsssCfg") && isstruct(pkt.dsssCfg)
    reliabilityUse = rx_expand_reliability(reliabilityUse, numel(dataSymUse));
    [dataSymUse, reliabilityUse] = dsss_despread(dataSymUse(:), pkt.dsssCfg, reliabilityUse(:));
end
soft = demodulate_to_softbits(dataSymUse, runtimeCfg.mod, runtimeCfg.fec, runtimeCfg.softMetric, reliabilityUse);
codedBits = deinterleave_bits(soft, pkt.intState, runtimeCfg.interleaver);
packetDataBitsScr = fec_decode(codedBits, runtimeCfg.fec);
packetDataBitsRx = descramble_bits(packetDataBitsScr, pkt.scrambleCfg);
packetDataBitsRx = fit_bits_length(packetDataBitsRx, numel(pkt.packetDataBits));
decodeDiag = local_build_decode_diag_local(reliabilityUse, codedBits, runtimeCfg.fec);
end

function decodeDiag = local_build_decode_diag_local(symbolReliability, codedMetrics, fec)
symbolReliability = double(symbolReliability(:));
symbolReliability(~isfinite(symbolReliability)) = 0;
symbolReliability = max(min(symbolReliability, 1), 0);

codedReliability = local_metric_reliability_local(codedMetrics, fec);

if isempty(symbolReliability)
    symbolMean = 0;
    symbolMin = 0;
else
    symbolMean = mean(symbolReliability);
    symbolMin = min(symbolReliability);
end

if isempty(codedReliability)
    codedMean = 0;
    codedMin = 0;
else
    codedMean = mean(codedReliability);
    codedMin = min(codedReliability);
end

packetReliability = 0.30 * symbolMean + 0.20 * symbolMin + 0.30 * codedMean + 0.20 * codedMin;
packetReliability = max(min(packetReliability, 1), 0);

decodeDiag = struct( ...
    "symbolReliabilityMean", double(symbolMean), ...
    "symbolReliabilityMin", double(symbolMin), ...
    "codedReliabilityMean", double(codedMean), ...
    "codedReliabilityMin", double(codedMin), ...
    "packetReliability", double(packetReliability));
end

function codedReliability = local_metric_reliability_local(codedMetrics, fec)
metrics = double(codedMetrics(:));
if isempty(metrics)
    codedReliability = zeros(0, 1);
    return;
end

if strcmpi(fec.decisionType, "hard")
    codedReliability = ones(size(metrics));
    return;
end

nsdec = fec_payload_soft_bits(fec);
maxv = 2^nsdec - 1;
midv = maxv / 2;
codedReliability = 2 * abs(metrics - midv) / max(maxv, eps);
codedReliability = max(min(codedReliability, 1), 0);
end
