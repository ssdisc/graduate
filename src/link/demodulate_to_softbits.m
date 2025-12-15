function soft = demodulate_to_softbits(r, mod, fec, softCfg)
%DEMODULATE_TO_SOFTBITS  Produce Viterbi input metrics.

switch upper(string(mod.type))
    case "BPSK"
        metric = real(r(:));
    otherwise
        error("Unsupported modulation: %s", mod.type);
end

if strcmpi(fec.decisionType, "hard")
    soft = uint8(metric < 0);
    return;
end

ns = fec.softBits;
maxv = 2^ns - 1;
A = softCfg.clipA;

metric = max(min(metric, A), -A);

% Quantize so that 0 => strong '0', maxv => strong '1'
soft = round((A - metric) / (2*A) * maxv);
soft = uint8(max(min(soft, maxv), 0));
end

