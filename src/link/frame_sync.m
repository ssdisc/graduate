function idx = frame_sync(r, preambleSym)
%FRAME_SYNC  通过与已知前导的相关实现粗帧同步。

r = r(:);
p = preambleSym(:);
if numel(r) < numel(p)
    idx = [];
    return;
end

c = abs(conv(r, flipud(conj(p)), 'valid'));
[~, k] = max(c);
idx = k;
end

