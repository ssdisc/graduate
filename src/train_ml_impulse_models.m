%% train_ml_impulse_models.m
% 训练通信链路的CNN和GRU脉冲检测模型。
%
% 用法:
%   1. 运行此脚本训练模型
%   2. 模型将被保存，可在仿真中加载
%
% 示例:
%   >> train_ml_impulse_models
%   >> % 然后用训练好的模型运行仿真
%   >> p = default_params();
%   >> load('models/impulse_cnn_model.mat', 'model');
%   >> p.mitigation.mlCnn = model;
%   >> results = simulate(p);

clear; clc;
addpath(genpath('src'));

%% 设置
p = default_params();

% 创建模型目录
modelDir = fullfile(pwd, 'models');
if ~exist(modelDir, 'dir')
    mkdir(modelDir);
end

%% 训练CNN模型
fprintf('========================================\n');
fprintf('训练1D CNN脉冲检测器\n');
fprintf('========================================\n');

cnnOpts = struct();
cnnOpts.nBlocks = 300;      % 训练块数量
cnnOpts.blockLen = 2048;    % 每块样本数
cnnOpts.epochs = 30;        % 训练轮数
cnnOpts.lr = 0.01;          % 初始学习率
cnnOpts.verbose = true;

[cnnModel, cnnReport] = ml_train_cnn_impulse(p, cnnOpts);

% 保存CNN模型
model = cnnModel;
save(fullfile(modelDir, 'impulse_cnn_model.mat'), 'model', 'cnnReport');
fprintf('CNN模型已保存到: %s\n\n', fullfile(modelDir, 'impulse_cnn_model.mat'));

%% 训练GRU模型
fprintf('========================================\n');
fprintf('训练GRU脉冲检测器\n');
fprintf('========================================\n');

gruOpts = struct();
gruOpts.nBlocks = 200;      % 训练序列数量
gruOpts.blockLen = 512;     % 序列长度（GRU用较短）
gruOpts.epochs = 20;        % 训练轮数
gruOpts.lr = 0.005;         % 初始学习率
gruOpts.verbose = true;

[gruModel, gruReport] = ml_train_gru_impulse(p, gruOpts);

% 保存GRU模型
model = gruModel;
save(fullfile(modelDir, 'impulse_gru_model.mat'), 'model', 'gruReport');
fprintf('GRU模型已保存到: %s\n\n', fullfile(modelDir, 'impulse_gru_model.mat'));

%% 摘要
fprintf('========================================\n');
fprintf('训练摘要\n');
fprintf('========================================\n');
fprintf('\nCNN模型:\n');
fprintf('  检测率 (Pd): %.1f%%\n', 100 * cnnReport.pdEst);
fprintf('  虚警率 (Pfa):   %.1f%%\n', 100 * cnnReport.pfaEst);
fprintf('  阈值:           %.3f\n', cnnReport.threshold);

fprintf('\nGRU模型:\n');
fprintf('  检测率 (Pd): %.1f%%\n', 100 * gruReport.pdEst);
fprintf('  虚警率 (Pfa):   %.1f%%\n', 100 * gruReport.pfaEst);
fprintf('  阈值:           %.3f\n', gruReport.threshold);

fprintf('\n模型保存在: %s\n', modelDir);
fprintf('\n在仿真中使用训练好的模型:\n');
fprintf('  p = default_params();\n');
fprintf('  load(''models/impulse_cnn_model.mat'', ''model'');\n');
fprintf('  p.mitigation.mlCnn = model;\n');
fprintf('  results = simulate(p);\n');
