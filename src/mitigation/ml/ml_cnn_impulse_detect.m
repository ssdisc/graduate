function [mask, reliability, cleanSym, pImpulse] = ml_cnn_impulse_detect(rIn, model)
%ML_CNN_IMPULSE_DETECT  使用1D CNN检测脉冲并输出软信息。
%
% 输入:
%   rIn   - 复数接收符号 (N x 1)
%   model - 来自ml_train_cnn_impulse的CNN模型结构体
%           .type, .threshold
%           .inputMean, .inputStd
%           .net（DL模型）
%
% 输出:
%   mask       - 二值脉冲掩码（逻辑型，N x 1）
%   reliability- 译码器的软可靠性权重（0-1，N x 1）
%   cleanSym   - 去噪符号估计（复数，N x 1）
%   pImpulse   - 原始脉冲概率（N x 1）

r = rIn(:);
N = numel(r);

% 提取输入特征
X = ml_cnn_features(r);  % [N x inputChannels]

% 归一化
Xn = (X - model.inputMean) ./ (model.inputStd + 1e-8);

% 仅支持Deep Learning Toolbox模型
if ~isfield(model, 'type') || model.type ~= "cnn_dl"
    error("ml_cnn_impulse_detect:UnsupportedModelType", ...
        "仅支持 type=""cnn_dl"" 的模型，请使用 ml_train_cnn_impulse 重新训练。");
end
[pImpulse, reliability, cleanReal, cleanImag] = dl_forward(Xn, model);

% 确保输出长度匹配
actualN = numel(pImpulse);
if actualN < N
    pImpulse = [pImpulse; 0.5 * ones(N - actualN, 1)];
    reliability = [reliability; ones(N - actualN, 1)];
    cleanReal = [cleanReal; zeros(N - actualN, 1)];
    cleanImag = [cleanImag; zeros(N - actualN, 1)];
elseif actualN > N
    pImpulse = pImpulse(1:N);
    reliability = reliability(1:N);
    cleanReal = cleanReal(1:N);
    cleanImag = cleanImag(1:N);
end

% 应用阈值生成硬掩码
mask = pImpulse >= model.threshold;

% 构造清洁符号
cleanSym = complex(cleanReal, cleanImag);

% 对检测为脉冲的样本降低可靠性
reliability(mask) = reliability(mask) .* (1 - pImpulse(mask));

end

%% Deep Learning Toolbox前向推理
function [pImpulse, reliability, cleanReal, cleanImag] = dl_forward(Xn, model)
%DL_FORWARD  使用dlnetwork进行推理。

% 转换为dlarray格式 'CTB' (Channel x Time x Batch)
XDl = dlarray(single(Xn'), 'CTB');  % [4 x T x 1]

% 前向传播（推理模式）
out = predict(model.net, XDl);  % [4 x T x 1]

% 提取数据并转换为double精度（vitdec需要double）
out = double(extractdata(out));  % [4 x T]

% 解析输出
pImpulse = sigmoid(out(1,:)');       % [N x 1]
reliability = sigmoid(out(2,:)');     % [N x 1]
cleanReal = out(3,:)';               % [N x 1]
cleanImag = out(4,:)';               % [N x 1]

end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-max(min(x, 30), -30)));
end
