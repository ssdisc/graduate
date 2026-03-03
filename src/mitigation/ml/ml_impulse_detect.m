function [mask, p] = ml_impulse_detect(rIn, model)
%ML_IMPULSE_DETECT  使用小型ML模型预测脉冲样本。
%
% 输入:
%   rIn   - 复数接收符号 (N x 1)
%   model - 逻辑回归模型结构体
%           .mu, .sigma - 特征归一化参数
%           .w, .b      - 线性分类器参数
%           .threshold  - 判决阈值
%
% 输出:
%   mask - 二值脉冲掩码
%   p    - 脉冲概率

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
