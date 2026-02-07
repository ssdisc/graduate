function x = deinterleave_bits(y, state, inter)
%DEINTERLEAVE_BITS  interleave_bits的逆操作。
%
% 输入:
%   y     - 交织后的序列
%   state - 交织状态结构体（来自interleave_bits）
%           .pad, .nRows, .nCols
%   inter - 交织配置结构体
%           .enable - 是否启用交织
%
% 输出:
%   x - 逆交织后的序列

if ~inter.enable
    x = y(:);
    return;
end
mat = reshape(y, state.nRows, state.nCols);
xPad = reshape(mat.', [], 1);
if state.pad > 0
    x = xPad(1:end-state.pad);
else
    x = xPad;
end
end

