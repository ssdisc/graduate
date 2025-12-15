function [sym, info] = modulate_bits(bits, mod)
%MODULATE_BITS  Map bits to complex baseband symbols.

bits = uint8(bits(:) ~= 0);
switch upper(string(mod.type))
    case "BPSK"
        sym = 1 - 2*double(bits);
        info.bitsPerSymbol = 1;
    otherwise
        error("Unsupported modulation: %s", mod.type);
end

info.codeRate = 1/2;
end

