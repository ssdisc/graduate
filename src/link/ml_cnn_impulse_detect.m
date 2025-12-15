function [mask, reliability, cleanSym, pImpulse] = ml_cnn_impulse_detect(rIn, model)
%ML_CNN_IMPULSE_DETECT  使用1D CNN检测脉冲并输出软信息。
%
% 输入:
%   rIn   - 复数接收符号 (N x 1)
%   model - 来自ml_train_cnn_impulse的已训练CNN模型
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

% 检查模型类型
if isfield(model, 'type') && model.type == "cnn_dl"
    % Deep Learning Toolbox dlnetwork推理
    [pImpulse, reliability, cleanReal, cleanImag] = dl_forward(Xn, model);
else
    % 旧版手动CNN推理（向后兼容）
    [pImpulse, reliability, cleanReal, cleanImag] = legacy_forward(Xn, model, N);
end

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

N = size(Xn, 1);

% 转换为dlarray格式 'CTB' (Channel x Time x Batch)
XDl = dlarray(single(Xn'), 'CTB');  % [4 x N x 1]

% 前向传播（推理模式）
out = predict(model.net, XDl);  % [4 x N x 1]

% 提取数据并转换为double精度（vitdec需要double）
out = double(extractdata(out));  % [4 x N]

% 解析输出
pImpulse = sigmoid(out(1,:)');       % [N x 1]
reliability = sigmoid(out(2,:)');     % [N x 1]
cleanReal = out(3,:)';               % [N x 1]
cleanImag = out(4,:)';               % [N x 1]

end

%% 旧版手动CNN前向推理（向后兼容）
function [pImpulse, reliability, cleanReal, cleanImag] = legacy_forward(Xn, model, N)
%LEGACY_FORWARD  使用手动实现的CNN进行推理。

% 计算填充以保持卷积后的输出大小
K1 = model.conv1KernelSize;
K2 = model.conv2KernelSize;
totalKernelLoss = (K1 - 1) + (K2 - 1);
padLen = ceil(totalKernelLoss / 2) + model.halfWin;

% 填充输入
Xpad = [repmat(Xn(1,:), padLen, 1); Xn; repmat(Xn(end,:), padLen, 1)];

% 前向传播
% Conv1 + ReLU
h1 = conv1d_forward(Xpad, model.W1, model.b1);
h1 = max(h1, 0);

% Conv2 + ReLU
h2 = conv1d_forward(h1, model.W2, model.b2);
h2 = max(h2, 0);

% 裁剪到原始长度
h2Len = size(h2, 1);
trimStart = max(1, floor((h2Len - N) / 2) + 1);
trimEnd = min(h2Len, trimStart + N - 1);
h2 = h2(trimStart:trimEnd, :);

% 输出层
out = h2 * model.Wo + model.bo;

% 解析输出
pImpulse = sigmoid(out(:, 1));
reliability = sigmoid(out(:, 2));
cleanReal = out(:, 3);
cleanImag = out(:, 4);

end

function y = conv1d_forward(x, W, b)
%CONV1D_FORWARD  1D卷积（valid模式）。

[T, Cin] = size(x);
[K, ~, Cout] = size(W);
Tout = T - K + 1;

y = zeros(Tout, Cout);
for co = 1:Cout
    for ci = 1:Cin
        kernel = W(:, ci, co);
        y(:, co) = y(:, co) + conv(x(:, ci), flipud(kernel), 'valid');
    end
    y(:, co) = y(:, co) + b(co);
end
end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-max(min(x, 30), -30)));
end
