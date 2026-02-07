function out = scramble_bits(bits, s)
%SCRAMBLE_BITS  PN异或扰码（白化/轻量加密）。
%
% 输入:
%   bits - 输入比特流
%   s    - 扰码参数结构体
%          .enable       - 是否启用扰码
%          .pnPolynomial - PN多项式
%          .pnInit       - PN初始状态
%
% 输出:
%   out - 扰码后的比特流

if ~s.enable
    out = uint8(bits(:) ~= 0);
    return;
end
pn = comm.PNSequence( ...
    "Polynomial", s.pnPolynomial, ...
    "InitialConditions", s.pnInit, ...
    "SamplesPerFrame", numel(bits));
pnBits = uint8(pn());
out = bitxor(uint8(bits(:) ~= 0), pnBits);
end

