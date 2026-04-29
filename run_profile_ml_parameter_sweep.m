function report = run_profile_ml_parameter_sweep(opts)
%RUN_PROFILE_ML_PARAMETER_SWEEP Sweep profile-adapted ML methods against traditional baselines.

arguments
    opts.ModelTag (1,1) string = "profile_ml_gpu_20260429_1420"
    opts.ModelDir (1,1) string = fullfile(pwd, "models")
    opts.ResultsRoot (1,1) string = fullfile(pwd, "results", "profile_ml_parameter_sweep")
    opts.Tag (1,1) string = string(datetime("now", "Format", "yyyyMMdd_HHmmss"))
    opts.NFramesPerPoint (1,1) double {mustBeInteger, mustBePositive} = 1
    opts.UseParallel (1,1) logical = false

    opts.ImpulseEbN0List double = [2 4 6 8]
    opts.ImpulseJsrDbList double = [-3 0 3]
    opts.ImpulseProbList double = [0.01 0.03 0.08]
    opts.ImpulseMethods string = ["none" "blanking" "clipping" "ml_cnn" "ml_gru"]

    opts.NarrowbandEbN0List double = [4 6 8]
    opts.NarrowbandJsrDbList double = [0 3 6]
    opts.NarrowbandCenterList double = [-3 -1.875 0 1.875 3]
    opts.NarrowbandBandwidthList double = [1.0 1.4]
    opts.NarrowbandMethods string = ["none" "fh_erasure" "ml_fh_erasure" ...
        "narrowband_subband_excision_soft" "narrowband_cnn_residual_soft"]
end

repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

opts = local_validate_opts_local(opts);
outRoot = fullfile(char(opts.ResultsRoot), char(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

models = local_load_models_local(opts.ModelDir, opts.ModelTag);

allRows = repmat(local_empty_row_local(), 0, 1);
caseReports = struct("impulse", {{}}, "narrowband", {{}});

fprintf("\n=== Impulse parameter sweep ===\n");
for probIdx = 1:numel(opts.ImpulseProbList)
    impulseProb = double(opts.ImpulseProbList(probIdx));
    caseName = sprintf("prob_%0.3f", impulseProb);
    runDir = fullfile(outRoot, "impulse", char(caseName));
    [results, elapsedSec] = local_run_impulse_case_local(opts, models, impulseProb, runDir);
    rows = local_rows_from_results_local("impulse", results, struct( ...
        "impulseProb", impulseProb, ...
        "narrowbandCenter", NaN, ...
        "narrowbandBandwidth", NaN), elapsedSec, runDir);
    allRows = [allRows; rows]; %#ok<AGROW>
    caseReports.impulse{end + 1} = local_case_report_local(caseName, runDir, elapsedSec, rows);
    writetable(struct2table(rows), fullfile(runDir, "summary.csv"));
    fprintf("[IMPULSE] %s elapsed=%.2fs rows=%d\n", char(caseName), elapsedSec, numel(rows));
end

fprintf("\n=== Narrowband parameter sweep ===\n");
for bwIdx = 1:numel(opts.NarrowbandBandwidthList)
    bandwidth = double(opts.NarrowbandBandwidthList(bwIdx));
    for centerIdx = 1:numel(opts.NarrowbandCenterList)
        center = double(opts.NarrowbandCenterList(centerIdx));
        caseName = sprintf("center_%+0.3f_bw_%0.3f", center, bandwidth);
        runDir = fullfile(outRoot, "narrowband", char(local_safe_name_local(caseName)));
        [results, elapsedSec] = local_run_narrowband_case_local(opts, models, center, bandwidth, runDir);
        rows = local_rows_from_results_local("narrowband", results, struct( ...
            "impulseProb", NaN, ...
            "narrowbandCenter", center, ...
            "narrowbandBandwidth", bandwidth), elapsedSec, runDir);
        allRows = [allRows; rows]; %#ok<AGROW>
        caseReports.narrowband{end + 1} = local_case_report_local(caseName, runDir, elapsedSec, rows);
        writetable(struct2table(rows), fullfile(runDir, "summary.csv"));
        fprintf("[NARROWBAND] %s elapsed=%.2fs rows=%d\n", char(caseName), elapsedSec, numel(rows));
    end
end

summaryTable = struct2table(allRows);
summaryPath = fullfile(outRoot, "summary.csv");
writetable(summaryTable, summaryPath);

methodSummary = local_method_summary_local(summaryTable);
methodSummaryPath = fullfile(outRoot, "method_summary.csv");
writetable(methodSummary, methodSummaryPath);

bestByCase = local_best_by_case_local(summaryTable);
bestByCasePath = fullfile(outRoot, "best_by_case.csv");
writetable(bestByCase, bestByCasePath);

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.modelTag = opts.ModelTag;
report.outRoot = string(outRoot);
report.summaryPath = string(summaryPath);
report.methodSummaryPath = string(methodSummaryPath);
report.bestByCasePath = string(bestByCasePath);
report.opts = opts;
report.caseReports = caseReports;
report.summaryTable = summaryTable;
report.methodSummary = methodSummary;
report.bestByCase = bestByCase;
save(fullfile(outRoot, "report.mat"), "report", "-v7.3");

fprintf("\nSweep summary saved: %s\n", summaryPath);
disp(methodSummary);
end

function opts = local_validate_opts_local(opts)
opts.ImpulseMethods = string(opts.ImpulseMethods(:).');
opts.NarrowbandMethods = string(opts.NarrowbandMethods(:).');
opts.ImpulseEbN0List = local_finite_vector_local(opts.ImpulseEbN0List, "ImpulseEbN0List");
opts.ImpulseJsrDbList = local_finite_vector_local(opts.ImpulseJsrDbList, "ImpulseJsrDbList");
opts.ImpulseProbList = local_finite_vector_local(opts.ImpulseProbList, "ImpulseProbList");
if any(opts.ImpulseProbList <= 0 | opts.ImpulseProbList > 1)
    error("ImpulseProbList must be inside (0, 1].");
end
opts.NarrowbandEbN0List = local_finite_vector_local(opts.NarrowbandEbN0List, "NarrowbandEbN0List");
opts.NarrowbandJsrDbList = local_finite_vector_local(opts.NarrowbandJsrDbList, "NarrowbandJsrDbList");
opts.NarrowbandCenterList = local_finite_vector_local(opts.NarrowbandCenterList, "NarrowbandCenterList");
opts.NarrowbandBandwidthList = local_finite_vector_local(opts.NarrowbandBandwidthList, "NarrowbandBandwidthList");
if any(opts.NarrowbandBandwidthList <= 0)
    error("NarrowbandBandwidthList must be positive.");
end
end

function values = local_finite_vector_local(raw, name)
values = double(raw(:).');
if isempty(values) || any(~isfinite(values))
    error("%s must be a non-empty finite vector.", name);
end
end

function models = local_load_models_local(modelDir, modelTag)
modelDir = string(modelDir);
models = struct();
models.impulseCnn = local_load_model_artifact_local(modelDir, "impulse_cnn_model", modelTag);
models.impulseGru = local_load_model_artifact_local(modelDir, "impulse_gru_model", modelTag);
models.fhErasure = local_load_model_artifact_local(modelDir, "fh_erasure_model", modelTag);
models.narrowbandResidual = local_load_model_artifact_local(modelDir, "narrowband_residual_cnn_model", modelTag);
end

function model = local_load_model_artifact_local(modelDir, baseName, modelTag)
artifactPath = fullfile(char(modelDir), sprintf("%s_%s.mat", char(baseName), char(modelTag)));
if ~exist(artifactPath, "file")
    error("Required model artifact is missing: %s", artifactPath);
end
s = load(artifactPath, "model");
if ~(isfield(s, "model") && isstruct(s.model))
    error("Model artifact %s must contain struct variable model.", artifactPath);
end
model = s.model;
fprintf("Loaded model artifact: %s\n", artifactPath);
end

function [results, elapsedSec] = local_run_impulse_case_local(opts, models, impulseProb, runDir)
if ~exist(runDir, "dir")
    mkdir(runDir);
end
cfg = default_params( ...
    "linkProfileName", "impulse", ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", true, ...
    "loadMlModels", strings(1, 0));
cfg.profileRx.cfg.methods = opts.ImpulseMethods;
cfg.linkBudget.ebN0dBList = opts.ImpulseEbN0List;
cfg.linkBudget.jsrDbList = opts.ImpulseJsrDbList;
cfg.channel.impulseProb = double(impulseProb);
cfg.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
cfg.sim.useParallel = logical(opts.UseParallel);
cfg.sim.saveFigures = false;
cfg.sim.resultsDir = string(runDir);
cfg.extensions.ml.preloaded = struct( ...
    "impulseCnn", models.impulseCnn, ...
    "impulseGru", models.impulseGru);
validate_link_profile(cfg);
tStart = tic;
results = simulate(cfg);
elapsedSec = toc(tStart);
save(fullfile(runDir, "results.mat"), "results", "-v7.3");
end

function [results, elapsedSec] = local_run_narrowband_case_local(opts, models, center, bandwidth, runDir)
if ~exist(runDir, "dir")
    mkdir(runDir);
end
cfg = default_params( ...
    "linkProfileName", "narrowband", ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", true, ...
    "loadMlModels", strings(1, 0));
cfg.profileRx.cfg.methods = opts.NarrowbandMethods;
cfg.linkBudget.ebN0dBList = opts.NarrowbandEbN0List;
cfg.linkBudget.jsrDbList = opts.NarrowbandJsrDbList;
cfg.channel.narrowband.centerFreqPoints = double(center);
cfg.channel.narrowband.bandwidthFreqPoints = double(bandwidth);
cfg.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
cfg.sim.useParallel = logical(opts.UseParallel);
cfg.sim.saveFigures = false;
cfg.sim.resultsDir = string(runDir);
cfg.extensions.ml.preloaded = struct( ...
    "fhErasure", models.fhErasure, ...
    "narrowbandResidual", models.narrowbandResidual);
local_validate_narrowband_center_local(cfg);
validate_link_profile(cfg);
tStart = tic;
results = simulate(cfg);
elapsedSec = toc(tStart);
save(fullfile(runDir, "results.mat"), "results", "-v7.3");
end

function local_validate_narrowband_center_local(cfg)
runtimeCfg = compile_runtime_config(cfg);
waveform = resolve_waveform_cfg(runtimeCfg);
[maxCenter, info] = narrowband_center_freq_points_limit( ...
    runtimeCfg.fh, waveform, runtimeCfg.channel.narrowband.bandwidthFreqPoints);
center = abs(double(runtimeCfg.channel.narrowband.centerFreqPoints));
if center > maxCenter
    error("narrowband center %.6g exceeds valid +/-%.6g FH-point range for bandwidth %.6g (spacingNorm %.6g).", ...
        double(runtimeCfg.channel.narrowband.centerFreqPoints), maxCenter, ...
        double(runtimeCfg.channel.narrowband.bandwidthFreqPoints), double(info.spacingNorm));
end
end

function rows = local_rows_from_results_local(profileName, results, caseCfg, elapsedSec, runDir)
methods = string(results.methods(:));
nMethods = numel(methods);
nPoints = numel(results.ebN0dB);
rows = repmat(local_empty_row_local(), nMethods * nPoints, 1);
dst = 1;
for methodIdx = 1:nMethods
    for pointIdx = 1:nPoints
        row = local_empty_row_local();
        row.profile = string(profileName);
        row.method = methods(methodIdx);
        row.ebN0dB = double(results.ebN0dB(pointIdx));
        row.jsrDb = double(results.jsrDb(pointIdx));
        row.impulseProb = double(caseCfg.impulseProb);
        row.narrowbandCenter = double(caseCfg.narrowbandCenter);
        row.narrowbandBandwidth = double(caseCfg.narrowbandBandwidth);
        row.ber = double(results.ber(methodIdx, pointIdx));
        row.rawPer = double(results.rawPer(methodIdx, pointIdx));
        row.per = double(results.per(methodIdx, pointIdx));
        row.perExact = local_optional_matrix_value_local(results, "perExact", methodIdx, pointIdx);
        row.frontEndSuccess = local_optional_diag_value_local(results.packetDiagnostics.bob, "frontEndSuccessRateByMethod", methodIdx, pointIdx);
        row.phyHeaderSuccess = local_optional_diag_value_local(results.packetDiagnostics.bob, "phyHeaderSuccessRateByMethod", methodIdx, pointIdx);
        row.headerSuccess = local_optional_diag_value_local(results.packetDiagnostics.bob, "headerSuccessRateByMethod", methodIdx, pointIdx);
        row.sessionSuccess = local_optional_diag_value_local(results.packetDiagnostics.bob, "sessionSuccessRateByMethod", methodIdx, pointIdx);
        row.payloadSuccess = local_optional_diag_value_local(results.packetDiagnostics.bob, "payloadSuccessRate", methodIdx, pointIdx);
        row.exactFrameSuccess = local_optional_diag_value_local(results.packetDiagnostics.bob, "exactFrameSuccessRate", methodIdx, pointIdx);
        row.psnrOriginalComm = local_image_metric_value_local(results, "original", "communication", "psnr", methodIdx, pointIdx);
        row.ssimOriginalComm = local_image_metric_value_local(results, "original", "communication", "ssim", methodIdx, pointIdx);
        row.psnrResizedComm = local_image_metric_value_local(results, "resized", "communication", "psnr", methodIdx, pointIdx);
        row.ssimResizedComm = local_image_metric_value_local(results, "resized", "communication", "ssim", methodIdx, pointIdx);
        row.burstSec = double(results.tx.burstDurationSec);
        row.elapsedSec = double(elapsedSec);
        row.runDir = string(runDir);
        rows(dst) = row;
        dst = dst + 1;
    end
end
end

function row = local_empty_row_local()
row = struct( ...
    "profile", "", ...
    "method", "", ...
    "ebN0dB", NaN, ...
    "jsrDb", NaN, ...
    "impulseProb", NaN, ...
    "narrowbandCenter", NaN, ...
    "narrowbandBandwidth", NaN, ...
    "ber", NaN, ...
    "rawPer", NaN, ...
    "per", NaN, ...
    "perExact", NaN, ...
    "frontEndSuccess", NaN, ...
    "phyHeaderSuccess", NaN, ...
    "headerSuccess", NaN, ...
    "sessionSuccess", NaN, ...
    "payloadSuccess", NaN, ...
    "exactFrameSuccess", NaN, ...
    "psnrOriginalComm", NaN, ...
    "ssimOriginalComm", NaN, ...
    "psnrResizedComm", NaN, ...
    "ssimResizedComm", NaN, ...
    "burstSec", NaN, ...
    "elapsedSec", NaN, ...
    "runDir", "");
end

function value = local_optional_matrix_value_local(s, fieldName, methodIdx, pointIdx)
if isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = double(s.(fieldName)(methodIdx, pointIdx));
else
    value = NaN;
end
end

function value = local_optional_diag_value_local(diag, fieldName, methodIdx, pointIdx)
if isstruct(diag) && isfield(diag, fieldName) && ~isempty(diag.(fieldName))
    value = double(diag.(fieldName)(methodIdx, pointIdx));
else
    value = NaN;
end
end

function value = local_image_metric_value_local(results, refName, stateName, metricName, methodIdx, pointIdx)
try
    value = double(results.imageMetrics.(char(refName)).(char(stateName)).(char(metricName))(methodIdx, pointIdx));
catch err
    error("Missing image metric imageMetrics.%s.%s.%s: %s", ...
        char(refName), char(stateName), char(metricName), err.message);
end
end

function caseReport = local_case_report_local(caseName, runDir, elapsedSec, rows)
tbl = struct2table(rows);
caseReport = struct();
caseReport.caseName = string(caseName);
caseReport.runDir = string(runDir);
caseReport.elapsedSec = double(elapsedSec);
caseReport.nRows = height(tbl);
caseReport.maxPer = max(tbl.per, [], "omitnan");
caseReport.minBer = min(tbl.ber, [], "omitnan");
end

function t = local_method_summary_local(summaryTable)
profiles = string(summaryTable.profile);
methods = string(summaryTable.method);
pairs = unique(table(profiles, methods), "rows", "stable");
rows = repmat(struct( ...
    "profile", "", ...
    "method", "", ...
    "nRows", NaN, ...
    "meanBer", NaN, ...
    "medianBer", NaN, ...
    "meanPer", NaN, ...
    "maxPer", NaN, ...
    "passRatePer0", NaN, ...
    "meanRawPer", NaN, ...
    "meanPsnrOriginalComm", NaN, ...
    "meanSsimOriginalComm", NaN), height(pairs), 1);
for idx = 1:height(pairs)
    mask = profiles == pairs.profiles(idx) & methods == pairs.methods(idx);
    row = rows(idx);
    row.profile = pairs.profiles(idx);
    row.method = pairs.methods(idx);
    row.nRows = nnz(mask);
    row.meanBer = mean(summaryTable.ber(mask), "omitnan");
    row.medianBer = median(summaryTable.ber(mask), "omitnan");
    row.meanPer = mean(summaryTable.per(mask), "omitnan");
    row.maxPer = max(summaryTable.per(mask), [], "omitnan");
    row.passRatePer0 = mean(double(summaryTable.per(mask) <= 1e-12), "omitnan");
    row.meanRawPer = mean(summaryTable.rawPer(mask), "omitnan");
    row.meanPsnrOriginalComm = mean(summaryTable.psnrOriginalComm(mask), "omitnan");
    row.meanSsimOriginalComm = mean(summaryTable.ssimOriginalComm(mask), "omitnan");
    rows(idx) = row;
end
t = struct2table(rows);
end

function t = local_best_by_case_local(summaryTable)
profileKey = string(summaryTable.profile);
ebKey = double(summaryTable.ebN0dB);
jsrKey = double(summaryTable.jsrDb);
impulseKey = local_fill_nan_key_local(summaryTable.impulseProb, -999999);
centerKey = local_fill_nan_key_local(summaryTable.narrowbandCenter, -999998);
bandwidthKey = local_fill_nan_key_local(summaryTable.narrowbandBandwidth, -999997);
[groupIdx, profileU, ebU, jsrU, impulseU, centerU, bandwidthU] = findgroups( ...
    profileKey, ebKey, jsrKey, impulseKey, centerKey, bandwidthKey);
nGroups = max(groupIdx);
rows = repmat(struct( ...
    "profile", "", ...
    "ebN0dB", NaN, ...
    "jsrDb", NaN, ...
    "impulseProb", NaN, ...
    "narrowbandCenter", NaN, ...
    "narrowbandBandwidth", NaN, ...
    "bestMethod", "", ...
    "bestBer", NaN, ...
    "bestPer", NaN, ...
    "bestRawPer", NaN), nGroups, 1);
for idx = 1:nGroups
    mask = groupIdx == idx;
    sub = summaryTable(mask, :);
    score = sub.per * 1e6 + sub.rawPer * 1e3 + sub.ber;
    [~, bestIdx] = min(score);
    row = rows(idx);
    row.profile = profileU(idx);
    row.ebN0dB = ebU(idx);
    row.jsrDb = jsrU(idx);
    row.impulseProb = local_restore_nan_key_local(impulseU(idx), -999999);
    row.narrowbandCenter = local_restore_nan_key_local(centerU(idx), -999998);
    row.narrowbandBandwidth = local_restore_nan_key_local(bandwidthU(idx), -999997);
    row.bestMethod = string(sub.method(bestIdx));
    row.bestBer = double(sub.ber(bestIdx));
    row.bestPer = double(sub.per(bestIdx));
    row.bestRawPer = double(sub.rawPer(bestIdx));
    rows(idx) = row;
end
t = struct2table(rows);
end

function values = local_fill_nan_key_local(raw, sentinel)
values = double(raw);
values(isnan(values)) = double(sentinel);
end

function value = local_restore_nan_key_local(raw, sentinel)
value = double(raw);
if value == double(sentinel)
    value = NaN;
end
end

function name = local_safe_name_local(name)
name = regexprep(string(name), "[^A-Za-z0-9_.-]", "_");
name = replace(name, "+", "p");
name = replace(name, "-", "m");
end
