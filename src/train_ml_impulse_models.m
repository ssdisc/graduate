%% train_ml_impulse_models.m
% 训练通信链路的LR/CNN/GRU脉冲检测模型。
%
% 用法:
%   1. 运行此脚本训练模型
%   2. 模型将被保存，可在仿真中加载
%
% 示例:
%   >> train_ml_impulse_models
%   >> % 然后用训练好的模型运行仿真
%   >> p = default_params();
%   >> load('models/impulse_lr_model.mat', 'model');
%   >> p.mitigation.ml = model;
%   >> load('models/impulse_cnn_model.mat', 'model');
%   >> p.mitigation.mlCnn = model;
%   >> load('models/impulse_gru_model.mat', 'model');
%   >> p.mitigation.mlGru = model;
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
batchTag = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));

%% 训练LR模型
fprintf('========================================\n');
fprintf('训练逻辑回归脉冲检测器\n');
fprintf('========================================\n');

lrOpts = struct();
lrOpts.nBlocks = 200;       % 训练块数量
lrOpts.blockLen = 4096;     % 每块样本数
lrOpts.epochs = 25;         % 训练轮数
lrOpts.lr = 0.2;            % 学习率
lrOpts.verbose = true;

[lrModel, lrReport] = ml_train_impulse_lr(p, lrOpts);

% 保存LR模型
model = lrModel;
report = lrReport;
meta = struct('batchTag', batchTag, 'savedBy', 'train_ml_impulse_models', 'savedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
lrLatestPath = fullfile(modelDir, 'impulse_lr_model.mat');
lrBatchPath = fullfile(modelDir, sprintf('impulse_lr_model_%s.mat', batchTag));
save(lrLatestPath, 'model', 'report', 'meta');
save(lrBatchPath, 'model', 'report', 'meta');
fprintf('LR模型已保存(最新): %s\n', lrLatestPath);
fprintf('LR模型已保存(批次): %s\n\n', lrBatchPath);

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
report = cnnReport;
meta = struct('batchTag', batchTag, 'savedBy', 'train_ml_impulse_models', 'savedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
cnnLatestPath = fullfile(modelDir, 'impulse_cnn_model.mat');
cnnBatchPath = fullfile(modelDir, sprintf('impulse_cnn_model_%s.mat', batchTag));
save(cnnLatestPath, 'model', 'report', 'meta');
save(cnnBatchPath, 'model', 'report', 'meta');
fprintf('CNN模型已保存(最新): %s\n', cnnLatestPath);
fprintf('CNN模型已保存(批次): %s\n\n', cnnBatchPath);

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
report = gruReport;
meta = struct('batchTag', batchTag, 'savedBy', 'train_ml_impulse_models', 'savedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
gruLatestPath = fullfile(modelDir, 'impulse_gru_model.mat');
gruBatchPath = fullfile(modelDir, sprintf('impulse_gru_model_%s.mat', batchTag));
save(gruLatestPath, 'model', 'report', 'meta');
save(gruBatchPath, 'model', 'report', 'meta');
fprintf('GRU模型已保存(最新): %s\n', gruLatestPath);
fprintf('GRU模型已保存(批次): %s\n\n', gruBatchPath);

%% 摘要
fprintf('========================================\n');
fprintf('训练摘要\n');
fprintf('========================================\n');
fprintf('批次标签: %s\n', batchTag);
fprintf('\nLR模型:\n');
fprintf('  检测率 (Pd): %.1f%%\n', 100 * lrReport.pdEst);
fprintf('  虚警率 (Pfa):   %.1f%%\n', 100 * lrReport.pfaEst);
fprintf('  阈值:           %.3f\n', lrReport.threshold);

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
fprintf('  load(''models/impulse_lr_model.mat'', ''model'');\n');
fprintf('  p.mitigation.ml = model;\n');
fprintf('  load(''models/impulse_cnn_model.mat'', ''model'');\n');
fprintf('  p.mitigation.mlCnn = model;\n');
fprintf('  load(''models/impulse_gru_model.mat'', ''model'');\n');
fprintf('  p.mitigation.mlGru = model;\n');
fprintf('  results = simulate(p);\n');
