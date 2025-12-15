%% train_ml_impulse_models.m
% Train CNN and GRU impulse detection models for the communication link.
%
% Usage:
%   1. Run this script to train models
%   2. Models will be saved and can be loaded in simulations
%
% Example:
%   >> train_ml_impulse_models
%   >> % Then run simulation with trained models
%   >> p = default_params();
%   >> load('models/impulse_cnn_model.mat', 'model');
%   >> p.mitigation.mlCnn = model;
%   >> results = simulate(p);

clear; clc;
addpath(genpath('src'));

%% Setup
p = default_params();

% Create models directory
modelDir = fullfile(pwd, 'models');
if ~exist(modelDir, 'dir')
    mkdir(modelDir);
end

%% Train CNN Model
fprintf('========================================\n');
fprintf('Training 1D CNN Impulse Detector\n');
fprintf('========================================\n');

cnnOpts = struct();
cnnOpts.nBlocks = 300;      % Number of training blocks
cnnOpts.blockLen = 2048;    % Samples per block
cnnOpts.epochs = 30;        % Training epochs
cnnOpts.lr = 0.01;          % Initial learning rate
cnnOpts.verbose = true;

[cnnModel, cnnReport] = ml_train_cnn_impulse(p, cnnOpts);

% Save CNN model
model = cnnModel;
save(fullfile(modelDir, 'impulse_cnn_model.mat'), 'model', 'cnnReport');
fprintf('CNN model saved to: %s\n\n', fullfile(modelDir, 'impulse_cnn_model.mat'));

%% Train GRU Model
fprintf('========================================\n');
fprintf('Training GRU Impulse Detector\n');
fprintf('========================================\n');

gruOpts = struct();
gruOpts.nBlocks = 200;      % Number of training sequences
gruOpts.blockLen = 512;     % Sequence length (shorter for GRU)
gruOpts.epochs = 20;        % Training epochs
gruOpts.lr = 0.005;         % Initial learning rate
gruOpts.verbose = true;

[gruModel, gruReport] = ml_train_gru_impulse(p, gruOpts);

% Save GRU model
model = gruModel;
save(fullfile(modelDir, 'impulse_gru_model.mat'), 'model', 'gruReport');
fprintf('GRU model saved to: %s\n\n', fullfile(modelDir, 'impulse_gru_model.mat'));

%% Summary
fprintf('========================================\n');
fprintf('Training Summary\n');
fprintf('========================================\n');
fprintf('\nCNN Model:\n');
fprintf('  Detection Rate (Pd): %.1f%%\n', 100 * cnnReport.pdEst);
fprintf('  False Alarm (Pfa):   %.1f%%\n', 100 * cnnReport.pfaEst);
fprintf('  Threshold:           %.3f\n', cnnReport.threshold);

fprintf('\nGRU Model:\n');
fprintf('  Detection Rate (Pd): %.1f%%\n', 100 * gruReport.pdEst);
fprintf('  False Alarm (Pfa):   %.1f%%\n', 100 * gruReport.pfaEst);
fprintf('  Threshold:           %.3f\n', gruReport.threshold);

fprintf('\nModels saved in: %s\n', modelDir);
fprintf('\nTo use trained models in simulation:\n');
fprintf('  p = default_params();\n');
fprintf('  load(''models/impulse_cnn_model.mat'', ''model'');\n');
fprintf('  p.mitigation.mlCnn = model;\n');
fprintf('  results = simulate(p);\n');
