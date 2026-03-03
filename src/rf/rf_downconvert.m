function y = rf_downconvert(x, rf, n0)
%RF_DOWNCONVERT  接收端等效下变频（复包络）。
%
% 输入:
%   x  - 输入射频复包络（列向量）
%   rf - 射频参数结构体
%        .enable
%        .rxFreqNorm / .ifFreqNorm
%        .rxPhaseOffsetRad
%   n0 - 起始样本索引（可选，默认0）
%
% 输出:
%   y  - 下变频后的基带复包络

arguments
    x (:,1)
    rf (1,1) struct
    n0 (1,1) double = 0
end

if ~isfield(rf, "enable") || ~rf.enable
    y = x;
    return;
end

if isfield(rf, "rxFreqNorm")
    fNorm = double(rf.rxFreqNorm);
elseif isfield(rf, "ifFreqNorm")
    fNorm = double(rf.ifFreqNorm);
else
    fNorm = 0.18;
end
if ~isfield(rf, "rxPhaseOffsetRad"); rf.rxPhaseOffsetRad = 0; end

n = n0 + (0:numel(x)-1).';
y = x .* exp(-1j * (2*pi*fNorm*n + double(rf.rxPhaseOffsetRad)));
end
