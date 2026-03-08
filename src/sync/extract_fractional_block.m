function [blk, ok, info] = extract_fractional_block(x, startPos, nSamp, syncCfg, modCfg)
% 从可能带分数起点的位置提取定长序列。
if nargin < 4
    syncCfg = struct();
end
if nargin < 5
    modCfg = struct("type", "BPSK");
end

x = x(:);
if nSamp <= 0 || isempty(x)
    blk = complex(zeros(0, 1));
    ok = false;
    info = struct("dllEnabled", false);
    return;
end

if isfield(syncCfg, "timingDll") && isstruct(syncCfg.timingDll) ...
        && isfield(syncCfg.timingDll, "enable") && syncCfg.timingDll.enable
    [blk, ok, dllInfo] = timing_dll_sync(x, startPos, nSamp, modCfg, syncCfg.timingDll);
    info = struct("dllEnabled", true, "dll", dllInfo);
    return;
end

t = startPos + (0:nSamp-1).';
% 允许轻微越界（线性外推为0），避免分数定时下末尾判定失败
guard = 2;
if t(1) < 1 - guard
    blk = complex(zeros(nSamp, 1));
    ok = false;
    info = struct("dllEnabled", false);
    return;
end
idx = (1:numel(x)).';
blk = interp1(idx, x, t, "linear", 0);
ok = all(isfinite(blk)) && any(abs(blk) > 0);
info = struct("dllEnabled", false);
end

