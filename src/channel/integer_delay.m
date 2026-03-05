function y = integer_delay(x, d)
%INTEGER_DELAY  整数延迟：y[n] = x[n-d]，超出范围补零。

x = x(:);
d = round(double(d));
if d <= 0
    y = x;
    return;
end
if d >= numel(x)
    y = complex(zeros(size(x)));
    return;
end
y = [complex(zeros(d, 1)); x(1:end-d)];
end

