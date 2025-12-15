function N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es)
%EBN0_TO_N0  Convert Eb/N0 to N0 (assuming Es is known).

Eb = Es / (codeRate * bitsPerSym);
N0 = Eb / EbN0;
end

