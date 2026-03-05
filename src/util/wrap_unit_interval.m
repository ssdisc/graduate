function x = wrap_unit_interval(x)
x = mod(double(x), 1.0);
if x <= 0
    x = x + eps;
elseif x >= 1
    x = 1 - eps;
end
end

