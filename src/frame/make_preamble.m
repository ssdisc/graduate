function [preambleBits, preambleSym] = make_preamble(L, frameCfg)
%MAKE_PREAMBLE  生成前导（PN或混沌）及其BPSK符号。

if nargin < 2
    frameCfg = struct();
end

preambleType = "pn";
if isfield(frameCfg, "preambleType") && strlength(string(frameCfg.preambleType)) > 0
    preambleType = lower(string(frameCfg.preambleType));
end

switch preambleType
    case "pn"
        pn = comm.PNSequence( ...
            "Polynomial", [1 0 0 1 1], ...
            "InitialConditions", [0 0 0 1], ...
            "SamplesPerFrame", L);
        preambleBits = uint8(pn());
    case {"chaos", "chaotic"}
        chaosMethod = "logistic";
        chaosParams = struct();
        if isfield(frameCfg, "preambleChaosMethod") && strlength(string(frameCfg.preambleChaosMethod)) > 0
            chaosMethod = lower(string(frameCfg.preambleChaosMethod));
        end
        if isfield(frameCfg, "preambleChaosParams") && isstruct(frameCfg.preambleChaosParams)
            chaosParams = frameCfg.preambleChaosParams;
        end
        seq = chaos_generate(L, chaosMethod, chaosParams);
        % 二值化得到近似白序列，其自相关主峰可用于粗同步。
        preambleBits = uint8(seq(:) >= 0.5);
    otherwise
        error("不支持的前导类型: %s", preambleType);
end

preambleSym = 1 - 2*double(preambleBits);
end
