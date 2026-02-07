function [sym, info] = modulate_bits(bits, mod)
%MODULATE_BITS  将比特映射到复基带符号。
%
% 输入:
%   bits - 输入比特流
%   mod  - 调制参数结构体
%          .type - 调制类型（当前支持"BPSK"）
%
% 输出:
%   sym  - 调制后的符号序列
%   info - 调制信息结构体
%          .bitsPerSymbol, .codeRate

bits = uint8(bits(:) ~= 0);
switch upper(string(mod.type))
    case "BPSK"
        sym = 1 - 2*double(bits);
        info.bitsPerSymbol = 1;
    otherwise
        error("不支持的调制方式: %s", mod.type);
end

info.codeRate = 1/2;
end

