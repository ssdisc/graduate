function model = ml_gru_impulse_model()
%ML_GRU_IMPULSE_MODEL  返回基于Deep Learning Toolbox的GRU脉冲检测器。
%
% 使用dlnetwork创建网络，支持GPU加速训练。
%
% 输出:
%   - 每样本的脉冲概率
%   - 软译码的可靠性权重
%   - 清洁符号估计

model = struct();
model.name = "impulse_gru_dl";
model.type = "gru_dl";
model.trained = false;
model.featureVersion = 2;
model.featureNames = ["abs_r" "abs_over_median" "absdiff_abs" "phase_diff"];

% 网络参数
model.inputChannels = 4;  % [幅度, 归一化幅度, 幅度差分, 差分相位]
model.hiddenSize = 32;    % GRU隐藏状态大小
model.outputSize = 4;     % [p_impulse, reliability, clean_real, clean_imag]

% 创建网络层
layers = [
    sequenceInputLayer(model.inputChannels, 'Name', 'input', 'Normalization', 'none')

    % GRU层
    gruLayer(model.hiddenSize, 'OutputMode', 'sequence', 'Name', 'gru')

    % 全连接输出层
    fullyConnectedLayer(model.outputSize, 'Name', 'fc_out')
];

% 创建dlnetwork
model.net = dlnetwork(layers);

% 检测阈值
model.threshold = 0.5;

% 归一化统计量（训练时计算）
model.inputMean = zeros(1, model.inputChannels);
model.inputStd = ones(1, model.inputChannels);

end
