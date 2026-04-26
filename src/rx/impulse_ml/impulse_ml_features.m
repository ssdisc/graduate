function X = impulse_ml_features(rIn)
%IMPULSE_ML_FEATURES Feature contract for impulse-profile ML front-ends.

r = rIn(:);
absPart = abs(r);
globalScale = median(absPart);
globalScale = max(globalScale, eps);

realNorm = real(r) ./ globalScale;
imagNorm = imag(r) ./ globalScale;
normAbsPart = absPart ./ globalScale;

absPrev = [absPart(1); absPart(1:end-1)];
absDiffNorm = abs(absPart - absPrev) ./ globalScale;

rPrev = [r(1); r(1:end-1)];
phaseDiff = angle(r .* conj(rPrev));

localScale = movmedian(absPart, 17, "Endpoints", "shrink");
localScale = max(localScale, eps);
localAbsRatio = absPart ./ localScale;
localAbsDeviation = abs(absPart - localScale) ./ localScale;

X = [realNorm, imagNorm, absPart, normAbsPart, absDiffNorm, ...
    phaseDiff, localAbsRatio, localAbsDeviation];
end
