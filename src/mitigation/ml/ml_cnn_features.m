function X = ml_cnn_features(rIn)
%ML_CNN_FEATURES  提取CNN脉冲检测器的输入特征。
%
% 输入:
%   rIn - 复数接收符号 (N x 1)
%
% 输出:
%   X   - 特征矩阵 [N x 8]，由 impulse profile 专用特征合同定义。

X = impulse_ml_features(rIn);
end
