function model = ml_impulse_lr_model()
%ML_IMPULSE_LR_MODEL  Lightweight impulse detector (logistic regression).
%
% This is a tiny ML model trained on the repo's Bernoulli-Gaussian channel
% (AWGN + impulsive noise) to predict which received samples are impulsive.
% It enables ML-based mitigation without requiring Deep Learning Toolbox.
%
% Features (per sample):
%   1) abs(r)
%   2) abs(abs(r) - abs(r_prev))
%   3) abs(r) / median(abs(r))  (block-robust normalization)
%
% The model outputs p(impulse | features); callers typically blank samples
% whose probability exceeds model.threshold.

model = struct();
model.name = "impulse_lr_v1";
model.features = ["abs_r" "absdiff_abs" "abs_over_median"];

% Normalization (z-score) parameters from training data
model.mu = [1.2426; 0.63232774; 1.0477313];
model.sigma = [0.74163985; 0.80829614; 0.58497995];

% Logistic regression parameters (trained)
model.w = [0.40416938; 0.25381094; 0.9232439];
model.b = -1.742013931274414;

% Threshold chosen to target ~1% false alarm rate on non-impulse samples.
model.threshold = 0.7518097162246704;
end

