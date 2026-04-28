function summary = validate_robust_unified_mixed_badpoints(varargin)
%VALIDATE_ROBUST_UNIFIED_MIXED_BADPOINTS Stress mixed-interference badpoints for robust_unified.

opts = local_parse_inputs(varargin{:});
repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

outRoot = fullfile(char(opts.ResultsRoot), char(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

rows = repmat(local_empty_row(), 0, 1);

if any(opts.Suites == "narrowband_rayleigh")
    suiteRows = local_run_narrowband_rayleigh_suite(opts, outRoot);
    rows = [rows; suiteRows(:)]; %#ok<AGROW>
end
if any(opts.Suites == "all_three")
    suiteRows = local_run_all_three_suite(opts, outRoot);
    rows = [rows; suiteRows(:)]; %#ok<AGROW>
end

summary = struct2table(rows);
writetable(summary, fullfile(outRoot, "summary.csv"));
save(fullfile(outRoot, "summary.mat"), "summary", "opts");
local_print_summary_local(summary);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "validate_robust_unified_mixed_badpoints";
addParameter(p, "Suites", ["narrowband_rayleigh" "all_three"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "EbN0dB", 6, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "JsrDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NFramesPerPoint", 1, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "BurstThresholdSec", 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "ElapsedThresholdSec", 600, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "SaveFullResults", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results", "validate_robust_unified_mixed_badpoints"), @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", "robust_unified_mixed_badpoints_" + string(datetime("now", "Format", "yyyyMMdd_HHmmss")), @(x) ischar(x) || isstring(x));
addParameter(p, "NarrowbandCenters", -4:0.5:4, @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "StressCenters", [-0.5 0.5], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "ImpulseProb", 0.03, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0 && x <= 1);
addParameter(p, "RayleighDelayCases", { ...
    [0 1 4], ...
    [0 2 4], ...
    [0 3 4]}, @(x) iscell(x) && ~isempty(x));
addParameter(p, "RayleighGainCases", { ...
    [0 -8 -14], ...
    [0 -6 -10], ...
    [0 -6 -12]}, @(x) iscell(x) && ~isempty(x));
addParameter(p, "RayleighCaseLabels", ["d014_g0m8m14" "d024_g0m6m10" "d034_g0m6m12"], ...
    @(x) isstring(x) || ischar(x) || iscellstr(x));
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
if numel(opts.RayleighCaseLabels) ~= numel(opts.RayleighDelayCases)
    error("RayleighCaseLabels must match RayleighDelayCases length.");
end
end

function rows = local_run_narrowband_rayleigh_suite(opts, outRoot)
suiteRoot = fullfile(outRoot, "narrowband_rayleigh");
if ~exist(suiteRoot, "dir")
    mkdir(suiteRoot);
end

centers = double(opts.NarrowbandCenters(:).');
rows = repmat(local_empty_row(), numel(centers), 1);

for idx = 1:numel(centers)
    center = centers(idx);
    row = local_empty_row();
    row.suite = "narrowband_rayleigh";
    row.caseName = sprintf("center_%+0.1f_d024", center);
    row.paramAText = "centerFreqPoints";
    row.paramA = center;
    row.paramBText = "pathCase";
    row.paramBLabel = "d024_g0m6m10";
    row.runDir = string(fullfile(suiteRoot, char(row.caseName)));

    spec = local_base_spec(opts, row.runDir);
    spec = local_enable_narrowband_local(spec, center);
    spec = local_enable_rayleigh_local(spec, [0 2 4], [0 -6 -10]);

    rows(idx) = local_run_single_case(spec, row, opts);
end
end

function rows = local_run_all_three_suite(opts, outRoot)
suiteRoot = fullfile(outRoot, "all_three");
if ~exist(suiteRoot, "dir")
    mkdir(suiteRoot);
end

centers = double(opts.StressCenters(:).');
nPaths = numel(opts.RayleighDelayCases);
rows = repmat(local_empty_row(), numel(centers) * nPaths, 1);
rowIdx = 0;

for centerIdx = 1:numel(centers)
    center = centers(centerIdx);
    for pathIdx = 1:nPaths
        delays = double(opts.RayleighDelayCases{pathIdx}(:).');
        gains = double(opts.RayleighGainCases{pathIdx}(:).');
        label = opts.RayleighCaseLabels(pathIdx);

        rowIdx = rowIdx + 1;
        row = local_empty_row();
        row.suite = "all_three";
        row.caseName = sprintf("center_%+0.1f_%s", center, char(label));
        row.paramAText = "centerFreqPoints";
        row.paramA = center;
        row.paramBText = "pathCase";
        row.paramBLabel = label;
        row.runDir = string(fullfile(suiteRoot, char(row.caseName)));

        spec = local_base_spec(opts, row.runDir);
        spec = local_enable_impulse_local(spec, double(opts.ImpulseProb));
        spec = local_enable_narrowband_local(spec, center);
        spec = local_enable_rayleigh_local(spec, delays, gains);

        rows(rowIdx) = local_run_single_case(spec, row, opts);
    end
end
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

% Lock to the current fixed path under test.
spec.profileRx.cfg.mitigation.robustMixed.narrowbandFrontend = "fh_erasure";
spec.profileRx.cfg.mitigation.robustMixed.enableFhSubbandExcision = false;
spec.profileRx.cfg.mitigation.robustMixed.enableScFdeNbiCancel = false;
spec.profileRx.cfg.mitigation.robustMixed.enableSampleNbiCancel = false;
spec.profileRx.cfg.mitigation.robustMixed.enableFhReliabilityFloorWithMultipath = false;
end

function spec = local_enable_impulse_local(spec, impulseProb)
spec.channel.impulseProb = double(impulseProb);
spec.channel.impulseWeight = 1.0;
spec.channel.impulseToBgRatio = 0.0;
end

function spec = local_enable_narrowband_local(spec, center)
spec.channel.narrowband.enable = true;
spec.channel.narrowband.weight = 1.0;
spec.channel.narrowband.centerFreqPoints = double(center);
spec.channel.narrowband.bandwidthFreqPoints = local_narrowband_bandwidth_local(spec);
end

function spec = local_enable_rayleigh_local(spec, delays, gains)
spec.channel.multipath.enable = true;
spec.channel.multipath.pathDelaysSymbols = double(delays(:).');
spec.channel.multipath.pathGainsDb = double(gains(:).');
spec.channel.multipath.rayleigh = true;
end

function bw = local_narrowband_bandwidth_local(spec)
runtimeCfg = compile_runtime_config(spec);
bw = narrowband_prespread_fh_bandwidth_points(runtimeCfg.fh, runtimeCfg.waveform, runtimeCfg.dsss);
end

function row = local_run_single_case(spec, row, opts)
runDir = char(row.runDir);
if ~exist(runDir, "dir")
    mkdir(runDir);
end

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
    fprintf("[RU-MIX-BAD] %-18s %-28s PER=%.4g rawPER=%.4g phy=%.4g pktSess=%.4g payload=%.4g burst=%.3fs elapsed=%.3fs pass=%d\n", ...
        char(row.suite), char(row.caseName), row.per, row.rawPer, row.phyHeaderSuccess, ...
        row.packetSessionSuccess, row.payloadSuccess, row.burstSec, row.elapsedSec, row.pass);
catch ME
    row.errorMessage = string(ME.message);
    fprintf("[RU-MIX-BAD] %-18s %-28s FAILED: %s\n", ...
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
    "paramBLabel", "", ...
    "runDir", "", ...
    "errorMessage", "");
end

function local_print_summary_local(summary)
if isempty(summary)
    fprintf("[RU-MIX-BAD] summary: no rows.\n");
    return;
end
suiteNames = unique(string(summary.suite(:).'), "stable");
for suiteName = suiteNames
    use = string(summary.suite) == suiteName;
    tbl = summary(use, :);
    nRunOk = nnz(tbl.runOk);
    nPass = nnz(tbl.pass);
    maxPer = max(tbl.per(tbl.runOk), [], "omitnan");
    maxRaw = max(tbl.rawPer(tbl.runOk), [], "omitnan");
    maxElapsed = max(tbl.elapsedSec(tbl.runOk), [], "omitnan");
    fprintf("[RU-MIX-BAD] summary %-18s pass=%d/%d runOk=%d maxPER=%.4g maxRawPER=%.4g maxElapsed=%.3fs\n", ...
        char(suiteName), nPass, height(tbl), nRunOk, maxPer, maxRaw, maxElapsed);
end
end
