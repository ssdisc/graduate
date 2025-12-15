function coded = fec_encode(bits, fec)
%FEC_ENCODE  Convolutional encoding.

bits = uint8(bits(:) ~= 0);
coded = convenc(bits, fec.trellis);
end

