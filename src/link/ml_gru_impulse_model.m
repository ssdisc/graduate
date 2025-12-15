function model = ml_gru_impulse_model()
%ML_GRU_IMPULSE_MODEL  返回默认（未训练）的GRU脉冲检测器。
%
% GRU（门控循环单元）对于时序数据中脉冲检测的时间上下文非常有效。

model = struct();
model.name = "impulse_gru";
model.type = "gru";

% 架构
model.inputSize = 4;     % [实部, 虚部, 幅度, 幅度差分]
model.hiddenSize = 16;   % GRU隐藏状态大小
model.outputSize = 4;    % [p_impulse, reliability, clean_real, clean_imag]

% 初始化GRU权重
% GRU有3个门：重置门(r)、更新门(z)和候选门(h~)
% 每个门都有输入权重(W)和隐藏权重(U)
rng(42);
hs = model.hiddenSize;
is = model.inputSize;

% Xavier初始化
scaleW = sqrt(2 / (is + hs));
scaleU = sqrt(2 / (hs + hs));

% 重置门
model.Wr = scaleW * randn(is, hs);
model.Ur = scaleU * randn(hs, hs);
model.br = zeros(1, hs);

% 更新门
model.Wz = scaleW * randn(is, hs);
model.Uz = scaleU * randn(hs, hs);
model.bz = zeros(1, hs);

% 候选隐藏状态
model.Wh = scaleW * randn(is, hs);
model.Uh = scaleU * randn(hs, hs);
model.bh = zeros(1, hs);

% 输出层
model.Wo = 0.1 * randn(hs, model.outputSize);
model.bo = [0, 1, 0, 0];  % 偏置reliability趋向1

% 检测阈值
model.threshold = 0.5;

% 归一化
model.inputMean = zeros(1, is);
model.inputStd = ones(1, is);

model.trained = false;

end
