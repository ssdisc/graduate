%TRAIN_IMAGE_DENOISE_MODEL  训练接收端图像降噪DnCNN模型。
%
% 用法:
%   1. 直接运行此脚本
%   2. 训练好的模型将保存到 models/image_denoise_model.mat
%   3. 在仿真中使用：
%      p = default_params();
%      load('models/image_denoise_model.mat', 'denoiseModel');
%      p.denoise.enable = true;
%      p.denoise.model = denoiseModel;
%      results = simulate(p);

clear; clc;
fprintf('=== 图像降噪DnCNN模型训练 ===\n\n');

% 添加路径
addpath(genpath('link'));

% 加载默认参数
p = default_params();

% 训练参数
trainOpts = struct();
trainOpts.epochs = 30;       % 训练轮数
trainOpts.nImages = 50;      % 训练图像数量
trainOpts.depth = 17;        % 网络深度
trainOpts.filters = 64;      % 滤波器数量
trainOpts.patchSize = 64;    % patch大小
trainOpts.batchSize = 32;    % 批大小
trainOpts.lr = 1e-3;         % 学习率
trainOpts.verbose = true;    % 显示进度

% 开始训练
fprintf('训练参数:\n');
fprintf('  - 训练轮数: %d\n', trainOpts.epochs);
fprintf('  - 训练图像数: %d\n', trainOpts.nImages);
fprintf('  - 网络深度: %d\n', trainOpts.depth);
fprintf('  - 滤波器数量: %d\n', trainOpts.filters);
fprintf('  - Patch大小: %d\n', trainOpts.patchSize);
fprintf('  - 批大小: %d\n', trainOpts.batchSize);
fprintf('  - 学习率: %.4f\n\n', trainOpts.lr);

tic;
[denoiseModel, report] = ml_train_image_denoise(p, ...
    'epochs', trainOpts.epochs, ...
    'nImages', trainOpts.nImages, ...
    'depth', trainOpts.depth, ...
    'filters', trainOpts.filters, ...
    'patchSize', trainOpts.patchSize, ...
    'batchSize', trainOpts.batchSize, ...
    'lr', trainOpts.lr, ...
    'verbose', trainOpts.verbose);
trainTime = toc;

fprintf('\n训练完成！\n');
fprintf('  - 训练时间: %.1f 秒\n', trainTime);
fprintf('  - 最终损失: %.6f\n', report.finalLoss);
fprintf('  - 训练patch数: %d\n', report.nPatches);

% 保存模型
modelsDir = fullfile(pwd, 'models');
if ~exist(modelsDir, 'dir')
    mkdir(modelsDir);
end

modelPath = fullfile(modelsDir, 'image_denoise_model.mat');
save(modelPath, 'denoiseModel', 'report', 'trainOpts');
fprintf('\n模型已保存到: %s\n', modelPath);

% 绘制训练曲线
figure('Name', '训练损失曲线');
plot(1:report.epochs, report.lossHistory, 'b-', 'LineWidth', 1.5);
xlabel('Epoch');
ylabel('MSE Loss');
title('图像降噪模型训练损失');
grid on;

% 保存图像
figPath = fullfile(modelsDir, 'denoise_training_loss.png');
saveas(gcf, figPath);
fprintf('训练曲线已保存到: %s\n', figPath);

fprintf('\n=== 使用方法 ===\n');
fprintf('p = default_params();\n');
fprintf('load(''models/image_denoise_model.mat'', ''denoiseModel'');\n');
fprintf('p.denoise.enable = true;\n');
fprintf('p.denoise.model = denoiseModel;\n');
fprintf('results = simulate(p);\n');
