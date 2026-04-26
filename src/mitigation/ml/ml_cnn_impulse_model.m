function model = ml_cnn_impulse_model()
%ML_CNN_IMPULSE_MODEL  返回基于Deep Learning Toolbox的1D CNN脉冲检测器。
%
% 使用dlnetwork创建网络，支持GPU加速训练。
%
% 输出:
%   - 每样本的脉冲/抑制概率
%   - 每样本 keep 系数（soft blanking）
%   - 预留辅助通道

model = struct();
model.name = "impulse_cnn_softblank_distill_v2";
model.type = "cnn_dl";
model.trained = false;
model.featureVersion = 3;
model.trainingLogicVersion = 9;
model.rxProfile = "impulse";
model.rxFrontend = "impulse_profile_ml_frontend_v1";
model.featureNames = ["real_over_median" "imag_over_median" "abs_r" ...
    "abs_over_median" "absdiff_over_median" "phase_diff" ...
    "abs_over_local_median" "absdev_over_local_median"];
model.cleanOutputMode = "soft_blanking_distilled";

% 网络参数
model.inputChannels = 8;
model.outputSize = 4;     % [p_impulse, keep_weight, aux1, aux2]

% 创建网络层
layers = [
    sequenceInputLayer(model.inputChannels, 'Name', 'input', 'Normalization', 'none')

    % 轻量TCN式局部上下文，比旧两层CNN更适合识别短突发脉冲。
    convolution1dLayer(9, 16, 'Padding', 'same', 'Name', 'conv_wide')
    reluLayer('Name', 'relu1')

    convolution1dLayer(5, 24, 'Padding', 'same', 'Name', 'conv_mid1')
    reluLayer('Name', 'relu2')

    convolution1dLayer(5, 24, 'Padding', 'same', 'Name', 'conv_mid2')
    reluLayer('Name', 'relu3')

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
