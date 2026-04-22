function results = run_demo()
%RUN_DEMO Run the main simulation pipeline from the repository root.

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

requiredModels = local_required_ml_models(activeMethods, p);
expectedReloadContext = ml_capture_reload_context(p);
expectedSelectorReloadContext = ml_capture_selector_reload_context(p);
expectedNarrowbandContext = ml_capture_narrowband_reload_context(p);
expectedFhErasureContext = ml_capture_fh_erasure_reload_context(p);
expectedMultipathEqContext = ml_capture_multipath_equalizer_reload_context(p);
impulseProfileName = local_impulse_profile_name(requiredModels, p);

fprintf('========================================\n');
fprintf('Demo config source: src/default_params.m\n');
fprintf('========================================\n');
fprintf('Active interference types: %s\n', local_list_text(activeInterferenceTypes));
fprintf('Allowed methods after binding: %s\n', local_list_text(allowedMethods));
fprintf('Methods: %s\n', strjoin(cellstr(p.mitigation.methods), ', '));
fprintf('Equalizers: %s\n', strjoin(cellstr(string(p.rxSync.multipathEq.compareMethods(:).')), ', '));
fprintf('Eb/N0 points: %s dB\n', mat2str(double(p.linkBudget.ebN0dBList)));
fprintf('JSR points: %s dB\n', mat2str(double(p.linkBudget.jsrDbList)));
fprintf('Noise PSD: %.4g\n', double(p.linkBudget.noisePsdLin));
fprintf('Frames per point: %d\n', p.sim.nFramesPerPoint);
fprintf('Parallel: %s\n', local_on_off_text(p.sim.useParallel));
fprintf('Bob RX diversity: %s, nRx=%d, combine=%s\n', ...
    local_on_off_text(p.rxDiversity.enable), double(p.rxDiversity.nRx), char(p.rxDiversity.combineMethod));
fprintf('Eve: %s, Warden: %s\n', ...
    local_on_off_text(p.eve.enable), local_on_off_text(p.covert.enable && p.covert.warden.enable));
if strlength(impulseProfileName) > 0
    fprintf('Impulse offline profile: %s\n', char(impulseProfileName));
end
fprintf('\n');

fprintf('========================================\n');
fprintf('Loading required ML models...\n');
fprintf('========================================\n\n');

if requiredModels.lr
    [p.mitigation.ml, ~, loadedLrPath] = load_pretrained_model( ...
        fullfile(modelDir, 'impulse_lr_model.mat'), @ml_impulse_lr_model, ...
        "strict", true, ...
        "requireTrained", true, ...
        "expectedContext", expectedReloadContext);
    fprintf('Loaded LR model: %s\n\n', char(loadedLrPath));
else
    fprintf('Skipping LR model load: current methods do not use ml_blanking.\n\n');
end

if requiredModels.cnn
    [p.mitigation.mlCnn, ~, loadedCnnPath] = load_pretrained_model( ...
        fullfile(modelDir, 'impulse_cnn_model.mat'), @ml_cnn_impulse_model, ...
        "strict", true, ...
        "requireTrained", true, ...
        "expectedContext", expectedReloadContext);
    fprintf('Loaded CNN model: %s\n\n', char(loadedCnnPath));
else
    fprintf('Skipping CNN model load: current methods do not use ml_cnn/ml_cnn_hard.\n\n');
end

if requiredModels.gru
    [p.mitigation.mlGru, ~, loadedGruPath] = load_pretrained_model( ...
        fullfile(modelDir, 'impulse_gru_model.mat'), @ml_gru_impulse_model, ...
        "strict", true, ...
        "requireTrained", true, ...
        "expectedContext", expectedReloadContext);
    fprintf('Loaded GRU model: %s\n\n', char(loadedGruPath));
else
    fprintf('Skipping GRU model load: current methods do not use ml_gru/ml_gru_hard.\n\n');
end

if requiredModels.selector
    [p.mitigation.selector, ~, loadedSelectorPath] = load_pretrained_model( ...
        fullfile(modelDir, 'interference_selector_model.mat'), @ml_interference_selector_model, ...
        "strict", true, ...
        "requireTrained", true, ...
        "expectedContext", expectedSelectorReloadContext);
    fprintf('Loaded selector model: %s\n\n', char(loadedSelectorPath));
else
    fprintf('Skipping selector model load: current methods do not use adaptive_ml_frontend.\n\n');
end

if requiredModels.narrowband
    [p.mitigation.mlNarrowband, ~, loadedNarrowbandPath] = load_pretrained_model( ...
        fullfile(modelDir, 'narrowband_action_model.mat'), @ml_narrowband_action_model, ...
        "strict", true, ...
        "requireTrained", true, ...
        "expectedContext", expectedNarrowbandContext);
    fprintf('Loaded narrowband action model: %s\n\n', char(loadedNarrowbandPath));
else
    fprintf('Skipping narrowband action model load: effective methods do not use ml_narrowband.\n\n');
end

if requiredModels.fhErasure
    [p.mitigation.mlFhErasure, ~, loadedFhErasurePath] = load_pretrained_model( ...
        fullfile(modelDir, 'fh_erasure_model.mat'), @ml_fh_erasure_model, ...
        "strict", true, ...
        "requireTrained", true, ...
        "expectedContext", expectedFhErasureContext);
    fprintf('Loaded FH erasure model: %s\n\n', char(loadedFhErasurePath));
else
    fprintf('Skipping FH erasure model load: effective methods do not use ml_fh_erasure.\n\n');
end

if requiredModels.multipathEq
    [p.rxSync.multipathEq.mlMlp, ~, loadedMultipathEqPath] = load_pretrained_model( ...
        fullfile(modelDir, 'multipath_equalizer_model.mat'), @ml_multipath_equalizer_model, ...
        "strict", true, ...
        "requireTrained", true, ...
        "expectedContext", expectedMultipathEqContext);
    fprintf('Loaded multipath equalizer model: %s\n\n', char(loadedMultipathEqPath));
else
    fprintf('Skipping multipath equalizer model load: compareMethods does not use ml_mlp.\n\n');
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
local_print_adaptive_action_distribution(results);
if nargout == 0
    clear results
end

end

function local_print_adaptive_action_distribution(results)
if ~(isstruct(results) && isfield(results, "packetDiagnostics") ...
        && isstruct(results.packetDiagnostics) && isfield(results.packetDiagnostics, "bob") ...
        && isstruct(results.packetDiagnostics.bob) && isfield(results.packetDiagnostics.bob, "adaptiveFrontEnd"))
    return;
end
af = results.packetDiagnostics.bob.adaptiveFrontEnd;
if ~(isfield(af, "actionNames") && isfield(af, "actionCounts") && isfield(af, "classNames") ...
        && isfield(af, "classCounts"))
    return;
end
methods = string(results.methods(:).');
idx = find(startsWith(lower(methods), "adaptive_ml_frontend"), 1, "first");
if isempty(idx)
    return;
end

actionCounts = double(squeeze(sum(af.actionCounts(:, idx, :), 3)));
classCounts = double(squeeze(sum(af.classCounts(:, idx, :), 3)));
totalDecisions = sum(actionCounts);
if totalDecisions <= 0
    fprintf('\nadaptive_ml_frontend: no decisions recorded.\n');
    return;
end

fprintf('\n========================================\n');
fprintf('adaptive_ml_frontend decision distribution (method "%s")\n', char(methods(idx)));
fprintf('Total decisions across Eb/N0 points: %d\n', totalDecisions);
fprintf('========================================\n');

actionNames = string(af.actionNames(:));
[counts, order] = sort(actionCounts, "descend");
actionNamesSorted = actionNames(order);
nonzero = counts > 0;
fprintf('Actions (non-zero, sorted by count):\n');
for k = 1:numel(counts)
    if ~nonzero(k)
        continue;
    end
    fprintf('  %5d (%.1f%%)  %s\n', counts(k), 100 * counts(k) / totalDecisions, char(actionNamesSorted(k)));
end

classNames = string(af.classNames(:));
[clsCounts, clsOrder] = sort(classCounts, "descend");
fprintf('Argmax class distribution:\n');
for k = 1:numel(clsCounts)
    if clsCounts(k) == 0
        continue;
    end
    fprintf('  %5d (%.1f%%)  %s\n', clsCounts(k), 100 * clsCounts(k) / totalDecisions, char(classNames(clsOrder(k))));
end

if isfield(af, "meanConfidence") && ~isempty(af.meanConfidence) ...
        && size(af.meanConfidence, 1) >= idx
    confPerEbN0 = double(af.meanConfidence(idx, :));
    fprintf('Mean confidence by Eb/N0: %s\n', mat2str(confPerEbN0, 4));
end
fprintf('========================================\n');
end

function required = local_required_ml_models(methods, p)
methods = lower(string(methods(:).'));
required = struct();
required.lr = any(methods == "ml_blanking");
required.cnn = any(methods == "ml_cnn" | methods == "ml_cnn_hard");
required.gru = any(methods == "ml_gru" | methods == "ml_gru_hard" | methods == "adaptive_ml_frontend");
required.selector = any(methods == "adaptive_ml_frontend");
required.narrowband = any(methods == "ml_narrowband");
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

function txt = local_on_off_text(tf)
if tf
    txt = 'ON';
else
    txt = 'OFF';
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

function profileName = local_impulse_profile_name(requiredModels, p)
if ~(requiredModels.lr || requiredModels.cnn || requiredModels.gru)
    profileName = "";
    return;
end
profile = ml_require_impulse_offline_training_profile(p);
profileName = profile.profileName;
end
