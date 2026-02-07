function bits = fec_decode(metrics, fec)
%FEC_DECODE  Viterbi译码（硬判决/软判决）。
%
% 输入:
%   metrics - 译码输入（硬比特或软度量）
%   fec     - FEC参数结构体
%             .decisionType   - 'hard'/'soft'
%             .softBits       - 软判决量化位数（soft模式）
%             .trellis        - 卷积码网格结构
%             .tracebackDepth - 回溯深度
%             .opmode         - vitdec工作模式
%
% 输出:
%   bits - 译码后的比特流

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

