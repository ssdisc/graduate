function rxDehopped = fh_demodulate(rxSym, hopInfo)
%FH_DEMODULATE  跳频解调（接收端）。
%
% 移除跳频符号的频率偏移，恢复基带信号。
%
% 输入:
%   rxSym   - 接收到的跳频符号 (复数列向量)
%   hopInfo - 跳频信息结构体（来自fh_modulate）
%
% 输出:
%   rxDehopped - 解跳后的基带符号
%
% 解跳原理:
%   乘以发送端相位旋转的共轭: exp(-j*2*pi*f_k*n/Fs)

arguments
    rxSym (:,1)
    hopInfo (1,1) struct
end

if ~hopInfo.enable
    % 跳频禁用，直接返回
    rxDehopped = rxSym;
    return;
end

nSym = numel(rxSym);
hopLen = hopInfo.hopLen;
nHops = hopInfo.nHops;
freqOffsets = hopInfo.freqOffsets;

% 解跳
rxDehopped = complex(zeros(size(rxSym)));

for hop = 1:nHops
    % 当前跳的符号范围
    startIdx = (hop - 1) * hopLen + 1;
    endIdx = min(hop * hopLen, nSym);

    if startIdx > nSym
        break;
    end
    endIdx = min(endIdx, nSym);
    hopSymCount = endIdx - startIdx + 1;

    % 当前跳的频率偏移
    f_hop = freqOffsets(hop);

    % 生成解跳相位序列（共轭）
    n = (0:hopSymCount-1)';
    phaseDerot = exp(-1j * 2 * pi * f_hop * n);

    % 移除频率偏移
    rxDehopped(startIdx:endIdx) = rxSym(startIdx:endIdx) .* phaseDerot;
end

end
