function report = validate_robust_unified_single_sweeps(varargin)
%VALIDATE_ROBUST_UNIFIED_SINGLE_SWEEPS Coverage validation for robust_unified single-interference cases.

opts = local_parse_inputs(varargin{:});
repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

outRoot = fullfile(char(opts.ResultsRoot), char(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.outRoot = string(outRoot);
report.opts = opts;
report.suites = struct();
report.summary = struct();

if any(opts.Suites == "impulse")
    [report.suites.impulse, report.summary.impulse] = local_run_impulse_suite(opts, outRoot);
end
if any(opts.Suites == "narrowband")
    [report.suites.narrowband, report.summary.narrowband] = local_run_narrowband_suite(opts, outRoot);
end
if any(opts.Suites == "rayleigh_multipath")
    [report.suites.rayleigh_multipath, report.summary.rayleigh_multipath] = local_run_rayleigh_suite(opts, outRoot);
end

save(fullfile(outRoot, "report.mat"), "report");
local_print_summary(report.summary);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "validate_robust_unified_single_sweeps";
addParameter(p, "Suites", ["impulse" "narrowband" "rayleigh_multipath"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "EbN0dB", 6, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "JsrDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NFramesPerPoint", 1, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "BurstThresholdSec", 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "ElapsedThresholdSec", 120, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "ImpulseProbList", [0.01 0.03 0.05 0.08 0.12 0.16], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "NarrowbandCenters", -3:0.5:3, @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "NarrowbandBandwidth", NaN, @(x) isscalar(x) && isnumeric(x) && (isnan(x) || (isfinite(x) && x > 0)));
addParameter(p, "RayleighDelayCases", { ...
    [0 1 2], ...
    [0 1 4], ...
    [0 2 4], ...
    [0 3 4], ...
    [0 1 3 5], ...
    [0 4 8]}, @(x) iscell(x) && ~isempty(x));
addParameter(p, "RayleighGainCases", { ...
    [0 -6 -10], ...
    [0 -8 -14], ...
    [0 -6 -10], ...
    [0 -6 -12], ...
    [0 -5 -9 -13], ...
    [0 -4 -8]}, @(x) iscell(x) && ~isempty(x));
addParameter(p, "RayleighCaseLabels", ["d012_g0m6m10" "d014_g0m8m14" "d024_g0m6m10" "d034_g0m6m12" "d0135_g0m5m9m13" "d048_g0m4m8"], ...
    @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "SaveFullResults", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results", "validate_robust_unified_single_sweeps"), @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", "robust_unified_single_sweeps_" + string(datetime("now", "Format", "yyyyMMdd_HHmmss")), @(x) ischar(x) || isstring(x));
parse(p, varargin{:});
opts = p.Results;
opts.Suites = unique(string(opts.Suites(:).'), "stable");
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
opts.SaveFullResults = logical(opts.SaveFullResults);
opts.RayleighCaseLabels = string(opts.RayleighCaseLabels(:).');
if numel(opts.RayleighDelayCases) ~= numel(opts.RayleighGainCases)
    error("RayleighDelayCases and RayleighGainCases must have the same length.");
end
if ~isempty(opts.RayleighCaseLabels) && numel(opts.RayleighCaseLabels) ~= numel(opts.RayleighDelayCases)
    error("RayleighCaseLabels length must match RayleighDelayCases.");
end
end

function [tbl, summary] = local_run_impulse_suite(opts, outRoot)
suiteRoot = fullfile(outRoot, "impulse");
local_mkdir(suiteRoot);
probs = double(opts.ImpulseProbList(:).');
rows = repmat(local_empty_row(), numel(probs), 1);

for idx = 1:numel(probs)
    prob = probs(idx);
    caseName = sprintf("prob_%0.3f", prob);
    row = local_empty_row();
    row.suite = "impulse";
    row.caseName = string(caseName);
    row.paramAText = "impulseProb";
    row.paramA = prob;
    row.runDir = string(fullfile(suiteRoot, caseName));

    spec = local_base_spec(opts, row.runDir);
    spec.channel.impulseProb = prob;
    spec.channel.impulseWeight = 1.0;
    spec.channel.impulseToBgRatio = 0.0;
    spec.channel.narrowband.enable = false;
    spec.channel.narrowband.weight = 0.0;
    spec.channel.multipath.enable = false;

    rows(idx) = local_run_single_case(spec, row, opts);
end

tbl = struct2table(rows);
summary = local_finish_suite(tbl, suiteRoot, "impulse");
end

function [tbl, summary] = local_run_narrowband_suite(opts, outRoot)
suiteRoot = fullfile(outRoot, "narrowband");
local_mkdir(suiteRoot);
centers = double(opts.NarrowbandCenters(:).');
rows = repmat(local_empty_row(), numel(centers), 1);

for idx = 1:numel(centers)
    center = centers(idx);
    spec = local_base_spec(opts, "");
    bw = local_resolve_narrowband_bandwidth_local(opts, spec);
    caseName = sprintf("center_%+0.1f_bw_%0.3f", center, bw);
    row = local_empty_row();
    row.suite = "narrowband";
    row.caseName = string(caseName);
    row.paramAText = "centerFreqPoints";
    row.paramBText = "bandwidthFreqPoints";
    row.paramA = center;
    row.paramB = bw;
    row.runDir = string(fullfile(suiteRoot, caseName));

    spec.sim.resultsDir = row.runDir;
    spec.channel.impulseProb = 0.0;
    spec.channel.impulseWeight = 0.0;
    spec.channel.impulseToBgRatio = 0.0;
    spec.channel.narrowband.enable = true;
    spec.channel.narrowband.weight = 1.0;
    spec.channel.narrowband.centerFreqPoints = center;
    spec.channel.narrowband.bandwidthFreqPoints = bw;
    spec.channel.multipath.enable = false;
    local_validate_narrowband_center_local(spec);

    rows(idx) = local_run_single_case(spec, row, opts);
end

tbl = struct2table(rows);
summary = local_finish_suite(tbl, suiteRoot, "narrowband");
end

function [tbl, summary] = local_run_rayleigh_suite(opts, outRoot)
suiteRoot = fullfile(outRoot, "rayleigh_multipath");
local_mkdir(suiteRoot);
nCases = numel(opts.RayleighDelayCases);
rows = repmat(local_empty_row(), nCases, 1);

for idx = 1:nCases
    delays = double(opts.RayleighDelayCases{idx}(:).');
    gains = double(opts.RayleighGainCases{idx}(:).');
    caseLabel = opts.RayleighCaseLabels(idx);
    row = local_empty_row();
    row.suite = "rayleigh_multipath";
    row.caseName = caseLabel;
    row.paramAText = "pathDelaysSymbols";
    row.paramBText = "pathGainsDb";
    row.paramAList = string(mat2str(delays));
    row.paramBList = string(mat2str(gains));
    row.runDir = string(fullfile(suiteRoot, char(caseLabel)));

    spec = local_base_spec(opts, row.runDir);
    spec.channel.impulseProb = 0.0;
    spec.channel.impulseWeight = 0.0;
    spec.channel.impulseToBgRatio = 0.0;
    spec.channel.narrowband.enable = false;
    spec.channel.narrowband.weight = 0.0;
    spec.channel.multipath.enable = true;
    spec.channel.multipath.pathDelaysSymbols = delays;
    spec.channel.multipath.pathGainsDb = gains;
    spec.channel.multipath.rayleigh = true;

    rows(idx) = local_run_single_case(spec, row, opts);
end

tbl = struct2table(rows);
summary = local_finish_suite(tbl, suiteRoot, "rayleigh_multipath");
end

function spec = local_base_spec(opts, runDir)
spec = default_link_spec( ...
    "linkProfileName", "robust_unified", ...
    "loadMlModels", string.empty(1, 0), ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false);
spec.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
spec.sim.saveFigures = false;
spec.sim.useParallel = false;
spec.sim.resultsDir = string(runDir);
spec.linkBudget.ebN0dBList = double(opts.EbN0dB);
spec.linkBudget.jsrDbList = double(opts.JsrDb);
end

function bw = local_resolve_narrowband_bandwidth_local(opts, spec)
if ~isnan(double(opts.NarrowbandBandwidth))
    bw = double(opts.NarrowbandBandwidth);
    return;
end
runtimeCfg = compile_runtime_config(spec);
bw = narrowband_prespread_fh_bandwidth_points(runtimeCfg.fh, runtimeCfg.waveform, runtimeCfg.dsss);
end

function row = local_run_single_case(spec, row, opts)
runDir = char(row.runDir);
local_mkdir(runDir);
try
    validate_link_profile(spec);
    tStart = tic;
    results = run_link_profile(spec);
    row.elapsedSec = toc(tStart);
    row.runOk = true;
    row.method = string(results.methods(1));
    row.ebN0dB = double(results.ebN0dB(1));
    row.jsrDb = double(results.jsrDb(1));
    row.burstSec = double(results.tx.burstDurationSec);
    row.ber = double(results.ber(1, 1));
    row.rawPer = double(results.rawPer(1, 1));
    row.per = double(results.per(1, 1));
    row.frontEndSuccess = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(1, 1));
    row.phyHeaderSuccess = double(results.packetDiagnostics.bob.phyHeaderSuccessRateByMethod(1, 1));
    row.headerSuccess = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(1, 1));
    row.sessionSuccess = double(results.packetDiagnostics.bob.sessionSuccessRateByMethod(1, 1));
    row.sessionTransportSuccess = double(results.packetDiagnostics.bob.sessionTransportSuccessRateByMethod(1, 1));
    row.packetSessionSuccess = double(results.packetDiagnostics.bob.packetSessionSuccessRateByMethod(1, 1));
    row.payloadSuccess = double(results.packetDiagnostics.bob.payloadSuccessRate(1, 1));
    row.pass = row.per == 0 ...
        && row.burstSec < double(opts.BurstThresholdSec) ...
        && row.elapsedSec < double(opts.ElapsedThresholdSec);
    local_save_case_artifact_local(runDir, row, spec, results, opts);
    fprintf("[RU-SINGLE] %-18s %-24s PER=%.4g rawPER=%.4g phy=%.4g sessTx=%.4g pktSess=%.4g payload=%.4g burst=%.3fs elapsed=%.3fs pass=%d\n", ...
        char(row.suite), char(row.caseName), row.per, row.rawPer, row.phyHeaderSuccess, ...
        row.sessionTransportSuccess, row.packetSessionSuccess, row.payloadSuccess, ...
        row.burstSec, row.elapsedSec, row.pass);
catch ME
    row.errorMessage = string(ME.message);
    fprintf("[RU-SINGLE] %-18s %-24s FAILED: %s\n", ...
        char(row.suite), char(row.caseName), ME.message);
end
end

function local_save_case_artifact_local(runDir, row, spec, results, opts)
if logical(opts.SaveFullResults)
    save(fullfile(runDir, "results.mat"), "results", "spec", "-v7.3");
    return;
end
caseResult = row;
caseResult.savedFullResults = false;
caseResult.methods = string(results.methods(:).');
caseResult.txSummary = struct("burstDurationSec", double(results.tx.burstDurationSec));
save(fullfile(runDir, "case_result.mat"), "caseResult", "spec");
end

function summary = local_finish_suite(tbl, suiteRoot, suiteName)
writetable(tbl, fullfile(suiteRoot, "summary.csv"));
summary = struct();
summary.suite = string(suiteName);
summary.nCases = height(tbl);
summary.nRunOk = sum(tbl.runOk);
summary.nPass = sum(tbl.pass);
summary.maxElapsedSec = max(tbl.elapsedSec, [], "omitnan");
summary.maxBurstSec = max(tbl.burstSec, [], "omitnan");
summary.maxPer = max(tbl.per, [], "omitnan");
summary.maxRawPer = max(tbl.rawPer, [], "omitnan");
summary.minPhyHeaderSuccess = min(tbl.phyHeaderSuccess, [], "omitnan");
summary.minHeaderSuccess = min(tbl.headerSuccess, [], "omitnan");
summary.minSessionTransportSuccess = min(tbl.sessionTransportSuccess, [], "omitnan");
summary.minPacketSessionSuccess = min(tbl.packetSessionSuccess, [], "omitnan");
summary.minPayloadSuccess = min(tbl.payloadSuccess, [], "omitnan");
save(fullfile(suiteRoot, "summary.mat"), "summary");
end

function row = local_empty_row()
row = struct( ...
    "suite", "", ...
    "caseName", "", ...
    "method", "", ...
    "runOk", false, ...
    "pass", false, ...
    "ebN0dB", NaN, ...
    "jsrDb", NaN, ...
    "elapsedSec", NaN, ...
    "burstSec", NaN, ...
    "ber", NaN, ...
    "rawPer", NaN, ...
    "per", NaN, ...
    "frontEndSuccess", NaN, ...
    "phyHeaderSuccess", NaN, ...
    "headerSuccess", NaN, ...
    "sessionSuccess", NaN, ...
    "sessionTransportSuccess", NaN, ...
    "packetSessionSuccess", NaN, ...
    "payloadSuccess", NaN, ...
    "paramAText", "", ...
    "paramBText", "", ...
    "paramA", NaN, ...
    "paramB", NaN, ...
    "paramAList", "", ...
    "paramBList", "", ...
    "runDir", "", ...
    "errorMessage", "");
end

function local_validate_narrowband_center_local(spec)
runtimeCfg = compile_runtime_config(spec);
waveform = resolve_waveform_cfg(runtimeCfg);
[maxCenter, info] = narrowband_center_freq_points_limit(runtimeCfg.fh, waveform, runtimeCfg.channel.narrowband.bandwidthFreqPoints);
center = abs(double(runtimeCfg.channel.narrowband.centerFreqPoints));
if center > maxCenter
    error("narrowband center %.6g exceeds valid +/-%.6g FH-point range for bandwidth %.6g (spacingNorm %.6g).", ...
        double(runtimeCfg.channel.narrowband.centerFreqPoints), maxCenter, ...
        double(runtimeCfg.channel.narrowband.bandwidthFreqPoints), double(info.spacingNorm));
end
end

function local_mkdir(dirPath)
if ~exist(dirPath, "dir")
    mkdir(dirPath);
end
end

function local_print_summary(summaryStruct)
names = string(fieldnames(summaryStruct));
for idx = 1:numel(names)
    s = summaryStruct.(names(idx));
    fprintf("[RU-SINGLE] summary %-18s pass=%d/%d maxPER=%.4g maxRawPER=%.4g maxBurst=%.3fs maxElapsed=%.3fs\n", ...
        char(s.suite), s.nPass, s.nCases, s.maxPer, s.maxRawPer, s.maxBurstSec, s.maxElapsedSec);
end
end
