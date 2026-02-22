function model = ml_cnn_impulse_model()
%ML_CNN_IMPULSE_MODEL  返回基于Deep Learning Toolbox的1D CNN脉冲检测器。
%
% 使用dlnetwork创建网络，支持GPU加速训练。
%
% 输出:
%   - 每样本的脉冲概率
%   - 软译码的可靠性权重
%   - 清洁符号估计

model = struct();
model.name = "impulse_cnn_1d";
model.type = "cnn_dl";
model.trained = false;

% 网络参数
model.inputChannels = 4;  % [幅度, 归一化幅度, 幅度差分, 相位]
model.outputSize = 4;     % [p_impulse, reliability, clean_real, clean_imag]

% 创建网络层
layers = [
    sequenceInputLayer(model.inputChannels, 'Name', 'input', 'Normalization', 'none')

    % Conv1: 16个滤波器，核大小5
    convolution1dLayer(5, 16, 'Padding', 'same', 'Name', 'conv1')
    batchNormalizationLayer('Name', 'bn1')
    reluLayer('Name', 'relu1')

    % Conv2: 32个滤波器，核大小3
    convolution1dLayer(3, 32, 'Padding', 'same', 'Name', 'conv2')
    batchNormalizationLayer('Name', 'bn2')
    reluLayer('Name', 'relu2')

    % Conv3: 输出层，4个滤波器
    convolution1dLayer(1, model.outputSize, 'Padding', 'same', 'Name', 'conv_out')
];

% 创建dlnetwork
model.net = dlnetwork(layers);

% 检测阈值
model.threshold = 0.5;

% 归一化统计量（训练时计算）
model.inputMean = zeros(1, model.inputChannels);
model.inputStd = ones(1, model.inputChannels);

end
