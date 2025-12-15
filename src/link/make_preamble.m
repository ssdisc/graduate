function [preambleBits, preambleSym] = make_preamble(L)
%MAKE_PREAMBLE  Generate a PN preamble (bits) and its BPSK symbols.

pn = comm.PNSequence( ...
    "Polynomial", [1 0 0 1 1], ...
    "InitialConditions", [0 0 0 1], ...
    "SamplesPerFrame", L);
preambleBits = uint8(pn());
preambleSym = 1 - 2*double(preambleBits);
end

