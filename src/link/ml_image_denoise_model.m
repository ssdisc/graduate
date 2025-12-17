function model = ml_image_denoise_model(varargin)
%ML_IMAGE_DENOISE_MODEL  创建基于DnCNN的图像降噪模型。
%
% 用法:
%   model = ml_image_denoise_model()
%   model = ml_image_denoise_model('depth', 10, 'filters', 64)
%
% 可选参数:
%   depth   - 网络深度（卷积层数），默认17
%   filters - 每层滤波器数量，默认64
%
% 输出:
%   model - 包含网络结构和参数的结构体
%
% 网络架构（DnCNN残差学习）:
%   输入 → Conv(filters,3) → ReLU
%       → [Conv(filters,3) → BN → ReLU] × (depth-2)
%       → Conv(1,3) → 残差输出
%   去噪图像 = 输入图像 - 残差

p = inputParser;
addParameter(p, 'depth', 17, @isnumeric);
addParameter(p, 'filters', 64, @isnumeric);
parse(p, varargin{:});

depth = p.Results.depth;
filters = p.Results.filters;

model = struct();
model.name = "image_denoise_dncnn";
model.type = "dncnn_dl";
model.trained = false;
model.depth = depth;
model.filters = filters;

% 创建DnCNN网络层（简化版，不使用BatchNormalization避免训练/推理不一致）
layers = [
    imageInputLayer([64 64 1], 'Name', 'input', 'Normalization', 'none')

    % 第一层：Conv + ReLU
    convolution2dLayer(3, filters, 'Padding', 'same', 'Name', 'conv1')
    reluLayer('Name', 'relu1')
];

% 中间层：Conv + ReLU（不使用BN）
for i = 2:(depth-1)
    layers = [layers
        convolution2dLayer(3, filters, 'Padding', 'same', 'Name', sprintf('conv%d', i))
        reluLayer('Name', sprintf('relu%d', i))
    ];
end

% 最后一层：Conv（输出残差，不加激活函数以允许负值）
layers = [layers
    convolution2dLayer(3, 1, 'Padding', 'same', 'Name', 'conv_out')
];

% 创建dlnetwork
model.net = dlnetwork(layers);

% 训练参数默认值
model.patchSize = 64;
model.batchSize = 32;
model.learningRate = 1e-3;

end
