function [y, state] = interleave_bits(x, inter)
%INTERLEAVE_BITS  简单块交织器。
%
% 输入:
%   x     - 输入比特/符号序列
%   inter - 交织配置结构体
%           .enable - 是否启用交织
%           .nRows  - 交织矩阵行数
%
% 输出:
%   y     - 交织后的序列
%   state - 交织状态结构体（供deinterleave_bits使用）
%           .pad, .nRows, .nCols

if ~inter.enable
    y = x(:);
    state = struct("pad", 0, "nRows", 1, "nCols", numel(y));
    return;
end

nRows = inter.nRows;
n = numel(x);
nCols = ceil(n / nRows);
pad = nRows*nCols - n;
xPad = [x(:); zeros(pad, 1, 'like', x)];

mat = reshape(xPad, nCols, nRows).';
y = mat(:);

state = struct("pad", pad, "nRows", nRows, "nCols", nCols);
end

