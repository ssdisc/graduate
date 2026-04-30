function report = sweep_robust_unified_ebn0(varargin)
%SWEEP_ROBUST_UNIFIED_EBN0 Sweep PER/rawPER/BER versus Eb/N0 for robust_unified.
%
% Example:
%   report = sweep_robust_unified_ebn0( ...
%       "EbN0List", 0:2:10, ...
%       "JsrDb", 0, ...
%       "NFramesPerPoint", 5, ...
%       "NWorkers", 4);

repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

opts = local_parse_inputs(repoRoot, varargin{:});
outRoot = fullfile(char(opts.ResultsRoot), char(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

tasks = local_build_tasks(opts, outRoot);
fprintf("[RU-EBN0] Output: %s\n", outRoot);
fprintf("[RU-EBN0] Cases: %s\n", strjoin(cellstr(opts.Cases), ", "));
fprintf("[RU-EBN0] Eb/N0 points: %s dB\n", mat2str(opts.EbN0List));
fprintf("[RU-EBN0] Total tasks: %d, JSR=%.3g dB, frames/point=%d\n", ...
    numel(tasks), double(opts.JsrDb), round(double(opts.NFramesPerPoint)));

pool = [];
if logical(opts.UseParallel) && double(opts.NFramesPerPoint) > 1
    pool = ensure_parpool(double(opts.NWorkers));
end

rows = repmat(local_empty_row(), numel(tasks), 1);
if logical(opts.UseParallel) && ~isempty(pool)
    fprintf("[RU-EBN0] Running serial tasks with frame-parallel pool: %d workers\n", pool.NumWorkers);
else
    fprintf("[RU-EBN0] Running serial tasks\n");
end
for taskIdx = 1:numel(tasks)
    rows(taskIdx) = local_run_task(tasks(taskIdx), opts);
end

summaryTable = struct2table(rows);
summaryTable = sortrows(summaryTable, ["caseName", "ebN0dB"]);
writetable(summaryTable, fullfile(outRoot, "summary.csv"));

caseSummary = local_case_summary(summaryTable);
writetable(caseSummary, fullfile(outRoot, "case_summary.csv"));

if logical(opts.MakeFigures)
    local_make_figures(summaryTable, outRoot, opts);
end

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.outRoot = string(outRoot);
report.opts = opts;
report.summaryTable = summaryTable;
report.caseSummary = caseSummary;
save(fullfile(outRoot, "report.mat"), "report");

fprintf("[RU-EBN0] Done. summary.csv rows=%d\n", height(summaryTable));
disp(caseSummary);
end

function opts = local_parse_inputs(repoRoot, varargin)
p = inputParser();
p.FunctionName = "sweep_robust_unified_ebn0";
addParameter(p, "Cases", ["impulse" "narrowband" "rayleigh_multipath" "all_three"], ...
    @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "EbN0List", 0:2:10, @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "JsrDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NFramesPerPoint", 5, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "NWorkers", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 0);
addParameter(p, "UseParallel", true, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ModulationType", "QPSK", @(x) ischar(x) || isstring(x));
addParameter(p, "ImagePath", "", @(x) ischar(x) || isstring(x));
addParameter(p, "ImpulseProb", 0.03, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0 && x <= 1);
addParameter(p, "NarrowbandCenter", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NarrowbandBandwidth", NaN, @(x) isscalar(x) && isnumeric(x) && (isnan(x) || (isfinite(x) && x > 0)));
addParameter(p, "RayleighDelays", [0 2 4], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "RayleighGainsDb", [0 -6 -10], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "PerPassThreshold", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 0);
addParameter(p, "SaveFullResults", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "MakeFigures", true, @(x) islogical(x) || isnumeric(x));
addParameter(p, "BerPlotFloor", 1e-5, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "ResultsRoot", fullfile(repoRoot, "results", "sweep_robust_unified_ebn0"), ...
    @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", "robust_unified_ebn0_" + string(datetime("now", "Format", "yyyyMMdd_HHmmss")), ...
    @(x) ischar(x) || isstring(x));
parse(p, varargin{:});

opts = p.Results;
opts.Cases = unique(lower(string(opts.Cases(:).')), "stable");
opts.EbN0List = double(opts.EbN0List(:).');
opts.NFramesPerPoint = round(double(opts.NFramesPerPoint));
opts.NWorkers = round(double(opts.NWorkers));
opts.UseParallel = logical(opts.UseParallel);
opts.ModulationType = upper(string(opts.ModulationType));
opts.ImagePath = string(strtrim(opts.ImagePath));
opts.RayleighDelays = double(opts.RayleighDelays(:).');
opts.RayleighGainsDb = double(opts.RayleighGainsDb(:).');
opts.SaveFullResults = logical(opts.SaveFullResults);
opts.MakeFigures = logical(opts.MakeFigures);
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);

allowedCases = ["impulse" "narrowband" "rayleigh_multipath" ...
    "impulse_narrowband" "impulse_rayleigh" "narrowband_rayleigh" "all_three"];
badCases = setdiff(opts.Cases, allowedCases);
if ~isempty(badCases)
    error("Unsupported Cases: %s.", strjoin(cellstr(badCases), ", "));
end
if ~any(opts.ModulationType == ["QPSK" "BPSK" "MSK"])
    error("Unsupported ModulationType: %s.", char(opts.ModulationType));
end
if numel(opts.RayleighDelays) ~= numel(opts.RayleighGainsDb)
    error("RayleighDelays and RayleighGainsDb must have the same length.");
end
if strlength(opts.ImagePath) > 0 && ~isfile(opts.ImagePath)
    error("ImagePath not found: %s.", char(opts.ImagePath));
end
end

function tasks = local_build_tasks(opts, outRoot)
nTasks = numel(opts.Cases) * numel(opts.EbN0List);
tasks = repmat(local_empty_task(), nTasks, 1);
taskIdx = 0;
for caseIdx = 1:numel(opts.Cases)
    for ebIdx = 1:numel(opts.EbN0List)
        taskIdx = taskIdx + 1;
        caseName = opts.Cases(caseIdx);
        ebN0dB = double(opts.EbN0List(ebIdx));
        tasks(taskIdx).caseName = caseName;
        tasks(taskIdx).caseIndex = caseIdx;
        tasks(taskIdx).ebIndex = ebIdx;
        tasks(taskIdx).ebN0dB = ebN0dB;
        tasks(taskIdx).runDir = string(fullfile(outRoot, char(caseName), local_eb_tag(ebN0dB)));
    end
end
end

function row = local_run_task(task, opts)
repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

row = local_empty_row();
row.caseName = string(task.caseName);
row.caseIndex = double(task.caseIndex);
row.ebIndex = double(task.ebIndex);
row.ebN0dB = double(task.ebN0dB);
row.jsrDb = double(opts.JsrDb);
row.runDir = string(task.runDir);

try
    runDir = char(task.runDir);
    if ~exist(runDir, "dir")
        mkdir(runDir);
    end
    spec = local_build_spec(task, opts);
    validate_link_profile(spec);

    tStart = tic;
    results = run_link_profile(spec);
    row.elapsedSec = toc(tStart);

    row.runOk = true;
    row.method = string(results.methods(1));
    row.ebN0dB = double(results.ebN0dB(1));
    row.jsrDb = double(results.jsrDb(1));
    row.ber = double(results.ber(1, 1));
    row.rawPer = double(results.rawPer(1, 1));
    row.per = double(results.per(1, 1));
    row.perExact = double(results.perExact(1, 1));
    row.psnrOriginal = double(results.imageMetrics.original.communication.psnr(1, 1));
    row.ssimOriginal = double(results.imageMetrics.original.communication.ssim(1, 1));
    row.burstSec = double(results.tx.burstDurationSec);
    row.frontEndSuccess = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(1, 1));
    row.phyHeaderSuccess = double(results.packetDiagnostics.bob.phyHeaderSuccessRateByMethod(1, 1));
    row.headerSuccess = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(1, 1));
    row.sessionTransportSuccess = double(results.packetDiagnostics.bob.sessionTransportSuccessRateByMethod(1, 1));
    row.packetSessionSuccess = double(results.packetDiagnostics.bob.packetSessionSuccessRateByMethod(1, 1));
    row.payloadSuccess = double(results.packetDiagnostics.bob.payloadSuccessRate(1, 1));
    row.pass = row.per <= double(opts.PerPassThreshold);

    local_save_task_artifact(runDir, row, spec, results, opts);
    fprintf("[RU-EBN0] %-18s Eb/N0=%+6.2f dB PER=%.4g rawPER=%.4g BER=%.4g elapsed=%.2fs\n", ...
        char(row.caseName), row.ebN0dB, row.per, row.rawPer, row.ber, row.elapsedSec);
catch ME
    row.runOk = false;
    row.errorMessage = string(ME.message);
    try
        if strlength(row.runDir) > 0 && ~exist(char(row.runDir), "dir")
            mkdir(char(row.runDir));
        end
        save(fullfile(char(row.runDir), "case_error.mat"), "row", "ME");
    catch
    end
    fprintf("[RU-EBN0] %-18s Eb/N0=%+6.2f dB FAILED: %s\n", ...
        char(row.caseName), row.ebN0dB, ME.message);
end
end

function spec = local_build_spec(task, opts)
spec = default_link_spec( ...
    "linkProfileName", "robust_unified", ...
    "loadMlModels", string.empty(1, 0), ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false);

if strlength(opts.ImagePath) > 0
    spec.commonTx.source.useBuiltinImage = false;
    spec.commonTx.source.imagePath = opts.ImagePath;
end

spec.commonTx.modulation.type = string(opts.ModulationType);
spec.commonTx.security.chaosEncrypt.enable = true;
spec.commonTx.security.chaosEncrypt.packetIndependent = true;
spec.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
spec.sim.saveFigures = false;
spec.sim.useParallel = logical(opts.UseParallel);
spec.sim.nWorkers = double(opts.NWorkers);
spec.sim.parallelMode = "frames";
spec.sim.resultsDir = string(task.runDir);
spec.linkBudget.ebN0dBList = double(task.ebN0dB);
spec.linkBudget.jsrDbList = double(opts.JsrDb);
spec.profileRx.cfg.methods = "robust_combo";

spec.profileRx.cfg.mitigation.robustMixed.narrowbandFrontend = "fh_erasure";
spec.profileRx.cfg.mitigation.robustMixed.enableFhSubbandExcision = false;
spec.profileRx.cfg.mitigation.robustMixed.enableScFdeNbiCancel = false;
spec.profileRx.cfg.mitigation.robustMixed.enableSampleNbiCancel = false;
spec.profileRx.cfg.mitigation.robustMixed.enableFhReliabilityFloorWithMultipath = false;

spec = local_reset_channel(spec, opts);
spec = local_apply_case_channel(spec, string(task.caseName), opts);
end

function spec = local_reset_channel(spec, opts)
spec.channel.impulseProb = 0.0;
spec.channel.impulseWeight = 0.0;
spec.channel.impulseToBgRatio = 0.0;
spec.channel.narrowband.enable = false;
spec.channel.narrowband.weight = 0.0;
spec.channel.narrowband.centerFreqPoints = double(opts.NarrowbandCenter);
spec.channel.narrowband.bandwidthFreqPoints = local_resolve_narrowband_bandwidth(spec, opts);
spec.channel.multipath.enable = false;
spec.channel.multipath.pathDelaysSymbols = double(opts.RayleighDelays);
spec.channel.multipath.pathGainsDb = double(opts.RayleighGainsDb);
spec.channel.multipath.rayleigh = true;
end

function spec = local_apply_case_channel(spec, caseName, opts)
caseName = lower(string(caseName));
switch caseName
    case "impulse"
        spec = local_enable_impulse(spec, opts);
    case "narrowband"
        spec = local_enable_narrowband(spec);
    case "rayleigh_multipath"
        spec = local_enable_rayleigh(spec);
    case "impulse_narrowband"
        spec = local_enable_impulse(spec, opts);
        spec = local_enable_narrowband(spec);
    case "impulse_rayleigh"
        spec = local_enable_impulse(spec, opts);
        spec = local_enable_rayleigh(spec);
    case "narrowband_rayleigh"
        spec = local_enable_narrowband(spec);
        spec = local_enable_rayleigh(spec);
    case "all_three"
        spec = local_enable_impulse(spec, opts);
        spec = local_enable_narrowband(spec);
        spec = local_enable_rayleigh(spec);
    otherwise
        error("Unsupported case: %s.", char(caseName));
end

if spec.channel.narrowband.enable
    local_validate_narrowband_center(spec);
end
end

function spec = local_enable_impulse(spec, opts)
spec.channel.impulseProb = double(opts.ImpulseProb);
spec.channel.impulseWeight = 1.0;
spec.channel.impulseToBgRatio = 0.0;
end

function spec = local_enable_narrowband(spec)
spec.channel.narrowband.enable = true;
spec.channel.narrowband.weight = 1.0;
end

function spec = local_enable_rayleigh(spec)
spec.channel.multipath.enable = true;
spec.channel.multipath.rayleigh = true;
end

function bw = local_resolve_narrowband_bandwidth(spec, opts)
if ~isnan(double(opts.NarrowbandBandwidth))
    bw = double(opts.NarrowbandBandwidth);
    return;
end
runtimeCfg = compile_runtime_config(spec);
bw = narrowband_prespread_fh_bandwidth_points(runtimeCfg.fh, runtimeCfg.waveform, runtimeCfg.dsss);
end

function local_validate_narrowband_center(spec)
runtimeCfg = compile_runtime_config(spec);
[maxAbsCenter, ~] = narrowband_center_freq_points_limit( ...
    runtimeCfg.fh, runtimeCfg.waveform, spec.channel.narrowband.bandwidthFreqPoints);
if abs(double(spec.channel.narrowband.centerFreqPoints)) > maxAbsCenter
    error("Narrowband center %.6g is outside the valid range [-%.6g, %.6g].", ...
        double(spec.channel.narrowband.centerFreqPoints), maxAbsCenter, maxAbsCenter);
end
end

function local_save_task_artifact(runDir, row, spec, results, opts)
caseResult = row;
caseResult.methods = string(results.methods(:).');
caseResult.txSummary = struct("burstDurationSec", double(results.tx.burstDurationSec));
if logical(opts.SaveFullResults)
    save(fullfile(runDir, "results.mat"), "results", "spec", "caseResult", "-v7.3");
else
    save(fullfile(runDir, "case_result.mat"), "caseResult", "spec");
end
end

function tbl = local_case_summary(summaryTable)
caseNames = unique(string(summaryTable.caseName), "stable");
rows = repmat(local_empty_case_summary_row(), numel(caseNames), 1);
for idx = 1:numel(caseNames)
    mask = string(summaryTable.caseName) == caseNames(idx);
    cur = summaryTable(mask, :);
    ok = logical(cur.runOk);
    rows(idx).caseName = caseNames(idx);
    rows(idx).nPoints = height(cur);
    rows(idx).nRunOk = sum(ok);
    rows(idx).nPass = sum(logical(cur.pass) & ok);
    rows(idx).maxPer = local_nanmax(cur.per(ok));
    rows(idx).maxRawPer = local_nanmax(cur.rawPer(ok));
    rows(idx).maxBer = local_nanmax(cur.ber(ok));
    rows(idx).minPsnrOriginal = local_nanmin(cur.psnrOriginal(ok));
    rows(idx).maxElapsedSec = local_nanmax(cur.elapsedSec(ok));
end
tbl = struct2table(rows);
end

function local_make_figures(summaryTable, outRoot, opts)
local_plot_metric(summaryTable, outRoot, "per", "PER", "per_ebn0_curve", false, opts);
local_plot_metric(summaryTable, outRoot, "rawPer", "rawPER", "rawper_ebn0_curve", false, opts);
local_plot_metric(summaryTable, outRoot, "ber", "BER", "ber_ebn0_curve", true, opts);
local_plot_metric(summaryTable, outRoot, "psnrOriginal", "PSNR (dB)", "psnr_ebn0_curve", false, opts);
local_plot_metric(summaryTable, outRoot, "ssimOriginal", "SSIM", "ssim_ebn0_curve", false, opts);
end

function local_plot_metric(summaryTable, outRoot, metricName, yLabelText, fileBase, useLogY, opts)
metricField = char(metricName);
fig = figure("Visible", "off", "Color", "w", "Position", [80 80 860 560]);
ax = axes(fig);
hold(ax, "on");
grid(ax, "on");

caseNames = unique(string(summaryTable.caseName), "stable");
colors = lines(max(1, numel(caseNames)));
for idx = 1:numel(caseNames)
    mask = string(summaryTable.caseName) == caseNames(idx) & logical(summaryTable.runOk);
    cur = summaryTable(mask, :);
    if isempty(cur)
        continue;
    end
    cur = sortrows(cur, "ebN0dB");
    x = double(cur.ebN0dB);
    y = double(cur.(metricField));
    if useLogY
        y = max(y, double(opts.BerPlotFloor));
        semilogy(ax, x, y, "-o", "LineWidth", 1.5, "Color", colors(idx, :), ...
            "DisplayName", local_case_display_name(caseNames(idx)));
    else
        plot(ax, x, y, "-o", "LineWidth", 1.5, "Color", colors(idx, :), ...
            "DisplayName", local_case_display_name(caseNames(idx)));
    end
end

xlabel(ax, "Eb/N0 (dB)");
ylabel(ax, yLabelText);
title(ax, sprintf("robust\\_unified %s vs Eb/N0 | JSR %.2f dB | frames/point %d", ...
    yLabelText, double(opts.JsrDb), round(double(opts.NFramesPerPoint))));
legend(ax, "Location", "best");
if ~useLogY && any(metricName == ["per" "rawPer"])
    ylim(ax, [-0.02 1.02]);
end
exportgraphics(fig, char(fullfile(outRoot, fileBase + ".png")), "Resolution", 200);
savefig(fig, char(fullfile(outRoot, fileBase + ".fig")));
close(fig);
end

function displayName = local_case_display_name(caseName)
displayName = strrep(char(caseName), "_", "\_");
end

function tag = local_eb_tag(ebN0dB)
if ebN0dB >= 0
    tag = sprintf("eb_p%05.2f", ebN0dB);
else
    tag = sprintf("eb_m%05.2f", abs(ebN0dB));
end
tag = strrep(tag, ".", "p");
end

function task = local_empty_task()
task = struct( ...
    "caseName", "", ...
    "caseIndex", NaN, ...
    "ebIndex", NaN, ...
    "ebN0dB", NaN, ...
    "runDir", "");
end

function row = local_empty_row()
row = struct( ...
    "caseName", "", ...
    "caseIndex", NaN, ...
    "ebIndex", NaN, ...
    "ebN0dB", NaN, ...
    "jsrDb", NaN, ...
    "runOk", false, ...
    "pass", false, ...
    "method", "", ...
    "ber", NaN, ...
    "rawPer", NaN, ...
    "per", NaN, ...
    "perExact", NaN, ...
    "psnrOriginal", NaN, ...
    "ssimOriginal", NaN, ...
    "burstSec", NaN, ...
    "elapsedSec", NaN, ...
    "frontEndSuccess", NaN, ...
    "phyHeaderSuccess", NaN, ...
    "headerSuccess", NaN, ...
    "sessionTransportSuccess", NaN, ...
    "packetSessionSuccess", NaN, ...
    "payloadSuccess", NaN, ...
    "runDir", "", ...
    "errorMessage", "");
end

function row = local_empty_case_summary_row()
row = struct( ...
    "caseName", "", ...
    "nPoints", 0, ...
    "nRunOk", 0, ...
    "nPass", 0, ...
    "maxPer", NaN, ...
    "maxRawPer", NaN, ...
    "maxBer", NaN, ...
    "minPsnrOriginal", NaN, ...
    "maxElapsedSec", NaN);
end

function v = local_nanmax(x)
x = double(x(:));
x = x(isfinite(x));
if isempty(x)
    v = NaN;
else
    v = max(x);
end
end

function v = local_nanmin(x)
x = double(x(:));
x = x(isfinite(x));
if isempty(x)
    v = NaN;
else
    v = min(x);
end
end
