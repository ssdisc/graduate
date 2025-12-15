function x = deinterleave_bits(y, state, inter)
%DEINTERLEAVE_BITS  Inverse of interleave_bits.

if ~inter.enable
    x = y(:);
    return;
end
mat = reshape(y, state.nRows, state.nCols);
xPad = reshape(mat.', [], 1);
if state.pad > 0
    x = xPad(1:end-state.pad);
else
    x = xPad;
end
end

