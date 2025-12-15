function X = ml_impulse_features(rIn)
%ML_IMPULSE_FEATURES  Feature extraction for ML-based impulse detection.

r = rIn(:);
a = abs(r);

medA = median(a);
z = a ./ (medA + eps);

aPrev = [a(1); a(1:end-1)];
da = abs(a - aPrev);

X = [a, da, z];
end

