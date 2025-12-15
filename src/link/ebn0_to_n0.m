function N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es)
%EBN0_TO_N0  将Eb/N0转换为N0（假设Es已知）。

Eb = Es / (codeRate * bitsPerSym);
N0 = Eb / EbN0;
end

