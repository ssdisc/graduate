function valueOut = rx_expand_reliability(valueIn, targetLen)
%RX_EXPAND_RELIABILITY Fit a reliability vector to the target symbol length.

valueIn = double(valueIn(:));
targetLen = round(double(targetLen));
if isempty(valueIn)
    valueOut = ones(targetLen, 1);
    return;
end

if numel(valueIn) >= targetLen
    valueOut = valueIn(1:targetLen);
else
    valueOut = [valueIn; repmat(valueIn(end), targetLen - numel(valueIn), 1)];
end
valueOut = max(0, min(1, valueOut));
end
