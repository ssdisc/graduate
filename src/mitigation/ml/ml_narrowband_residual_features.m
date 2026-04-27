function [featureMatrix, scale] = ml_narrowband_residual_features(x)
%ML_NARROWBAND_RESIDUAL_FEATURES Per-symbol local features for residual CNN.

r = x(:);
N = numel(r);
if N == 0
    featureMatrix = zeros(0, 6);
    scale = 1;
    return;
end

mag = abs(r);
validMag = mag(isfinite(mag) & mag > 1e-8);
if isempty(validMag)
    scale = 1;
else
    scale = median(validMag);
end
if ~(isfinite(scale) && scale > 1e-8)
    scale = 1;
end

prev = [r(1); r(1:max(N - 1, 1))];
if N == 1
    prev = r;
end
dr = r - prev(1:N);
localAbs = movmean(mag, min(9, max(1, N)), "Endpoints", "shrink");

featureMatrix = [ ...
    real(r) ./ scale, ...
    imag(r) ./ scale, ...
    mag ./ scale, ...
    real(dr) ./ scale, ...
    imag(dr) ./ scale, ...
    localAbs ./ scale];
featureMatrix(~isfinite(featureMatrix)) = 0;
end
