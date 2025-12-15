function X = ml_cnn_features(rIn)
%ML_CNN_FEATURES  Extract input features for CNN impulse detector.
%
% Input:
%   rIn - Complex received symbols (N x 1)
%
% Output:
%   X   - Feature matrix [N x 4]: [real, imag, abs, abs_diff]

r = rIn(:);
N = numel(r);

% Feature 1-2: Real and imaginary parts
realPart = real(r);
imagPart = imag(r);

% Feature 3: Magnitude
absPart = abs(r);

% Feature 4: Magnitude difference (gradient)
absDiff = [0; diff(absPart)];

X = [realPart, imagPart, absPart, absDiff];

end
