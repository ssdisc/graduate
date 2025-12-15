function out = scramble_bits(bits, s)
%SCRAMBLE_BITS  PN-xor scrambling (whitening / encryption-lite).

if ~s.enable
    out = uint8(bits(:) ~= 0);
    return;
end
pn = comm.PNSequence( ...
    "Polynomial", s.pnPolynomial, ...
    "InitialConditions", s.pnInit, ...
    "SamplesPerFrame", numel(bits));
pnBits = uint8(pn());
out = bitxor(uint8(bits(:) ~= 0), pnBits);
end

