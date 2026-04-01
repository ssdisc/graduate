function results = run_demo(mode)
%RUN_DEMO Run the main demo pipeline from the repository root.

arguments
    mode (1,1) string {mustBeMember(mode, ["full" "midterm"])} = "full"
end

addpath(genpath(fullfile(fileparts(mfilename('fullpath')), 'src')));

p = default_params( ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false, ...
    "loadMlModels", strings(1, 0));
p = local_apply_demo_preset(p, mode);

modelDir = fullfile(pwd, 'models');
if ~exist(modelDir, 'dir')
    mkdir(modelDir);
end

forceRetrain = false;
batchTag = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
generalizedTrainArgs = local_generalized_training_args();
requiredModels = local_required_ml_models(p.mitigation.methods);

fprintf('========================================\n');
fprintf('Demo preset: %s\n', upper(char(mode)));
fprintf('========================================\n');
fprintf('Methods: %s\n', strjoin(cellstr(p.mitigation.methods), ', '));
fprintf('Link gain points: %s dB\n', mat2str(double(p.linkBudget.linkGainDbList)));
fprintf('Tx power: %.2f dB, Noise PSD: %.4g\n', ...
    10 * log10(double(p.linkBudget.txPowerLin)), double(p.linkBudget.noisePsdLin));
fprintf('Frames per point: %d\n', p.sim.nFramesPerPoint);
fprintf('Parallel: %s\n', local_on_off_text(p.sim.useParallel));
fprintf('Eve: %s, Warden: %s\n\n', ...
    local_on_off_text(p.eve.enable), local_on_off_text(p.covert.enable && p.covert.warden.enable));

fprintf('========================================\n');
fprintf('Loading or training required ML models...\n');
fprintf('========================================\n\n');

if requiredModels.lr
    lrModelPath = fullfile(modelDir, 'impulse_lr_model.mat');
    if forceRetrain
        fprintf('Training LR model...\n');
        [p.mitigation.ml, lrReport] = ml_train_impulse_lr(p, ...
            generalizedTrainArgs{:}, ...
            'nBlocks', 1000, 'blockLen', 4096, 'epochs', 100, ...
            'saveArtifacts', true, 'saveDir', string(modelDir), ...
            'saveTag', batchTag, 'savedBy', "run_demo");
        fprintf('LR model saved (latest): %s\n', char(lrReport.artifacts.latestPath));
        fprintf('LR model saved (batch): %s\n\n', char(lrReport.artifacts.batchPath));
    else
        [p.mitigation.ml, loadedLr, loadedLrPath] = load_pretrained_model(lrModelPath, @ml_impulse_lr_model);
        if loadedLr
            fprintf('Loaded LR model: %s\n\n', char(loadedLrPath));
        else
            fprintf('Using built-in LR model parameters.\n\n');
        end
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
            'nBlocks', 1000, 'blockLen', 1024, 'epochs', 100, ...
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
            'nBlocks', 1000, 'blockLen', 256, 'epochs', 100, ...
            'saveArtifacts', true, 'saveDir', string(modelDir), ...
            'saveTag', batchTag, 'savedBy', "run_demo");
        fprintf('GRU model saved (latest): %s\n', char(gruReport.artifacts.latestPath));
        fprintf('GRU model saved (batch): %s\n\n', char(gruReport.artifacts.batchPath));
    end
else
    fprintf('Skipping GRU model load: current methods do not use ml_gru/ml_gru_hard.\n\n');
end

p.mitigation.strictModelLoad = true;
p.mitigation.requireTrainedModels = true;

fprintf('========================================\n');
fprintf('Running link simulation...\n');
fprintf('========================================\n\n');

results = simulate(p);
if mode == "midterm"
    local_save_midterm_outputs(p, results);
end
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

function p = local_apply_demo_preset(p, mode)
switch lower(string(mode))
    case "full"
        return;
    case "midterm"
        p.linkBudget.linkGainDbList = 6;
        p.sim.nFramesPerPoint = 1;
        p.sim.saveFigures = false;
        p.sim.useParallel = false;
        p.sim.nWorkers = 0;

        p.eve.enable = false;
        p.covert.enable = false;
        p.covert.warden.enable = false;
        p.covert.warden.useParallel = false;
        p.covert.warden.nWorkers = 0;

        p.mitigation.methods = ["none" "blanking" "ml_blanking"];

        % Slightly stronger impulsive setting so the demo is easier to see live.
        p.channel.impulseProb = 0.02;
        p.channel.impulseToBgRatio = 60;
    otherwise
        error("Unsupported demo preset: %s", mode);
end
end

function required = local_required_ml_models(methods)
methods = lower(string(methods(:).'));
required = struct();
required.lr = any(methods == "ml_blanking");
required.cnn = any(methods == "ml_cnn" | methods == "ml_cnn_hard");
required.gru = any(methods == "ml_gru" | methods == "ml_gru_hard");
end

function txt = local_on_off_text(tf)
if tf
    txt = 'ON';
else
    txt = 'OFF';
end
end

function local_save_midterm_outputs(p, results)
fprintf('[RUN_DEMO] Saving lightweight midterm outputs...\n');

outDir = make_results_dir(p.sim.resultsDir);
save(fullfile(outDir, "results.mat"), "-struct", "results");
export_thesis_tables(outDir, results);

imgTx = load_source_image(p.source);
imagesDir = fullfile(outDir, "images");
if ~exist(imagesDir, 'dir')
    mkdir(imagesDir);
end

figBer = figure("Name", "BER Quick View", "Visible", "off", "Color", "w");
axBer = axes(figBer);
bar(axBer, categorical(cellstr(results.methods)), results.ber(:, end), "FaceColor", [0.16 0.44 0.73]);
grid(axBer, "on");
ylabel(axBer, "BER");
title(axBer, sprintf("BER @ Eb/N0 = %.1f dB", double(results.ebN0dB(end))));
exportgraphics(figBer, fullfile(outDir, "ber_quick.png"), "Resolution", 180);
close(figBer);

examplePoint = results.example(end);
figImg = figure("Name", "Midterm Comparison", "Visible", "off", "Color", "w");
figImg.Position = [120 120 320 * (numel(results.methods) + 1) 320];
tl = tiledlayout(figImg, 1, numel(results.methods) + 1, "TileSpacing", "compact", "Padding", "compact");
title(tl, sprintf("Image Comparison @ Eb/N0 = %.1f dB", double(results.ebN0dB(end))));

nexttile(tl);
imshow(imgTx);
title("TX", "FontSize", 12);

for idx = 1:numel(results.methods)
    methodName = char(results.methods(idx));
    exampleEntry = examplePoint.methods.(methodName);
    imgRx = local_pick_midterm_image(exampleEntry);

    nexttile(tl);
    imshow(imgRx);
    title({ ...
        methodName; ...
        sprintf("BER=%.3g", double(results.ber(idx, end))); ...
        sprintf("PSNR=%.2f dB", double(results.psnrCompensated(idx, end)))}, ...
        "Interpreter", "none", "FontSize", 11);
end

exportgraphics(figImg, fullfile(imagesDir, "comparison.png"), "Resolution", 180);
close(figImg);

fprintf('[RUN_DEMO] Midterm outputs saved to: %s\n\n', outDir);
end

function img = local_pick_midterm_image(exampleEntry)
if isfield(exampleEntry, "imgRxCompensated") && ~isempty(exampleEntry.imgRxCompensated)
    img = exampleEntry.imgRxCompensated;
elseif isfield(exampleEntry, "imgRx") && ~isempty(exampleEntry.imgRx)
    img = exampleEntry.imgRx;
elseif isfield(exampleEntry, "imgRxComm") && ~isempty(exampleEntry.imgRxComm)
    img = exampleEntry.imgRxComm;
else
    error("run_demo:MissingMidtermExampleImage", ...
        "No image available in the example entry for lightweight export.");
end
end
