function results = run_demo()
%RUN_DEMO Run the main demo pipeline from the repository root.

addpath(genpath(fullfile(fileparts(mfilename('fullpath')), 'src')));

p = default_params( ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false, ...
    "loadMlModels", strings(1, 0));

modelDir = fullfile(pwd, 'models');
if ~exist(modelDir, 'dir')
    mkdir(modelDir);
end

forceRetrain = false;
batchTag = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
generalizedTrainArgs = local_generalized_training_args();
impulseDlTrainArgs = local_impulse_dl_training_args();
selectorTrainArgs = local_selector_training_args(p);
requiredModels = local_required_ml_models(p.mitigation.methods);

fprintf('========================================\n');
fprintf('Demo config source: src/default_params.m\n');
fprintf('========================================\n');
fprintf('Methods: %s\n', strjoin(cellstr(p.mitigation.methods), ', '));
fprintf('Eb/N0 points: %s dB\n', mat2str(double(p.linkBudget.ebN0dBList)));
fprintf('JSR points: %s dB\n', mat2str(double(p.linkBudget.jsrDbList)));
fprintf('Noise PSD: %.4g\n', double(p.linkBudget.noisePsdLin));
fprintf('Frames per point: %d\n', p.sim.nFramesPerPoint);
fprintf('Parallel: %s\n', local_on_off_text(p.sim.useParallel));
fprintf('Eve: %s, Warden: %s\n\n', ...
    local_on_off_text(p.eve.enable), local_on_off_text(p.covert.enable && p.covert.warden.enable));

fprintf('========================================\n');
fprintf('Loading or training required ML models...\n');
fprintf('========================================\n\n');

if requiredModels.lr
    lrModelPath = fullfile(modelDir, 'impulse_lr_model.mat');
    if ~forceRetrain
        [p.mitigation.ml, loadedLr, loadedLrPath] = load_pretrained_model(lrModelPath, @ml_impulse_lr_model);
        loadedLr = loadedLr && isfield(p.mitigation.ml, 'trained') && logical(p.mitigation.ml.trained);
        if ~loadedLr
            loadedLrPath = "";
        end
    else
        loadedLr = false;
        loadedLrPath = "";
    end
    if loadedLr
        fprintf('Loaded LR model: %s\n\n', char(loadedLrPath));
    else
        fprintf('Training LR model...\n');
        [p.mitigation.ml, lrReport] = ml_train_impulse_lr(p, ...
            generalizedTrainArgs{:}, ...
            'nBlocks', 1000, 'blockLen', 4096, 'epochs', 100, ...
            'saveArtifacts', true, 'saveDir', string(modelDir), ...
            'saveTag', batchTag, 'savedBy', "run_demo");
        fprintf('LR model saved (latest): %s\n', char(lrReport.artifacts.latestPath));
        fprintf('LR model saved (batch): %s\n\n', char(lrReport.artifacts.batchPath));
    end
else
    fprintf('Skipping LR model load: current methods do not use ml_blanking.\n\n');
end

if requiredModels.cnn
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
    if loadedCnn
        fprintf('Loaded CNN model: %s\n\n', char(loadedCnnPath));
    else
        fprintf('Training CNN model...\n');
        [p.mitigation.mlCnn, cnnReport] = ml_train_cnn_impulse(p, ...
            generalizedTrainArgs{:}, ...
            impulseDlTrainArgs{:}, ...
            'saveArtifacts', true, 'saveDir', string(modelDir), ...
            'saveTag', batchTag, 'savedBy', "run_demo");
        fprintf('CNN model saved (latest): %s\n', char(cnnReport.artifacts.latestPath));
        fprintf('CNN model saved (batch): %s\n\n', char(cnnReport.artifacts.batchPath));
    end
else
    fprintf('Skipping CNN model load: current methods do not use ml_cnn/ml_cnn_hard.\n\n');
end

if requiredModels.gru
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
    if loadedGru
        fprintf('Loaded GRU model: %s\n\n', char(loadedGruPath));
    else
        fprintf('Training GRU model...\n');
        [p.mitigation.mlGru, gruReport] = ml_train_gru_impulse(p, ...
            generalizedTrainArgs{:}, ...
            impulseDlTrainArgs{:}, ...
            'saveArtifacts', true, 'saveDir', string(modelDir), ...
            'saveTag', batchTag, 'savedBy', "run_demo");
        fprintf('GRU model saved (latest): %s\n', char(gruReport.artifacts.latestPath));
        fprintf('GRU model saved (batch): %s\n\n', char(gruReport.artifacts.batchPath));
    end
else
    fprintf('Skipping GRU model load: current methods do not use ml_gru/ml_gru_hard.\n\n');
end

if requiredModels.selector
    selectorModelPath = fullfile(modelDir, 'interference_selector_model.mat');
    if ~forceRetrain
        [p.mitigation.selector, loadedSelector, loadedSelectorPath] = load_pretrained_model(selectorModelPath, @ml_interference_selector_model);
        loadedSelector = loadedSelector && isfield(p.mitigation.selector, 'trained') && logical(p.mitigation.selector.trained);
        if ~loadedSelector
            loadedSelectorPath = "";
        end
    else
        loadedSelector = false;
        loadedSelectorPath = "";
    end
    if loadedSelector
        fprintf('Loaded selector model: %s\n\n', char(loadedSelectorPath));
    else
        fprintf('Training selector model...\n');
        [p.mitigation.selector, selectorReport] = ml_train_interference_selector(p, ...
            selectorTrainArgs{:}, ...
            'nBlocks', 900, 'dataSymbolsPerBlock', 512, 'epochs', 60, ...
            'saveArtifacts', true, 'saveDir', string(modelDir), ...
            'saveTag', batchTag, 'savedBy', "run_demo");
        fprintf('Selector model saved (latest): %s\n', char(selectorReport.artifacts.latestPath));
        fprintf('Selector model saved (batch): %s\n\n', char(selectorReport.artifacts.batchPath));
    end
else
    fprintf('Skipping selector model load: current methods do not use adaptive_ml_frontend.\n\n');
end

p.mitigation.strictModelLoad = true;
p.mitigation.requireTrainedModels = true;
if isfield(p, 'eve') && isstruct(p.eve) && isfield(p.eve, 'mitigation')
    p.eve.mitigation = p.mitigation;
end

fprintf('========================================\n');
fprintf('Running link simulation...\n');
fprintf('========================================\n\n');

results = simulate(p);
disp(results.summary);
if nargout == 0
    clear results
end

end

function args = local_generalized_training_args()
args = { ...
    'ebN0dBRange', [-2, 16], ...
    'labelScoreThreshold', 0.1, ...
    'thresholdPolicy', "min_pe_under_pfa", ...
    'minPositiveRate', 0.002, ...
    'maxPositiveRate', 0.30, ...
    'impulseEnableProbability', 0.85, ...
    'impulseProbRange', [0.002, 0.05], ...
    'impulseToBgRatioRange', [10, 80], ...
    'singleToneProbability', 0.35, ...
    'singleTonePowerRange', [0.0025, 0.12], ...
    'singleToneFreqHzRange', [-2500, 2500], ...
    'narrowbandProbability', 0.35, ...
    'narrowbandPowerRange', [0.0025, 0.12], ...
    'narrowbandCenterHzRange', [-2500, 2500], ...
    'narrowbandBandwidthHzRange', [200, 1800], ...
    'sweepProbability', 0.20, ...
    'sweepPowerRange', [0.0025, 0.08], ...
    'sweepStartHzRange', [-3500, -500], ...
    'sweepStopHzRange', [500, 3500], ...
    'sweepPeriodSymbolsRange', [64, 512], ...
    'syncImpairmentProbability', 0.15, ...
    'timingOffsetSymbolsRange', [-0.35, 0.35], ...
    'phaseOffsetRadRange', [-pi, pi], ...
    'multipathProbability', 0.20, ...
    'multipathRayleighProbability', 0.50, ...
    'maxAdditionalImpairments', 2, ...
    'verbose', true};
end

function args = local_impulse_dl_training_args()
args = { ...
    'nBlocks', 1000, ...
    'blockLen', 1024, ...
    'epochs', 100, ...
    'batchSize', 64, ...
    'lr', 1e-3};
end

function required = local_required_ml_models(methods)
methods = lower(string(methods(:).'));
required = struct();
required.lr = any(methods == "ml_blanking");
required.cnn = any(methods == "ml_cnn" | methods == "ml_cnn_hard");
required.gru = any(methods == "ml_gru" | methods == "ml_gru_hard" | methods == "adaptive_ml_frontend");
required.selector = any(methods == "adaptive_ml_frontend");
end

function txt = local_on_off_text(tf)
if tf
    txt = 'ON';
else
    txt = 'OFF';
end
end

function args = local_selector_training_args(p)
dataSymbolsPerBlock = local_selector_training_symbol_count(p);
args = { ...
    'ebN0dBRange', [-4, 16], ...
    'dataSymbolsPerBlock', dataSymbolsPerBlock, ...
    'maxRetriesPerBlock', 10, ...
    'verbose', true};
end

function nSym = local_selector_training_symbol_count(p)
bitsPerSym = local_bits_per_symbol(p.mod);
payloadBits = max(8, round(double(p.packet.payloadBitsPerPacket)));
payloadBits = 8 * floor(payloadBits / 8);
codedBits = fec_coded_bits_length(payloadBits, p.fec);
nSym = ceil(double(codedBits) / double(bitsPerSym));
if isfield(p, "dsss") && isstruct(p.dsss)
    nSym = nSym * dsss_effective_spread_factor(p.dsss);
end
nSym = max(1024, min(nSym, 4096));
if isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "enable") && p.fh.enable ...
        && ~fh_is_fast(p.fh) ...
        && isfield(p.fh, "symbolsPerHop") && double(p.fh.symbolsPerHop) > 0
    hopLen = round(double(p.fh.symbolsPerHop));
    nSym = hopLen * ceil(double(nSym) / double(hopLen));
end
end

function bitsPerSym = local_bits_per_symbol(modCfg)
switch upper(string(modCfg.type))
    case "BPSK"
        bitsPerSym = 1;
    case "QPSK"
        bitsPerSym = 2;
    case "MSK"
        bitsPerSym = 1;
    otherwise
        error("Unsupported modulation for selector training args: %s", char(modCfg.type));
end
end
