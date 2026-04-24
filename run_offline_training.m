function run_offline_training()
%RUN_OFFLINE_TRAINING Train and save offline ML models without running the main simulation.

addpath(genpath(fullfile(fileparts(mfilename('fullpath')), 'src')));

p = default_params( ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false, ...
    "loadMlModels", strings(1, 0));
[activeMethods, activeInterferenceTypes, allowedMethods] = resolve_mitigation_methods(p.mitigation, p.channel);
p.mitigation.methods = activeMethods;

modelDir = fullfile(pwd, 'models');
if ~exist(modelDir, 'dir')
    mkdir(modelDir);
end

batchTag = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
requiredModels = local_required_ml_models(activeMethods, p);
impulseProfile = local_impulse_profile_if_needed(requiredModels, p);
impulseCommonArgs = local_impulse_common_training_args_if_needed(requiredModels, p);
impulseLrArgs = local_impulse_lr_training_args_if_needed(requiredModels, p);
impulseDlArgs = local_impulse_dl_training_args_if_needed(requiredModels, p);
selectorTrainArgs = local_selector_training_args(p);
narrowbandTrainArgs = local_narrowband_training_args();
fhErasureTrainArgs = local_fh_erasure_training_args(p);
multipathEqTrainArgs = local_multipath_eq_training_args();

fprintf('========================================\n');
fprintf('Offline training config source: src/default_params.m\n');
fprintf('========================================\n');
fprintf('Active interference types: %s\n', local_list_text(activeInterferenceTypes));
fprintf('Allowed methods after binding: %s\n', local_list_text(allowedMethods));
fprintf('Methods: %s\n', strjoin(cellstr(p.mitigation.methods), ', '));
if ~isempty(impulseProfile)
    fprintf('Impulse offline profile: %s (%s)\n', char(impulseProfile.profileName), char(impulseProfile.profileKey));
    fprintf('Impulse scenario Eb/N0 range: %s dB\n', mat2str(double(impulseProfile.scenario.ebN0dBRange)));
    fprintf('Impulse probability range: %s\n', mat2str(double(impulseProfile.scenario.impulseProbRange)));
    fprintf('Impulse/bg ratio range: %s\n', mat2str(double(impulseProfile.scenario.impulseToBgRatioRange)));
end
fprintf('\n');

fprintf('========================================\n');
fprintf('Training and saving offline ML models...\n');
fprintf('========================================\n\n');

if requiredModels.lr
    fprintf('Training LR model...\n');
    [~, lrReport] = ml_train_impulse_lr(p, ...
        impulseCommonArgs{:}, ...
        impulseLrArgs{:}, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_offline_training");
    fprintf('LR model saved (latest): %s\n', char(lrReport.artifacts.latestPath));
    fprintf('LR model saved (batch): %s\n\n', char(lrReport.artifacts.batchPath));
else
    fprintf('Skipping LR model training: current methods do not use ml_blanking.\n\n');
end

if requiredModels.cnn
    fprintf('Training CNN model...\n');
    [~, cnnReport] = ml_train_cnn_impulse(p, ...
        impulseCommonArgs{:}, ...
        impulseDlArgs{:}, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_offline_training");
    fprintf('CNN model saved (latest): %s\n', char(cnnReport.artifacts.latestPath));
    fprintf('CNN model saved (batch): %s\n\n', char(cnnReport.artifacts.batchPath));
else
    fprintf('Skipping CNN model training: current methods do not use ml_cnn/ml_cnn_hard.\n\n');
end

if requiredModels.gru
    fprintf('Training GRU model...\n');
    [~, gruReport] = ml_train_gru_impulse(p, ...
        impulseCommonArgs{:}, ...
        impulseDlArgs{:}, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_offline_training");
    fprintf('GRU model saved (latest): %s\n', char(gruReport.artifacts.latestPath));
    fprintf('GRU model saved (batch): %s\n\n', char(gruReport.artifacts.batchPath));
else
    fprintf('Skipping GRU model training: current methods do not use ml_gru/ml_gru_hard.\n\n');
end

if requiredModels.selector
    fprintf('Training selector model...\n');
    [~, selectorReport] = ml_train_interference_selector(p, ...
        selectorTrainArgs{:}, ...
        'nBlocks', 900, 'dataSymbolsPerBlock', 512, 'epochs', 60, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_offline_training");
    fprintf('Selector model saved (latest): %s\n', char(selectorReport.artifacts.latestPath));
    fprintf('Selector model saved (batch): %s\n\n', char(selectorReport.artifacts.batchPath));
else
    fprintf('Skipping selector model training: current methods do not use adaptive_ml_frontend.\n\n');
end

if requiredModels.narrowband
    fprintf('Training narrowband action model...\n');
    [~, narrowbandReport] = ml_train_narrowband_action(p, ...
        narrowbandTrainArgs{:}, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_offline_training");
    fprintf('Narrowband action model saved (latest): %s\n', char(narrowbandReport.artifacts.latestPath));
    fprintf('Narrowband action model saved (batch): %s\n\n', char(narrowbandReport.artifacts.batchPath));
else
    fprintf('Skipping narrowband action model training: effective methods do not use ml_narrowband.\n\n');
end

if requiredModels.fhErasure
    fprintf('Training FH erasure model...\n');
    [~, fhErasureReport] = ml_train_fh_erasure(p, ...
        fhErasureTrainArgs{:}, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_offline_training");
    fprintf('FH erasure model saved (latest): %s\n', char(fhErasureReport.artifacts.latestPath));
    fprintf('FH erasure model saved (batch): %s\n\n', char(fhErasureReport.artifacts.batchPath));
else
    fprintf('Skipping FH erasure model training: current methods do not require ml_fh_erasure.\n\n');
end

if requiredModels.multipathEq
    fprintf('Training multipath equalizer model...\n');
    [~, multipathEqReport] = ml_train_multipath_equalizer(p, ...
        multipathEqTrainArgs{:}, ...
        'saveArtifacts', true, 'saveDir', string(modelDir), ...
        'saveTag', batchTag, 'savedBy', "run_offline_training");
    fprintf('Multipath equalizer model saved (latest): %s\n', char(multipathEqReport.artifacts.latestPath));
    fprintf('Multipath equalizer model saved (batch): %s\n\n', char(multipathEqReport.artifacts.batchPath));
else
    fprintf('Skipping multipath equalizer model training: compareMethods does not use ml_mlp.\n\n');
end
end

function args = local_impulse_common_training_args(p)
profile = ml_require_impulse_offline_training_profile(p);
scenario = profile.scenario;
args = { ...
    'ebN0dBRange', scenario.ebN0dBRange, ...
    'labelScoreThreshold', scenario.labelScoreThreshold, ...
    'thresholdPolicy', scenario.thresholdPolicy, ...
    'thresholdMaxCandidates', scenario.thresholdMaxCandidates, ...
    'thresholdEvalFramesPerPoint', scenario.thresholdEvalFramesPerPoint, ...
    'thresholdEvalEbN0dBList', scenario.thresholdEvalEbN0dBList, ...
    'thresholdEvalJsrDbList', scenario.thresholdEvalJsrDbList, ...
    'minPositiveRate', scenario.minPositiveRate, ...
    'maxPositiveRate', scenario.maxPositiveRate, ...
    'impulseEnableProbability', scenario.impulseEnableProbability, ...
    'impulseProbRange', scenario.impulseProbRange, ...
    'impulseToBgRatioRange', scenario.impulseToBgRatioRange, ...
    'singleToneProbability', scenario.singleToneProbability, ...
    'singleTonePowerRange', scenario.singleTonePowerRange, ...
    'singleToneFreqHzRange', scenario.singleToneFreqHzRange, ...
    'narrowbandProbability', scenario.narrowbandProbability, ...
    'narrowbandPowerRange', scenario.narrowbandPowerRange, ...
    'narrowbandCenterFreqPointsRange', scenario.narrowbandCenterFreqPointsRange, ...
    'narrowbandBandwidthFreqPointsRange', scenario.narrowbandBandwidthFreqPointsRange, ...
    'sweepProbability', scenario.sweepProbability, ...
    'sweepPowerRange', scenario.sweepPowerRange, ...
    'sweepStartHzRange', scenario.sweepStartHzRange, ...
    'sweepStopHzRange', scenario.sweepStopHzRange, ...
    'sweepPeriodSymbolsRange', scenario.sweepPeriodSymbolsRange, ...
    'syncImpairmentProbability', scenario.syncImpairmentProbability, ...
    'timingOffsetSymbolsRange', scenario.timingOffsetSymbolsRange, ...
    'phaseOffsetRadRange', scenario.phaseOffsetRadRange, ...
    'multipathProbability', scenario.multipathProbability, ...
    'multipathRayleighProbability', scenario.multipathRayleighProbability, ...
    'maxAdditionalImpairments', scenario.maxAdditionalImpairments, ...
    'verbose', true};
end

function args = local_impulse_common_training_args_if_needed(requiredModels, p)
if requiredModels.lr || requiredModels.cnn || requiredModels.gru
    args = local_impulse_common_training_args(p);
else
    args = {};
end
end

function args = local_impulse_lr_training_args(p)
profile = ml_require_impulse_offline_training_profile(p);
cfg = profile.logisticRegression;
args = { ...
    'nBlocks', cfg.nBlocks, ...
    'blockLen', cfg.blockLen, ...
    'epochs', cfg.epochs, ...
    'batchSize', cfg.batchSize, ...
    'lr', cfg.lr, ...
    'l2', cfg.l2};
end

function args = local_impulse_lr_training_args_if_needed(requiredModels, p)
if requiredModels.lr
    args = local_impulse_lr_training_args(p);
else
    args = {};
end
end

function args = local_impulse_dl_training_args(p)
profile = ml_require_impulse_offline_training_profile(p);
cfg = profile.deepLearning;
args = { ...
    'nBlocks', cfg.nBlocks, ...
    'blockLen', cfg.blockLen, ...
    'epochs', cfg.epochs, ...
    'batchSize', cfg.batchSize, ...
    'lr', cfg.lr};
end

function args = local_impulse_dl_training_args_if_needed(requiredModels, p)
if requiredModels.cnn || requiredModels.gru
    args = local_impulse_dl_training_args(p);
else
    args = {};
end
end

function required = local_required_ml_models(methods, p)
methods = lower(string(methods(:).'));
required = struct();
required.lr = any(methods == "ml_blanking");
required.cnn = any(methods == "ml_cnn" | methods == "ml_cnn_hard");
required.gru = any(methods == "ml_gru" | methods == "ml_gru_hard" | methods == "adaptive_ml_frontend");
required.selector = any(methods == "adaptive_ml_frontend");
required.narrowband = any(methods == "ml_narrowband" | methods == "adaptive_ml_frontend");
required.fhErasure = any(methods == "ml_fh_erasure");
required.multipathEq = local_multipath_eq_offline_requested(p);
end

function tf = local_multipath_eq_offline_requested(p)
tf = false;
if ~(isfield(p, "rxSync") && isstruct(p.rxSync) ...
        && isfield(p.rxSync, "multipathEq") && isstruct(p.rxSync.multipathEq))
    return;
end
eqCfg = p.rxSync.multipathEq;
if isfield(eqCfg, "method") && lower(string(eqCfg.method)) == "ml_mlp"
    tf = true;
    return;
end
if isfield(eqCfg, "compareMethods") && ~isempty(eqCfg.compareMethods)
    tf = any(lower(string(eqCfg.compareMethods(:).')) == "ml_mlp");
end
end

function txt = local_list_text(values)
values = string(values(:).');
if isempty(values)
    txt = 'none';
else
    txt = strjoin(cellstr(values), ', ');
end
end

function profile = local_impulse_profile_if_needed(requiredModels, p)
if requiredModels.lr || requiredModels.cnn || requiredModels.gru
    profile = ml_require_impulse_offline_training_profile(p);
else
    profile = [];
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

function args = local_narrowband_training_args()
args = { ...
    'ebN0dBRange', [-4, 16], ...
    'blockLenRange', [96 1024], ...
    'bpskProbability', 0.35, ...
    'verbose', true};
end

function args = local_fh_erasure_training_args(p)
if ~(isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "nFreqs") && double(p.fh.nFreqs) >= 2)
    error("FH erasure training requires at least two FH frequencies.");
end
args = { ...
    'nBlocks', 900, ...
    'ebN0dBRange', [-4, 16], ...
    'hopsPerBlockRange', [64 256], ...
    'jsrDbRange', [-12, 3], ...
    'bandwidthFreqPointsRange', [0.6, 1.4], ...
    'configuredCenterProbability', 0.35, ...
    'narrowbandProbability', 0.90, ...
    'epochs', 45, ...
    'batchSize', 256, ...
    'lr', 1e-3, ...
    'verbose', true};
end

function args = local_multipath_eq_training_args()
args = { ...
    'nChannels', 2500, ...
    'samplesPerChannel', 32, ...
    'blockLen', 192, ...
    'ebN0dBRange', [6, 14], ...
    'rayleighProbability', 0.85, ...
    'bpskProbability', 0.35, ...
    'epochs', 45, ...
    'batchSize', 512, ...
    'lr', 1e-3, ...
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
