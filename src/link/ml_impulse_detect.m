function [mask, p] = ml_impulse_detect(rIn, model)
%ML_IMPULSE_DETECT  使用小型ML模型预测脉冲样本。

r = rIn(:);
X = ml_impulse_features(r);

mu = reshape(model.mu(:), 1, []);
sigma = reshape(model.sigma(:), 1, []);
Xn = (X - mu) ./ sigma;

logit = Xn * model.w(:) + model.b;
logit = max(min(logit, 30), -30);
p = 1 ./ (1 + exp(-logit));

mask = p >= model.threshold;
end
