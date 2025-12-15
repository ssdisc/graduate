function bits = fec_decode(metrics, fec)
%FEC_DECODE  Viterbi decoding (hard/soft).

if strcmpi(fec.decisionType, "hard")
    hardBits = uint8(metrics(:) ~= 0);
    bits = vitdec(hardBits, fec.trellis, fec.tracebackDepth, fec.opmode, 'hard');
else
    nsdec = fec.softBits;
    soft = uint8(metrics(:));
    bits = vitdec(soft, fec.trellis, fec.tracebackDepth, fec.opmode, 'soft', nsdec);
end
bits = uint8(bits(:));
end

