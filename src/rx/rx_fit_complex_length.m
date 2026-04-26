function yOut = rx_fit_complex_length(yIn, targetLen)
%RX_FIT_COMPLEX_LENGTH Fit a complex vector to the target symbol length.

yIn = yIn(:);
targetLen = round(double(targetLen));
if numel(yIn) >= targetLen
    yOut = yIn(1:targetLen);
else
    yOut = [yIn; complex(zeros(targetLen - numel(yIn), 1))];
end
end
