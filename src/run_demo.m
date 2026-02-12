function run_demo()
%RUN_DEMO  赛道一（初赛）基准MATLAB仿真。
%
% 用法（从仓库根目录）：
%   addpath(genpath('src'));
%   run_demo

addpath(genpath(fullfile(fileparts(mfilename('fullpath')), 'link')));

p = default_params();

% 快速演示设置（按需修改）
p.sim.ebN0dBList = 0:2:10;
p.sim.nFramesPerPoint = 1;
p.sim.saveFigures = true;

%% ML模型：训练一次，后续复用（LR/CNN/GRU）
modelDir = fullfile(pwd, 'models');
if ~exist(modelDir, 'dir')
    mkdir(modelDir);
end

% 若需强制重训三种模型，改为true
forceRetrain = false;
batchTag = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));

fprintf('========================================\n');
fprintf('加载或训练ML脉冲检测模型...\n');
fprintf('========================================\n\n');

% 1) 逻辑回归模型（ml_blanking）
lrModelPath = fullfile(modelDir, 'impulse_lr_model.mat');
needTrainLr = forceRetrain || ~exist(lrModelPath, 'file');
if ~needTrainLr
    s = load(lrModelPath, 'model');
    if isfield(s, 'model') && ~isempty(s.model)
        p.mitigation.ml = s.model;
        fprintf('已加载LR模型: %s\n\n', lrModelPath);
    else
        needTrainLr = true;
    end
end
if needTrainLr
    fprintf('训练LR模型...\n');
    [p.mitigation.ml, lrReport] = ml_train_impulse_lr(p, ...
        'nBlocks', 200, 'blockLen', 4096, 'epochs', 25, 'verbose', true);
    model = p.mitigation.ml;
    report = lrReport;
    meta = struct('batchTag', batchTag, 'savedBy', 'run_demo', 'savedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    save(lrModelPath, 'model', 'report', 'meta');
    lrBatchPath = fullfile(modelDir, sprintf('impulse_lr_model_%s.mat', batchTag));
    save(lrBatchPath, 'model', 'report', 'meta');
    fprintf('LR模型已保存(最新): %s\n', lrModelPath);
    fprintf('LR模型已保存(批次): %s\n\n', lrBatchPath);
end

% 2) CNN模型（ml_cnn）
cnnModelPath = fullfile(modelDir, 'impulse_cnn_model.mat');
needTrainCnn = forceRetrain || ~exist(cnnModelPath, 'file');
if ~needTrainCnn
    s = load(cnnModelPath, 'model');
    if isfield(s, 'model') && ~isempty(s.model)
        p.mitigation.mlCnn = s.model;
        fprintf('已加载CNN模型: %s\n\n', cnnModelPath);
    else
        needTrainCnn = true;
    end
end
if needTrainCnn
    fprintf('训练CNN模型...\n');
    [p.mitigation.mlCnn, cnnReport] = ml_train_cnn_impulse(p, ...
        'nBlocks', 150, 'blockLen', 1024, 'epochs', 20, 'verbose', true);
    model = p.mitigation.mlCnn;
    report = cnnReport;
    meta = struct('batchTag', batchTag, 'savedBy', 'run_demo', 'savedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    save(cnnModelPath, 'model', 'report', 'meta');
    cnnBatchPath = fullfile(modelDir, sprintf('impulse_cnn_model_%s.mat', batchTag));
    save(cnnBatchPath, 'model', 'report', 'meta');
    fprintf('CNN模型已保存(最新): %s\n', cnnModelPath);
    fprintf('CNN模型已保存(批次): %s\n\n', cnnBatchPath);
end

% 3) GRU模型（ml_gru）
gruModelPath = fullfile(modelDir, 'impulse_gru_model.mat');
needTrainGru = forceRetrain || ~exist(gruModelPath, 'file');
if ~needTrainGru
    s = load(gruModelPath, 'model');
    if isfield(s, 'model') && ~isempty(s.model)
        p.mitigation.mlGru = s.model;
        fprintf('已加载GRU模型: %s\n\n', gruModelPath);
    else
        needTrainGru = true;
    end
end
if needTrainGru
    fprintf('训练GRU模型...\n');
    [p.mitigation.mlGru, gruReport] = ml_train_gru_impulse(p, ...
        'nBlocks', 100, 'blockLen', 256, 'epochs', 15, 'verbose', true);
    model = p.mitigation.mlGru;
    report = gruReport;
    meta = struct('batchTag', batchTag, 'savedBy', 'run_demo', 'savedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    save(gruModelPath, 'model', 'report', 'meta');
    gruBatchPath = fullfile(modelDir, sprintf('impulse_gru_model_%s.mat', batchTag));
    save(gruBatchPath, 'model', 'report', 'meta');
    fprintf('GRU模型已保存(最新): %s\n', gruModelPath);
    fprintf('GRU模型已保存(批次): %s\n\n', gruBatchPath);
end

%% 运行仿真
fprintf('========================================\n');
fprintf('运行链路仿真...\n');
fprintf('========================================\n\n');

results = simulate(p);

disp(results.summary);

end
