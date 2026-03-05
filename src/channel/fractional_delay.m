function y = fractional_delay(x, d)
%FRACTIONAL_DELAY  分数延迟：y[n] = x[n-d]，d>0表示向右延时。

idx = (1:numel(x)).';
query = idx - d;
y = interp1(idx, x, query, "linear", 0);
end

