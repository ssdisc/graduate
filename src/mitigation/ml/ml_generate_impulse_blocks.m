function dataset = ml_generate_impulse_blocks(p, nBlocks, blockLen, ebN0dBRange)
%ML_GENERATE_IMPULSE_BLOCKS  生成脉冲抑制训练/验证/测试所需的数据块。

[~, modInfo] = modulate_bits(uint8([0; 1]), p.mod);
codeRate = modInfo.codeRate;
bitsPerSym = modInfo.bitsPerSymbol;
Es = 1.0;

dataset = struct();
dataset.nBlocks = nBlocks;
dataset.blockLen = blockLen;
dataset.ebN0dBRange = ebN0dBRange;
dataset.ebN0dBPerBlock = zeros(nBlocks, 1);
dataset.txSym = cell(nBlocks, 1);
dataset.rxSym = cell(nBlocks, 1);
dataset.impMask = cell(nBlocks, 1);

for b = 1:nBlocks
    ebN0dB = ebN0dBRange(1) + rand() * diff(ebN0dBRange);
    dataset.ebN0dBPerBlock(b) = ebN0dB;
    EbN0 = 10.^(ebN0dB / 10);
    N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es);

    bits = randi([0 1], blockLen * bitsPerSym, 1, 'uint8');
    txSym = modulate_bits(bits, p.mod);
    [txSym, rxSym, impMask] = ml_simulate_training_chain(txSym, p, N0);

    dataset.txSym{b} = txSym;
    dataset.rxSym{b} = rxSym;
    dataset.impMask{b} = logical(impMask ~= 0);
end
end
