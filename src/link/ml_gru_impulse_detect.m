function [mask, reliability, cleanSym, pImpulse] = ml_gru_impulse_detect(rIn, model)
%ML_GRU_IMPULSE_DETECT  使用GRU检测脉冲并输出软信息。
%
% 输入:
%   rIn   - 复数接收符号 (N x 1)
%   model - 来自ml_train_gru_impulse的已训练GRU模型
%
% 输出:
%   mask       - 二值脉冲掩码（逻辑型，N x 1）
%   reliability- 译码器的软可靠性权重（0-1，N x 1）
%   cleanSym   - 去噪符号估计（复数，N x 1）
%   pImpulse   - 原始脉冲概率（N x 1）

r = rIn(:);
N = numel(r);

% 提取输入特征
X = ml_cnn_features(r);  % 复用相同的特征提取

% 归一化
Xn = (X - model.inputMean) ./ (model.inputStd + 1e-8);

% GRU前向传播
hs = model.hiddenSize;
h = zeros(1, hs);  % 初始隐藏状态

outputs = zeros(N, model.outputSize);

for t = 1:N
    xt = Xn(t, :);

    % 重置门
    rt = sigmoid(xt * model.Wr + h * model.Ur + model.br);

    % 更新门
    zt = sigmoid(xt * model.Wz + h * model.Uz + model.bz);

    % 候选隐藏状态
    h_tilde = tanh(xt * model.Wh + (rt .* h) * model.Uh + model.bh);

    % 新隐藏状态
    h = (1 - zt) .* h + zt .* h_tilde;

    % 输出
    outputs(t, :) = h * model.Wo + model.bo;
end

% 解析输出
pImpulse = sigmoid(outputs(:, 1));
reliability = sigmoid(outputs(:, 2));
cleanReal = outputs(:, 3);
cleanImag = outputs(:, 4);

% 应用阈值
mask = pImpulse >= model.threshold;

% 构造清洁符号
cleanSym = complex(cleanReal, cleanImag);

% 对检测为脉冲的样本降低可靠性
reliability(mask) = reliability(mask) .* (1 - pImpulse(mask));

end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-max(min(x, 30), -30)));
end
