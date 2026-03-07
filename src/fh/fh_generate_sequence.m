function [freqIdx, state] = fh_generate_sequence(nHops, fh)
%FH_GENERATE_SEQUENCE  生成跳频序列。
%
% 输入:
%   nHops - 需要的跳频数量
%   fh    - 跳频参数结构体
%           .nFreqs       - 频点数量
%           .sequenceType - 序列类型: 'pn'/'chaos'/'linear'/'random'
%           .pnPolynomial - PN多项式（sequenceType='pn'时使用）
%           .pnInit       - PN初始状态（sequenceType='pn'时使用）
%           .chaosMethod  - 混沌映射类型（sequenceType='chaos'时使用）
%           .chaosParams  - 混沌参数（sequenceType='chaos'时使用）
%
% 输出:
%   freqIdx - 频率索引序列 (1 到 nFreqs)
%   state   - 序列状态（用于调试/同步）
%
% 支持的序列类型:
%   'pn'     - 基于PN序列的伪随机跳频
%   'chaos'  - 基于混沌映射的跳频（Logistic/Henon/Tent）
%   'linear' - 线性递增跳频（用于测试）
%   'random' - 完全随机跳频（不可复现，仅测试用）

arguments
    nHops (1,1) double {mustBePositive, mustBeInteger}
    fh (1,1) struct
end

nFreqs = fh.nFreqs;
seqType = lower(string(fh.sequenceType));
if nFreqs < 1 || abs(nFreqs - round(nFreqs)) > 1e-12
    error("fh.nFreqs必须为正整数，当前为%g。", nFreqs);
end
nFreqs = round(nFreqs);

if nFreqs == 1
    freqIdx = ones(nHops, 1);
    state = [];
    return;
end

switch seqType
    case "pn"
        % 基于PN序列生成跳频序列
        % 使用LFSR生成伪随机比特，然后映射到频率索引
        poly = fh.pnPolynomial;
        initState = fh.pnInit;

        % 计算每个跳频索引需要的比特数
        bitsPerHop = ceil(log2(nFreqs));

        % 生成PN序列
        [pnBits, nextState] = pn_generate_bits(poly, initState, nHops * bitsPerHop);
        state = struct();
        state.type = "pn";
        state.currentState = uint8(nextState(:)).';

        % 将比特转换为频率索引（模nFreqs）
        freqIdx = zeros(nHops, 1);
        for k = 1:nHops
            startBit = (k-1) * bitsPerHop + 1;
            endBit = k * bitsPerHop;
            bits = pnBits(startBit:endBit);

            % 比特转整数0~nFreqs-1
            idx = 0;
            for b = 1:bitsPerHop
                idx = idx + bits(b) * 2^(bitsPerHop - b);
            end

            % 映射到有效频率索引 (1 到 nFreqs)
            freqIdx(k) = mod(idx, nFreqs) + 1;
        end

    case {"chaos", "chaotic"}
        % 基于混沌序列生成跳频索引（与加密模块共用chaos_generate）
        if ~isfield(fh, "chaosMethod") || strlength(string(fh.chaosMethod)) == 0
            chaosMethod = "logistic";
        else
            chaosMethod = lower(string(fh.chaosMethod));
        end
        if isfield(fh, "chaosParams") && isstruct(fh.chaosParams)
            chaosParams = fh.chaosParams;
        else
            chaosParams = struct();
        end

        chaosSeq = double(chaos_generate(nHops, chaosMethod, chaosParams));
        chaosSeq = max(min(chaosSeq(:), 1 - eps), 0);
        freqIdx = floor(chaosSeq * nFreqs) + 1;
        freqIdx = min(max(freqIdx, 1), nFreqs);

        state = struct();
        state.type = "chaos";
        state.chaosMethod = chaosMethod;
        state.chaosParams = chaosParams;
        if ~isempty(chaosSeq)
            state.lastValue = chaosSeq(end);
        else
            state.lastValue = NaN;
        end

    case "linear"
        % 线性递增（用于调试）
        freqIdx = mod((0:nHops-1)', nFreqs) + 1;
        state = [];

    case "random"
        % 完全随机（不可复现）
        freqIdx = randi([1, nFreqs], nHops, 1);
        state = [];

    otherwise
        error("未知的跳频序列类型: %s", seqType);
end

end
