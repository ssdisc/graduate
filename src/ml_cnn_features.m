function X = ml_cnn_features(rIn)
%ML_CNN_FEATURES  提取CNN脉冲检测器的输入特征。
%
% 输入:
%   rIn - 复数接收符号 (N x 1)
%
% 输出:
%   X   - 特征矩阵 [N x 4]: [实部, 虚部, 幅度, 幅度差分]

r = rIn(:);
N = numel(r);

% 特征1-2：实部和虚部
realPart = real(r);
imagPart = imag(r);

% 特征3：幅度
absPart = abs(r);

% 特征4：幅度差分（梯度）
absDiff = [0; diff(absPart)];

X = [realPart, imagPart, absPart, absDiff];

end
