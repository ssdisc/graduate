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
%           .sequenceOffsetHops - 会话连续序列中的hop起始偏移
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
payloadDiv = local_payload_diversity_cfg_local(fh, nFreqs);

if nFreqs == 1
    if payloadDiv.enable
        error("fh.payloadDiversity requires fh.nFreqs >= 2.");
    end
    freqIdx = ones(nHops, 1);
    state = [];
    return;
end

nLogicalHops = nHops;
if payloadDiv.enable
    if local_fh_is_fast_local(fh)
        error("fh.payloadDiversity only supports slow FH.");
    end
    nLogicalHops = ceil(double(nHops) / double(payloadDiv.copies));
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
        [pnBits, nextState] = pn_generate_bits(poly, initState, nLogicalHops * bitsPerHop);
        state = struct();
        state.type = "pn";
        state.currentState = uint8(nextState(:)).';

        % 将比特转换为频率索引（模nFreqs）
        freqIdxBase = zeros(nLogicalHops, 1);
        for k = 1:nLogicalHops
            startBit = (k-1) * bitsPerHop + 1;
            endBit = k * bitsPerHop;
            bits = pnBits(startBit:endBit);

            % 比特转整数0~nFreqs-1
            idx = 0;
            for b = 1:bitsPerHop
                idx = idx + bits(b) * 2^(bitsPerHop - b);
            end

            % 映射到有效频率索引 (1 到 nFreqs)
            freqIdxBase(k) = mod(idx, nFreqs) + 1;
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
        offsetHops = 0;
        if isfield(fh, "sequenceOffsetHops") && ~isempty(fh.sequenceOffsetHops)
            offsetHops = max(0, round(double(fh.sequenceOffsetHops)));
        end

        chaosSeqFull = double(chaos_generate(nLogicalHops + offsetHops, chaosMethod, chaosParams));
        chaosSeq = chaosSeqFull(offsetHops + 1:end);
        chaosSeq = max(min(chaosSeq(:), 1 - eps), 0);
        freqIdxBase = floor(chaosSeq * nFreqs) + 1;
        freqIdxBase = min(max(freqIdxBase, 1), nFreqs);

        state = struct();
        state.type = "chaos";
        state.chaosMethod = chaosMethod;
        state.chaosParams = chaosParams;
        state.sequenceOffsetHops = offsetHops;
        if ~isempty(chaosSeqFull)
            state.lastValue = chaosSeqFull(end);
        else
            state.lastValue = NaN;
        end

    case "linear"
        % 线性递增（用于调试）
        freqIdxBase = mod((0:nLogicalHops-1)', nFreqs) + 1;
        state = [];

    case "random"
        % 完全随机（不可复现）
        freqIdxBase = randi([1, nFreqs], nLogicalHops, 1);
        state = [];

    otherwise
        error("未知的跳频序列类型: %s", seqType);
end

if payloadDiv.enable
    freqIdx = local_expand_payload_diversity_freq_idx_local(freqIdxBase, nHops, nFreqs, payloadDiv);
    if ~isstruct(state)
        state = struct();
    end
    state.payloadDiversity = payloadDiv;
    state.logicalHops = nLogicalHops;
    state.physicalHops = nHops;
else
    freqIdx = freqIdxBase;
end

end

function cfg = local_payload_diversity_cfg_local(fh, nFreqs)
cfg = struct("enable", false, "copies", 1, "indexOffset", 0, "indexShifts", 0);
if ~(isfield(fh, "payloadDiversity") && isstruct(fh.payloadDiversity))
    return;
end

raw = fh.payloadDiversity;
if ~(isfield(raw, "enable") && logical(raw.enable))
    return;
end

copies = local_required_positive_integer_local(raw, "copies", "fh.payloadDiversity");
indexOffset = local_required_positive_integer_local(raw, "indexOffset", "fh.payloadDiversity");
if copies < 2
    error("fh.payloadDiversity.copies must be >= 2 when enabled.");
end

indexShifts = mod((0:copies-1) .* indexOffset, nFreqs);
if numel(unique(indexShifts)) ~= copies
    error("fh.payloadDiversity indexOffset=%d revisits the same frequency within %d copies (nFreqs=%d).", ...
        indexOffset, copies, nFreqs);
end

cfg = struct( ...
    "enable", true, ...
    "copies", copies, ...
    "indexOffset", indexOffset, ...
    "indexShifts", indexShifts(:).');
end

function freqIdx = local_expand_payload_diversity_freq_idx_local(baseFreqIdx, nPhysicalHops, nFreqs, cfg)
baseFreqIdx = round(double(baseFreqIdx(:)));
nPhysicalHops = round(double(nPhysicalHops));
if isempty(baseFreqIdx)
    freqIdx = zeros(0, 1);
    return;
end

freqIdx = zeros(nPhysicalHops, 1);
dstHop = 1;
for logicalHop = 1:numel(baseFreqIdx)
    baseIdx = baseFreqIdx(logicalHop);
    for copyIdx = 1:cfg.copies
        if dstHop > nPhysicalHops
            break;
        end
        freqIdx(dstHop) = mod(baseIdx - 1 + cfg.indexShifts(copyIdx), nFreqs) + 1;
        dstHop = dstHop + 1;
    end
end

if dstHop <= nPhysicalHops
    error("payload diversity FH expansion produced %d hops, expected %d.", dstHop - 1, nPhysicalHops);
end
end

function value = local_required_positive_integer_local(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s.%s is required.", ownerName, fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 1)
    error("%s.%s must be a positive integer scalar, got %g.", ownerName, fieldName, value);
end
value = round(value);
end

function tf = local_fh_is_fast_local(fh)
tf = false;
if isfield(fh, "mode") && strlength(string(fh.mode)) > 0
    tf = lower(string(fh.mode)) == "fast";
end
end
