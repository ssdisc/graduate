function [blk, ok] = extract_fractional_block(x, startPos, nSamp)
% 从可能带分数起点的位置提取定长序列。
x = x(:);
if nSamp <= 0 || isempty(x)
    blk = complex(zeros(0, 1));
    ok = false;
    return;
end
t = startPos + (0:nSamp-1).';
% 允许轻微越界（线性外推为0），避免分数定时下末尾判定失败
guard = 2;
if t(1) < 1 - guard || t(end) > numel(x) + guard
    blk = complex(zeros(nSamp, 1));
    ok = false;
    return;
end
idx = (1:numel(x)).';
blk = interp1(idx, x, t, "linear", 0);
ok = all(isfinite(blk)) && any(abs(blk) > 0);
end

