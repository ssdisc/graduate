function model = ml_impulse_lr_model()
%ML_IMPULSE_LR_MODEL  采样级逻辑回归脉冲检测器的未训练占位模型。

model = struct();
model.name = "impulse_lr_v2";
model.trained = false;
model.features = ["abs_r" "absdiff_abs" "abs_over_median"];
model.trainingLogicVersion = 4;

% 训练完成前仅保留结构占位，禁止再复用旧符号级权重。
model.mu = zeros(3, 1);
model.sigma = ones(3, 1);

% 默认输出接近0概率，避免未训练模型误伤样本。
model.w = zeros(3, 1);
model.b = -20;

model.threshold = 0.5;
end

