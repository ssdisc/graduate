function bitsOut = fit_bits_length(bitsIn, targetLen)
bitsIn = uint8(bitsIn(:) ~= 0);
targetLen = max(0, round(double(targetLen)));
if numel(bitsIn) >= targetLen
    bitsOut = bitsIn(1:targetLen);
else
    bitsOut = [bitsIn; zeros(targetLen - numel(bitsIn), 1, "uint8")];
end
end

