function [txHopped, hopInfo] = fh_modulate(txSym, fh)
%FH_MODULATE  跳频调制（发送端）。
%
% 将基带符号按跳频序列进行频率偏移。
%
% 输入:
%   txSym - 基带发送符号 (复数列向量)
%   fh    - 跳频参数结构体
%           .enable        - 是否启用跳频
%           .symbolsPerHop - 每跳包含的符号数
%           .nFreqs        - 频点数量
%           .freqSet       - 频偏集合（长度为nFreqs）
%           .sequenceType  - 序列类型: 'pn'/'chaos'/'linear'/'random'
%           .pnPolynomial  - PN多项式（pn模式）
%           .pnInit        - PN初始状态（pn模式）
%           .chaosMethod/.chaosParams（chaos模式）
%
% 输出:
%   txHopped - 跳频后的符号（复数列向量）
%   hopInfo  - 跳频信息结构体（接收端解跳频时需要）
%              .enable       - 跳频使能标志
%              .nHops        - 总跳数
%              .hopLen       - 每跳符号数
%              .freqIdx      - 频点索引序列 (1×nHops)
%              .freqOffsets  - 归一化频偏序列 (1×nHops)
%              .pnState      - PN序列生成器最终状态（用于连续传输）
%              .nFreqs       - 可用频点总数
%              .freqSet      - 频偏集合
%
% 跳频原理:
%   每个跳频周期(hop)内的符号乘以 exp(j*2*pi*f_k*n/Fs)
%   其中 f_k 是第k跳的频率偏移

arguments
    txSym (:,1)
    fh (1,1) struct
end

if ~fh.enable
    % 跳频禁用，直接返回
    txHopped = txSym;
    hopInfo = struct('enable', false);
    return;
end

nSym = numel(txSym);
hopLen = fh.symbolsPerHop;  % 每跳的符号数
nHops = ceil(nSym / hopLen); % 计算跳数，向上取整

% 生成跳频序列
[freqIdx, pnState] = fh_generate_sequence(nHops, fh);

% 计算频率偏移值（归一化频率）
% freqIdx ∈ [1, nFreqs]，映射到 [-BW/2, BW/2]
freqOffsets = fh.freqSet(freqIdx);  % 归一化频率偏移

% 对每个符号应用频率偏移
txHopped = complex(zeros(size(txSym)));

for hop = 1:nHops
    % 当前跳的符号范围 
    startIdx = (hop - 1) * hopLen + 1;
    endIdx = min(hop * hopLen, nSym);
    hopSymCount = endIdx - startIdx + 1;

    % 当前跳的频率偏移
    f_hop = freqOffsets(hop);

    % 生成相位旋转序列
    n = (0:hopSymCount-1)';
    phaseRot = exp(1j * 2 * pi * f_hop * n);

    % 应用频率偏移
    txHopped(startIdx:endIdx) = txSym(startIdx:endIdx) .* phaseRot;
end

% 保存跳频信息用于接收端
hopInfo = struct();
hopInfo.enable = true;
hopInfo.nHops = nHops;
hopInfo.hopLen = hopLen;
hopInfo.freqIdx = freqIdx;
hopInfo.freqOffsets = freqOffsets;
hopInfo.pnState = pnState;
hopInfo.nFreqs = fh.nFreqs;
hopInfo.freqSet = fh.freqSet;

end
