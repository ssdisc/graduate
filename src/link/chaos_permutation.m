function [perm, invPerm] = chaos_permutation(n, method, params)
%CHAOS_PERMUTATION  基于混沌序列生成可逆置乱索引。
%
% 输入:
%   n      - 索引长度
%   method - 混沌映射类型
%   params - 混沌参数
%
% 输出:
%   perm    - 正向置乱索引，xPerm = x(perm)
%   invPerm - 逆向置乱索引，x = xPerm(invPerm)

arguments
    n (1,1) double {mustBePositive, mustBeInteger}
    method (1,1) string
    params (1,1) struct
end

seq = chaos_generate(n, method, params);
seq = seq(:);
idx = (1:n).';

% 使用索引作为次关键字，保证在极少数重复值下仍可确定性排序
[~, perm] = sortrows([seq, idx], [1, 2]);

if nargout > 1
    invPerm = zeros(n, 1);
    invPerm(perm) = 1:n;
end

end
