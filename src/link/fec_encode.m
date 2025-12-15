function coded = fec_encode(bits, fec)
%FEC_ENCODE  卷积编码。

bits = uint8(bits(:) ~= 0);
coded = convenc(bits, fec.trellis);
end

