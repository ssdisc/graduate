function out = descramble_bits(bits, s)
%DESCRAMBLE_BITS  解扰与扰码操作相同（PN异或）。
%
% 输入:
%   bits - 输入比特流
%   s    - 扰码参数结构体
%          .enable, .pnPolynomial, .pnInit
%
% 输出:
%   out - 解扰后的比特流

out = scramble_bits(bits, s);
end

