function [mask, reliability, cleanSym, pImpulse] = ml_cnn_impulse_detect(rIn, model)
%ML_CNN_IMPULSE_DETECT  使用1D CNN检测脉冲并输出软信息。
%
% 输入:
%   rIn   - 复数接收符号 (N x 1)
%   model - 来自ml_train_cnn_impulse的CNN模型结构体
%           .type, .threshold
%           .inputMean, .inputStd
%           .net（DL模型）
%
% 输出:
%   mask       - 二值脉冲掩码（逻辑型，N x 1）
%   reliability- 译码器的软可靠性权重（0-1，N x 1）
%   cleanSym   - 去噪符号估计（复数，N x 1）
%   pImpulse   - 原始脉冲概率（N x 1）

[mask, reliability, cleanSym, pImpulse] = impulse_ml_predict(rIn, model, "cnn_dl");
end
