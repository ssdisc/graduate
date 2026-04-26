function packetDataBitsRx = rx_decode_packet_bits_common(dataSymUse, reliabilityUse, pkt, runtimeCfg)
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
end
