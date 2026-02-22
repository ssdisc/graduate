function [preambleBits, preambleSym] = make_preamble(L)
%MAKE_PREAMBLE  生成PN前导（比特）及其BPSK符号。

pn = comm.PNSequence( ...
    "Polynomial", [1 0 0 1 1], ...
    "InitialConditions", [0 0 0 1], ...
    "SamplesPerFrame", L);
preambleBits = uint8(pn());
preambleSym = 1 - 2*double(preambleBits);
end
