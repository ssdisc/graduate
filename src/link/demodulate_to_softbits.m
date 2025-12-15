function soft = demodulate_to_softbits(r, mod, fec, softCfg, reliability)
%DEMODULATE_TO_SOFTBITS  生成带可靠性加权的Viterbi输入度量。
%
% 输入:
%   r          - 接收符号（复数或实数）
%   mod        - 调制参数
%   fec        - FEC参数（decisionType, softBits）
%   softCfg    - 软度量配置（clipA）
%   reliability- （可选）每符号可靠性权重（0-1）
%                低可靠性将软输出推向"擦除"（中间值）

if nargin < 5
    reliability = [];
end

switch upper(string(mod.type))
    case "BPSK"
        metric = real(r(:));
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
        % 在软值和中间（不确定）值之间插值
        soft = reliability .* soft + (1 - reliability) .* midv;
    end
end

soft = round(soft);
soft = uint8(max(min(soft, maxv), 0));
end


