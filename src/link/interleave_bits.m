function [y, state] = interleave_bits(x, inter)
%INTERLEAVE_BITS  简单块交织器。

if ~inter.enable
    y = x(:);
    state = struct("pad", 0, "nRows", 1, "nCols", numel(y));
    return;
end

nRows = inter.nRows;
n = numel(x);
nCols = ceil(n / nRows);
pad = nRows*nCols - n;
xPad = [x(:); zeros(pad, 1, 'like', x)];

mat = reshape(xPad, nCols, nRows).';
y = mat(:);

state = struct("pad", pad, "nRows", nRows, "nCols", nCols);
end

