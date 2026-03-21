function model = ml_impulse_lr_model()
%ML_IMPULSE_LR_MODEL  轻量级脉冲检测器（逻辑回归）。
%
% 这是一个在伯努利-高斯信道（AWGN+脉冲噪声）上训练的微型ML模型，
% 用于预测哪些接收样本是脉冲。无需深度学习工具箱即可实现ML脉冲抑制。
%
% 特征（每样本）：
%   1) abs(r)
%   2) abs(abs(r) - abs(r_prev))
%   3) abs(r) / median(abs(r))（块鲁棒归一化）
%
% 模型输出p(脉冲|特征)；调用者通常对概率超过model.threshold的样本置零。

model = struct();
model.name = "impulse_lr_v1";
model.features = ["abs_r" "absdiff_abs" "abs_over_median"];
model.trainingLogicVersion = 3;

% 训练数据的归一化（z-score）参数
model.mu = [1.2426; 0.63232774; 1.0477313];
model.sigma = [0.74163985; 0.80829614; 0.58497995];

% 逻辑回归参数（已训练）
model.w = [0.40416938; 0.25381094; 0.9232439];
model.b = -1.742013931274414;

% 选择阈值以在非脉冲样本上达到约1%虚警率
model.threshold = 0.7518097162246704;
end

