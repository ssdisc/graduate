function payloadBitsOut = decrypt_payload_packets(payloadBitsIn, packetOk, txPackets, assumption)
% 逐包独立解密，避免密文扩散跨包影响。
payloadBitsOut = uint8(payloadBitsIn(:) ~= 0);
nPacketsLocal = numel(txPackets);
ok = normalize_packet_ok(packetOk, nPacketsLocal);
assumption = lower(string(assumption));

for pktIdx = 1:nPacketsLocal
    if ~ok(pktIdx)
        continue;
    end
    pkt = txPackets(pktIdx);
    if ~isfield(pkt, "chaosEncInfo") || ~isfield(pkt.chaosEncInfo, "enabled") || ~pkt.chaosEncInfo.enabled
        continue;
    end
    if assumption == "none"
        continue;
    end

    infoUse = pkt.chaosEncInfo;
    if assumption == "wrong_key"
        infoUse = perturb_chaos_enc_info(infoUse, pktIdx);
    elseif assumption ~= "known"
        error("Unknown chaos assumption: %s", assumption);
    end

    seg = payloadBitsOut(pkt.startBit:pkt.endBit);
    segDec = chaos_decrypt_bits(seg, infoUse);
    payloadBitsOut(pkt.startBit:pkt.endBit) = fit_bits_length(segDec, numel(seg));
end
end

