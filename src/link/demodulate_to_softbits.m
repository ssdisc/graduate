function soft = demodulate_to_softbits(r, mod, fec, softCfg, reliability)
%DEMODULATE_TO_SOFTBITS  生成带可靠性加权的Viterbi输入度量。
%
% 输入:
%   r          - 接收符号（复数或实数）
%   mod        - 调制参数结构体
%                .type - 调制类型（支持"BPSK"/"QPSK"）
%   fec        - FEC参数结构体
%                .decisionType - 'hard' 或 'soft'
%                .softBits     - 软判决量化位数（soft模式）
%   softCfg    - 软度量配置结构体
%                .clipA - 度量截断阈值
%   reliability- （可选）每符号可靠性权重（0-1）
%                低可靠性将软输出推向"擦除"（中间值）

if nargin < 5
    reliability = [];
end

switch upper(string(mod.type))
    case "BPSK"
        metric = real(r(:));
        bitsPerSym = 1;
    case "QPSK"
        r = r(:);
        metricI = real(r) * sqrt(2);
        metricQ = imag(r) * sqrt(2);
        metric = reshape([metricI.'; metricQ.'], [], 1);
        bitsPerSym = 2;
    otherwise
        error("不支持的调制方式: %s", mod.type);
end

if strcmpi(fec.decisionType, "hard")
    soft = uint8(metric < 0);
    return;
end

ns = fec.softBits;
maxv = 2^ns - 1;
midv = maxv / 2;  % 中间值 = 擦除/不确定
A = softCfg.clipA;

metric = max(min(metric, A), -A);

% 量化使得 0 => 强'0', maxv => 强'1'
soft = (A - metric) / (2*A) * maxv;

% 如果提供了可靠性则应用可靠性加权
% 低可靠性 -> 推向中间（擦除）
if ~isempty(reliability)
    reliability = reliability(:);
    if numel(reliability) == numel(soft)
        reliabilityBits = reliability;
    elseif numel(reliability) * bitsPerSym == numel(soft)
        reliabilityBits = repelem(reliability, bitsPerSym);
    else
        reliabilityBits = [];
    end
    if ~isempty(reliabilityBits)
        % 在软值和中间（不确定）值之间插值
        soft = reliabilityBits .* soft + (1 - reliabilityBits) .* midv;
    end
end

soft = round(soft);
soft = uint8(max(min(soft, maxv), 0));
end


