function report = run_profile_ml_gpu_training_eval(opts)
%RUN_PROFILE_ML_GPU_TRAINING_EVAL Train profile-adapted ML models and run one evaluation pass.

arguments
    opts.Tag (1,1) string = string(datetime("now", "Format", "yyyyMMdd_HHmmss"))
    opts.ModelDir (1,1) string = fullfile(pwd, "models")
    opts.ResultsRoot (1,1) string = fullfile(pwd, "results", "profile_ml_gpu_training_eval")
    opts.UseGpu (1,1) logical = true
    opts.NFrames (1,1) double {mustBeInteger, mustBePositive} = 1

    opts.ImpulseBlocks (1,1) double {mustBeInteger, mustBePositive} = 240
    opts.ImpulseBlockLen (1,1) double {mustBeInteger, mustBePositive} = 2048
    opts.ImpulseEpochs (1,1) double {mustBeInteger, mustBePositive} = 12
    opts.ImpulseBatchSize (1,1) double {mustBeInteger, mustBePositive} = 32

    opts.FhErasureBlocks (1,1) double {mustBeInteger, mustBePositive} = 360
    opts.FhErasureEpochs (1,1) double {mustBeInteger, mustBePositive} = 18
    opts.FhErasureBatchSize (1,1) double {mustBeInteger, mustBePositive} = 128

    opts.ResidualBlocks (1,1) double {mustBeInteger, mustBePositive} = 220
    opts.ResidualBlockLen (1,1) double {mustBeInteger, mustBePositive} = 512
    opts.ResidualEpochs (1,1) double {mustBeInteger, mustBePositive} = 10
    opts.ResidualBatchSize (1,1) double {mustBeInteger, mustBePositive} = 16
    opts.ResumeFromTagArtifacts (1,1) logical = true
end

repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

if opts.UseGpu && ~canUseGPU()
    error("GPU training was requested, but canUseGPU() returned false.");
end
if opts.UseGpu
    gpuInfo = gpuDevice();
    fprintf("Using GPU: %s, %.2f GB available.\n", gpuInfo.Name, gpuInfo.AvailableMemory / 1024^3);
end

modelDir = string(opts.ModelDir);
outRoot = fullfile(char(opts.ResultsRoot), char(opts.Tag));
if ~exist(char(modelDir), "dir")
    mkdir(char(modelDir));
end
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.tag = opts.Tag;
report.modelDir = modelDir;
report.outRoot = string(outRoot);
report.opts = opts;

fprintf("\n=== Impulse profile CNN/GRU training ===\n");
impulseRuntime = local_runtime_config_local("impulse");
impulseCommon = { ...
    "nBlocks", opts.ImpulseBlocks, ...
    "blockLen", opts.ImpulseBlockLen, ...
    "epochs", opts.ImpulseEpochs, ...
    "batchSize", opts.ImpulseBatchSize, ...
    "ebN0dBRange", [4 10], ...
    "impulsePowerMode", "jsr_calibrated", ...
    "jsrDbRange", [-3 3], ...
    "impulseProbRange", [0.005 0.16], ...
    "impulseProbFocusRange", [0.01 0.08], ...
    "impulseProbFocusProbability", 0.70, ...
    "impulseEnableProbability", 1.0, ...
    "maxAdditionalImpairments", 0, ...
    "minPositiveRate", 0.001, ...
    "maxPositiveRate", 0.70, ...
    "pfaTarget", 0.02, ...
    "thresholdEvalFramesPerPoint", 1, ...
    "thresholdEvalEbN0dBList", [6 8], ...
    "thresholdEvalJsrDbList", 0, ...
    "useGpu", opts.UseGpu, ...
    "saveArtifacts", true, ...
    "saveDir", modelDir, ...
    "saveTag", opts.Tag, ...
    "savedBy", "run_profile_ml_gpu_training_eval", ...
    "verbose", true};

[impulseCnn, impulseCnnReport, reusedCnn] = local_load_tagged_model_local(modelDir, "impulse_cnn_model", opts.Tag, opts.ResumeFromTagArtifacts);
if ~reusedCnn
    [impulseCnn, impulseCnnReport] = ml_train_cnn_impulse(impulseRuntime, impulseCommon{:});
end
[impulseGru, impulseGruReport, reusedGru] = local_load_tagged_model_local(modelDir, "impulse_gru_model", opts.Tag, opts.ResumeFromTagArtifacts);
if ~reusedGru
    [impulseGru, impulseGruReport] = ml_train_gru_impulse(impulseRuntime, impulseCommon{:});
end
report.training.impulse.cnn = impulseCnnReport;
report.training.impulse.gru = impulseGruReport;

fprintf("\n=== Narrowband profile ML FH-erasure training ===\n");
narrowbandRuntime = local_runtime_config_local("narrowband");
[fhErasureModel, fhErasureReport, reusedFh] = local_load_tagged_model_local(modelDir, "fh_erasure_model", opts.Tag, opts.ResumeFromTagArtifacts);
if ~reusedFh
    [fhErasureModel, fhErasureReport] = ml_train_fh_erasure(narrowbandRuntime, ...
    "nBlocks", opts.FhErasureBlocks, ...
    "epochs", opts.FhErasureEpochs, ...
    "batchSize", opts.FhErasureBatchSize, ...
    "ebN0dBRange", [4 10], ...
    "hopsPerBlockRange", [64 192], ...
    "jsrDbRange", [-3 3], ...
    "narrowbandProbability", 0.90, ...
    "bandwidthFreqPointsRange", [0.6 1.4], ...
    "configuredCenterProbability", 0.50, ...
    "useGpu", opts.UseGpu, ...
    "saveArtifacts", true, ...
    "saveDir", modelDir, ...
    "saveTag", opts.Tag, ...
    "savedBy", "run_profile_ml_gpu_training_eval", ...
    "verbose", true);
end
report.training.narrowband.fhErasure = fhErasureReport;

fprintf("\n=== Narrowband profile residual CNN training ===\n");
[residualModel, residualReport, reusedResidual] = local_load_tagged_model_local(modelDir, "narrowband_residual_cnn_model", opts.Tag, opts.ResumeFromTagArtifacts);
if ~reusedResidual
    [residualModel, residualReport] = ml_train_narrowband_residual_cnn(narrowbandRuntime, ...
    "nBlocks", opts.ResidualBlocks, ...
    "blockLen", opts.ResidualBlockLen, ...
    "epochs", opts.ResidualEpochs, ...
    "batchSize", opts.ResidualBatchSize, ...
    "ebN0dBRange", [4 10], ...
    "jsrDbRange", [-3 3], ...
    "centerFreqPointsList", -3:0.5:3, ...
    "bandwidthFreqPointsList", [0.8 1.0 1.2], ...
    "useGpu", opts.UseGpu, ...
    "saveArtifacts", true, ...
    "saveDir", modelDir, ...
    "saveTag", opts.Tag, ...
    "savedBy", "run_profile_ml_gpu_training_eval", ...
    "verbose", true);
end
report.training.narrowband.residualCnn = residualReport;

fprintf("\n=== Impulse profile evaluation ===\n");
impulseResults = local_run_impulse_eval_local(outRoot, opts, impulseCnn, impulseGru);
report.evaluation.impulse.summary = local_method_summary_local(impulseResults);
report.evaluation.impulse.resultsPath = string(fullfile(outRoot, "impulse_eval", "results.mat"));
report.evaluation.impulse.summaryPath = string(fullfile(outRoot, "impulse_eval", "summary.csv"));
save(report.evaluation.impulse.resultsPath, "impulseResults");
writetable(report.evaluation.impulse.summary, report.evaluation.impulse.summaryPath);
disp(report.evaluation.impulse.summary);

fprintf("\n=== Narrowband profile evaluation ===\n");
narrowbandResults = local_run_narrowband_eval_local(outRoot, opts, fhErasureModel, residualModel);
report.evaluation.narrowband.summary = local_method_summary_local(narrowbandResults);
report.evaluation.narrowband.resultsPath = string(fullfile(outRoot, "narrowband_eval", "results.mat"));
report.evaluation.narrowband.summaryPath = string(fullfile(outRoot, "narrowband_eval", "summary.csv"));
save(report.evaluation.narrowband.resultsPath, "narrowbandResults");
writetable(report.evaluation.narrowband.summary, report.evaluation.narrowband.summaryPath);
disp(report.evaluation.narrowband.summary);

reportPath = fullfile(outRoot, "training_eval_report.mat");
save(reportPath, "report");
fprintf("\nProfile ML training/evaluation report saved: %s\n", reportPath);
end

function runtimeCfg = local_runtime_config_local(profileName)
linkSpec = default_params( ...
    "linkProfileName", string(profileName), ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false, ...
    "loadMlModels", strings(1, 0));
runtimeCfg = compile_runtime_config(linkSpec);
end

function [model, report, reused] = local_load_tagged_model_local(modelDir, baseName, tag, resumeEnabled)
model = struct();
report = struct();
reused = false;
if ~resumeEnabled
    return;
end
artifactPath = fullfile(char(modelDir), sprintf("%s_%s.mat", char(baseName), char(tag)));
if ~exist(artifactPath, "file")
    return;
end
s = load(artifactPath, "model", "report");
if ~(isfield(s, "model") && isstruct(s.model) && isfield(s, "report") && isstruct(s.report))
    error("Tagged artifact %s must contain struct variables model and report.", artifactPath);
end
model = s.model;
report = s.report;
reused = true;
fprintf("Reusing tagged model artifact: %s\n", artifactPath);
end

function results = local_run_impulse_eval_local(outRoot, opts, impulseCnn, impulseGru)
runDir = fullfile(outRoot, "impulse_eval");
if ~exist(runDir, "dir")
    mkdir(runDir);
end
linkSpec = default_params( ...
    "linkProfileName", "impulse", ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", true, ...
    "loadMlModels", strings(1, 0));
linkSpec.profileRx.cfg.methods = ["none" "blanking" "clipping" "ml_cnn" "ml_gru"];
linkSpec.linkBudget.ebN0dBList = 6;
linkSpec.linkBudget.jsrDbList = 0;
linkSpec.sim.nFramesPerPoint = opts.NFrames;
linkSpec.sim.useParallel = false;
linkSpec.sim.saveFigures = false;
linkSpec.sim.resultsDir = string(runDir);
linkSpec.extensions.ml.preloaded = struct( ...
    "impulseCnn", impulseCnn, ...
    "impulseGru", impulseGru);
results = simulate(linkSpec);
end

function results = local_run_narrowband_eval_local(outRoot, opts, fhErasureModel, residualModel)
runDir = fullfile(outRoot, "narrowband_eval");
if ~exist(runDir, "dir")
    mkdir(runDir);
end
linkSpec = default_params( ...
    "linkProfileName", "narrowband", ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", true, ...
    "loadMlModels", strings(1, 0));
linkSpec.profileRx.cfg.methods = ["none" "fh_erasure" "ml_fh_erasure" ...
    "narrowband_subband_excision_soft" "narrowband_cnn_residual_soft"];
linkSpec.linkBudget.ebN0dBList = 8;
linkSpec.linkBudget.jsrDbList = 0;
linkSpec.sim.nFramesPerPoint = opts.NFrames;
linkSpec.sim.useParallel = false;
linkSpec.sim.saveFigures = false;
linkSpec.sim.resultsDir = string(runDir);
linkSpec.extensions.ml.preloaded = struct( ...
    "fhErasure", fhErasureModel, ...
    "narrowbandResidual", residualModel);
results = simulate(linkSpec);
end

function tbl = local_method_summary_local(results)
methods = string(results.methods(:));
ber = double(results.ber(:, 1));
rawPer = double(results.rawPer(:, 1));
per = double(results.per(:, 1));
frontEnd = local_metric_column_local(results.packetDiagnostics.bob, "frontEndSuccessRateByMethod", numel(methods));
header = local_metric_column_local(results.packetDiagnostics.bob, "headerSuccessRateByMethod", numel(methods));
payload = local_metric_column_local(results.packetDiagnostics.bob, "payloadSuccessRate", numel(methods));
tbl = table(methods, ber, rawPer, per, frontEnd, header, payload);
end

function values = local_metric_column_local(diag, fieldName, nMethods)
fieldName = char(fieldName);
if ~(isstruct(diag) && isfield(diag, fieldName))
    values = nan(nMethods, 1);
    return;
end
x = double(diag.(fieldName));
if isempty(x)
    values = nan(nMethods, 1);
    return;
end
values = x(:, 1);
values = values(:);
if numel(values) ~= nMethods
    error("Metric %s has %d rows, expected %d.", fieldName, numel(values), nMethods);
end
end
