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
model.featureVersion = 3;
model.trainingLogicVersion = 6;
model.rxProfile = "impulse";
model.rxFrontend = "impulse_profile_ml_frontend_v1";
model.featureNames = ["real_over_median" "imag_over_median" "abs_r" ...
    "abs_over_median" "absdiff_over_median" "phase_diff" ...
    "abs_over_local_median" "absdev_over_local_median"];
model.cleanOutputMode = "residual_correction";

% 网络参数
model.inputChannels = 8;
model.projectionSize = 16;
model.hiddenSize = 24;
model.outputSize = 4;     % [p_impulse, reliability, delta_clean_real, delta_clean_imag]

% 创建网络层
layers = [
    sequenceInputLayer(model.inputChannels, 'Name', 'input', 'Normalization', 'none')

    fullyConnectedLayer(model.projectionSize, 'Name', 'feature_projection')
    reluLayer('Name', 'projection_relu')

    gruLayer(model.hiddenSize, 'OutputMode', 'sequence', 'Name', 'gru')

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
