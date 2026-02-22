function X = ml_impulse_features(rIn)
%ML_IMPULSE_FEATURES  ML脉冲检测的特征提取。

r = rIn(:);
a = abs(r);

medA = median(a);
z = a ./ (medA + eps);

aPrev = [a(1); a(1:end-1)];
da = abs(a - aPrev);

X = [a, da, z];
end

