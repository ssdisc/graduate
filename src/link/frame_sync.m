function idx = frame_sync(r, preambleSym)
%FRAME_SYNC  Coarse frame sync by correlation with known preamble.

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

