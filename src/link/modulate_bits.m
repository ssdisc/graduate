function [sym, info] = modulate_bits(bits, mod)
%MODULATE_BITS  将比特映射到复基带符号。

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

