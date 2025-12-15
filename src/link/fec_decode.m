function bits = fec_decode(metrics, fec)
%FEC_DECODE  Viterbi译码（硬判决/软判决）。

% 确保所有数据都是double精度且在CPU上（非gpuArray）
metrics = double(gather(metrics(:)));

if strcmpi(fec.decisionType, "hard")
    hardBits = double(metrics ~= 0);
    bits = vitdec(hardBits, fec.trellis, fec.tracebackDepth, fec.opmode, 'hard');
else
    nsdec = fec.softBits;
    % 软译码需要整数量化值，范围0到2^nsdec-1
    soft = round(metrics);
    soft = max(min(soft, 2^nsdec-1), 0);
    bits = vitdec(soft, fec.trellis, fec.tracebackDepth, fec.opmode, 'soft', nsdec);
end
bits = uint8(bits(:));
end

