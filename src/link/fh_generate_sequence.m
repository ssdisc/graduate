function [freqIdx, state] = fh_generate_sequence(nHops, fh)
%FH_GENERATE_SEQUENCE  生成跳频序列。
%
% 输入:
%   nHops - 需要的跳频数量
%   fh    - 跳频参数结构体
%
% 输出:
%   freqIdx - 频率索引序列 (1 到 nFreqs)
%   state   - PN序列状态（用于同步）
%
% 支持的序列类型:
%   'pn'     - 基于PN序列的伪随机跳频
%   'linear' - 线性递增跳频（用于测试）
%   'random' - 完全随机跳频（不可复现，仅测试用）

arguments
    nHops (1,1) double {mustBePositive, mustBeInteger}
    fh (1,1) struct
end

nFreqs = fh.nFreqs;
seqType = lower(string(fh.sequenceType));

switch seqType
    case "pn"
        % 基于PN序列生成跳频序列
        % 使用LFSR生成伪随机比特，然后映射到频率索引
        poly = fh.pnPolynomial;
        initState = fh.pnInit;

        % 计算每个跳频索引需要的比特数
        bitsPerHop = ceil(log2(nFreqs));
        nBits = nHops * bitsPerHop;

        % 生成PN序列
        [pnBits, state] = generate_pn_bits(nBits, poly, initState);

        % 将比特转换为频率索引
        freqIdx = zeros(nHops, 1);
        for k = 1:nHops
            startBit = (k-1) * bitsPerHop + 1;
            endBit = k * bitsPerHop;
            bits = pnBits(startBit:endBit);

            % 比特转整数
            idx = 0;
            for b = 1:bitsPerHop
                idx = idx + bits(b) * 2^(bitsPerHop - b);
            end

            % 映射到有效频率索引 (1 到 nFreqs)
            freqIdx(k) = mod(idx, nFreqs) + 1;
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

%% 辅助函数

function [bits, state] = generate_pn_bits(nBits, poly, initState)
%GENERATE_PN_BITS  生成PN序列比特。

% poly是多项式系数，如 [1 0 0 1 1] 表示 x^4 + x + 1
% initState是初始状态

regLen = numel(initState);
state = initState(:)';

bits = zeros(nBits, 1, 'uint8');

for k = 1:nBits
    % 输出最低位
    bits(k) = state(end);

    % 计算反馈
    feedback = 0;
    for i = 1:numel(poly)
        if poly(i) == 1 && i <= regLen
            feedback = xor(feedback, state(i));
        end
    end

    % 移位
    state = [feedback, state(1:end-1)];
end

end
