function [sym, info] = modulate_bits(bits, mod, fec)
%MODULATE_BITS  将比特映射到复基带符号。
%
% 输入:
%   bits - 输入比特流
%   mod  - 调制参数结构体
%          .type - 调制类型（支持"BPSK"/"QPSK"/"MSK"）
%   fec  - （可选）payload FEC配置，用于回传真实码率
%
% 输出:
%   sym  - 调制后的符号序列
%   info - 调制信息结构体
%          .bitsPerSymbol, .codeRate

bits = uint8(bits(:) ~= 0);
switch upper(string(mod.type))
    case "BPSK"
        sym = 1 - 2*double(bits); % 0->+1, 1->-1
        info.bitsPerSymbol = 1;
    case "QPSK"
        if rem(numel(bits), 2) ~= 0
            error("QPSK输入比特数必须为偶数，当前为%d。", numel(bits));
        end
        bits2 = reshape(bits, 2, []);
        bI = double(bits2(1, :)).';
        bQ = double(bits2(2, :)).';
        sym = ((1 - 2*bI) + 1j*(1 - 2*bQ)) / sqrt(2);% 0->+1, 1->-1，归一化功率
        info.bitsPerSymbol = 2;
    case "MSK"
        % 最小频移键控（h=0.5）的离散相位实现：
        % 每比特引入±pi/2相位增量，得到常包络连续相位序列。
        dPhi = (1 - 2*double(bits)) * (pi/2); % bit0:+pi/2, bit1:-pi/2
        phase = cumsum(dPhi);
        sym = exp(1j * phase);
        info.bitsPerSymbol = 1;
    otherwise
        error("不支持的调制方式: %s", mod.type);
end

if nargin >= 3 && ~isempty(fec)
    fecInfo = fec_get_info(fec);
    info.codeRate = fecInfo.codeRate;
else
    info.codeRate = 1.0;
end
info.spreadFactor = 1;
info.bitLoad = info.bitsPerSymbol * info.codeRate;
end

