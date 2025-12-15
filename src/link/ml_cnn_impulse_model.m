function model = ml_cnn_impulse_model()
%ML_CNN_IMPULSE_MODEL  返回默认（未训练）的1D CNN脉冲检测器。
%
% 提供一个轻量级1D CNN用于脉冲检测，输出：
%   - 每样本的脉冲概率
%   - 软译码的可靠性权重
%   - 清洁/去噪符号估计
%
% 模型使用因果卷积以避免前瞻。

model = struct();
model.name = "impulse_cnn_1d";
model.type = "cnn";

% 架构：输入 -> Conv1D -> ReLU -> Conv1D -> Sigmoid
% 窗口大小 = 2*halfWin + 1（每个样本周围的上下文）
model.halfWin = 4;  % 前后各看4个样本（共9个）

% 第1层：Conv1D（输入：2通道 [real, imag] 或 [abs, phase]）
model.inputChannels = 4;  % [实部, 虚部, 幅度, 幅度差分]
model.conv1Filters = 16;
model.conv1KernelSize = 5;

% 第2层：Conv1D
model.conv2Filters = 8;
model.conv2KernelSize = 3;

% 输出层：每样本3个输出
%   1. p_impulse：该样本被污染的概率
%   2. reliability：译码器的软权重（0=忽略，1=信任）
%   3. clean_real, clean_imag：去噪符号估计
model.outputSize = 4;  % [p_impulse, reliability, clean_real, clean_imag]

% 初始化权重（训练时会被覆盖）
model.trained = false;

% Conv1权重：[kernelSize, inputChannels, nFilters]
rng(42);
scale1 = sqrt(2 / (model.conv1KernelSize * model.inputChannels));
model.W1 = scale1 * randn(model.conv1KernelSize, model.inputChannels, model.conv1Filters);
model.b1 = zeros(1, model.conv1Filters);

% Conv2权重
scale2 = sqrt(2 / (model.conv2KernelSize * model.conv1Filters));
model.W2 = scale2 * randn(model.conv2KernelSize, model.conv1Filters, model.conv2Filters);
model.b2 = zeros(1, model.conv2Filters);

% 输出层（从conv2输出的全连接层）
model.Wo = 0.1 * randn(model.conv2Filters, model.outputSize);
model.bo = zeros(1, model.outputSize);
model.bo(2) = 1.0;  % 偏置reliability趋向1（默认信任）

% 检测阈值
model.threshold = 0.5;

% 归一化统计量（训练时计算）
model.inputMean = zeros(1, model.inputChannels);
model.inputStd = ones(1, model.inputChannels);

end
