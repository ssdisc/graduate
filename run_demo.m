function run_demo()
%RUN_DEMO Run the main demo pipeline from the repository root.

addpath(genpath(fullfile(fileparts(mfilename('fullpath')), 'src')));

p = default_params("strictModelLoad", false, "requireTrainedMlModels", false);

modelDir = fullfile(pwd, 'models');
if ~exist(modelDir, 'dir')
    mkdir(modelDir);
end

forceRetrain = false;
batchTag = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));

fprintf('========================================\n');
fprintf('Loading or training ML impulse models...\n');
fprintf('========================================\n\n');

lrModelPath = fullfile(modelDir, 'impulse_lr_model.mat');
if ~forceRetrain
    [p.mitigation.ml, loadedLr, loadedLrPath] = load_pretrained_model(lrModelPath, @ml_impulse_lr_model);
else
    loadedLr = false;
    loadedLrPath = "";
end
needTrainLr = forceRetrain || ~loadedLr;
if loadedLr
    fprintf('Loaded LR model: %s\n\n', char(loadedLrPath));
end
if needTrainLr
    fprintf('Training LR model...\n');
    [p.mitigation.ml, lrReport] = ml_train_impulse_lr(p, ...
        'nBlocks', 200, 'blockLen', 4096, 'epochs', 25, 'verbose', true, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_demo");
    fprintf('LR model saved (latest): %s\n', char(lrReport.artifacts.latestPath));
    fprintf('LR model saved (batch): %s\n\n', char(lrReport.artifacts.batchPath));
end

cnnModelPath = fullfile(modelDir, 'impulse_cnn_model.mat');
if ~forceRetrain
    [p.mitigation.mlCnn, loadedCnn, loadedCnnPath] = load_pretrained_model(cnnModelPath, @ml_cnn_impulse_model);
    loadedCnn = loadedCnn && isfield(p.mitigation.mlCnn, 'trained') && logical(p.mitigation.mlCnn.trained);
    if ~loadedCnn
        loadedCnnPath = "";
    end
else
    loadedCnn = false;
    loadedCnnPath = "";
end
needTrainCnn = forceRetrain || ~loadedCnn;
if loadedCnn
    fprintf('Loaded CNN model: %s\n\n', char(loadedCnnPath));
end
if needTrainCnn
    fprintf('Training CNN model...\n');
    [p.mitigation.mlCnn, cnnReport] = ml_train_cnn_impulse(p, ...
        'nBlocks', 150, 'blockLen', 1024, 'epochs', 20, 'verbose', true, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_demo");
    fprintf('CNN model saved (latest): %s\n', char(cnnReport.artifacts.latestPath));
    fprintf('CNN model saved (batch): %s\n\n', char(cnnReport.artifacts.batchPath));
end

gruModelPath = fullfile(modelDir, 'impulse_gru_model.mat');
if ~forceRetrain
    [p.mitigation.mlGru, loadedGru, loadedGruPath] = load_pretrained_model(gruModelPath, @ml_gru_impulse_model);
    loadedGru = loadedGru && isfield(p.mitigation.mlGru, 'trained') && logical(p.mitigation.mlGru.trained);
    if ~loadedGru
        loadedGruPath = "";
    end
else
    loadedGru = false;
    loadedGruPath = "";
end
needTrainGru = forceRetrain || ~loadedGru;
if loadedGru
    fprintf('Loaded GRU model: %s\n\n', char(loadedGruPath));
end
if needTrainGru
    fprintf('Training GRU model...\n');
    [p.mitigation.mlGru, gruReport] = ml_train_gru_impulse(p, ...
        'nBlocks', 100, 'blockLen', 256, 'epochs', 15, 'verbose', true, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_demo");
    fprintf('GRU model saved (latest): %s\n', char(gruReport.artifacts.latestPath));
    fprintf('GRU model saved (batch): %s\n\n', char(gruReport.artifacts.batchPath));
end

p.mitigation.strictModelLoad = true;
p.mitigation.requireTrainedModels = true;

fprintf('========================================\n');
fprintf('Running link simulation...\n');
fprintf('========================================\n\n');

results = simulate(p);
disp(results.summary);

end
