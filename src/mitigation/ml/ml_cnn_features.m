function X = ml_cnn_features(rIn)
%ML_CNN_FEATURES  提取CNN脉冲检测器的输入特征。
%
% 输入:
%   rIn - 复数接收符号 (N x 1)
%
% 输出:
%   X   - 特征矩阵 [N x 4]: [幅度, 归一化幅度, 幅度差分, 差分相位]

r = rIn(:);
absPart = abs(r);
medAbs = median(absPart);
normAbsPart = absPart ./ (medAbs + eps);

% 与开题报告一致，使用绝对幅度差分而非带符号梯度。
absPrev = [absPart(1); absPart(1:end-1)];
absDiff = abs(absPart - absPrev);

% 使用差分相位而非绝对相位，减弱残余公共相位旋转的影响。
rPrev = [r(1); r(1:end-1)];
phaseDiff = angle(r .* conj(rPrev));

X = [absPart, normAbsPart, absDiff, phaseDiff];

end
