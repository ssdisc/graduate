function y = rf_upconvert(x, rf, n0)
%RF_UPCONVERT  发送端等效上变频（复包络）。
%
% 输入:
%   x  - 复基带符号（列向量）
%   rf - 射频参数结构体
%        .enable
%        .txFreqNorm / .ifFreqNorm
%        .txPhaseOffsetRad
%   n0 - 起始样本索引（可选，默认0）
%
% 输出:
%   y  - 上变频后的等效射频复包络

arguments
    x (:,1)
    rf (1,1) struct
    n0 (1,1) double = 0
end

if ~isfield(rf, "enable") || ~rf.enable
    y = x;
    return;
end

if isfield(rf, "txFreqNorm")
    fNorm = double(rf.txFreqNorm);
elseif isfield(rf, "ifFreqNorm")
    fNorm = double(rf.ifFreqNorm);
else
    fNorm = 0.18;
end
if ~isfield(rf, "txPhaseOffsetRad"); rf.txPhaseOffsetRad = 0; end

n = n0 + (0:numel(x)-1).';
y = x .* exp(1j * (2*pi*fNorm*n + double(rf.txPhaseOffsetRad)));
end
