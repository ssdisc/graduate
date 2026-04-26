function report = validate_three_links_6db(varargin)
%VALIDATE_THREE_LINKS_6DB  Acceptance validation for the refactored three-link design.
%
% Default behavior:
%   - Coverage validation only
%   - Eb/N0 = 6 dB, JSR = 0 dB
%   - Primary receiver chain only for runtime-constrained pass/fail
%
% Optional behavior:
%   - RunConfidence=true  : selected 3-frame rechecks
%   - RunResearchChecks=true : baseline/improvement comparisons
%
% Example:
%   report = validate_three_links_6db();
%   report = validate_three_links_6db("RunConfidence", true, "Profiles", ["impulse" "narrowband"]);

opts = local_parse_inputs(varargin{:});
repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, 'src')));

outRoot = fullfile(char(opts.ResultsRoot), "validate_three_links_6db", char(opts.Tag));
if ~exist(outRoot, 'dir')
    mkdir(outRoot);
end

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.outRoot = string(outRoot);
report.opts = opts;
report.coverage = struct();
report.confidence = struct();
report.research = struct();
report.summary = struct();

if any(opts.Profiles == "impulse")
    [report.coverage.impulse, report.summary.impulseCoverage] = local_run_impulse_coverage(opts, outRoot);
    if opts.RunConfidence
        [report.confidence.impulse, report.summary.impulseConfidence] = local_run_impulse_confidence(opts, outRoot);
    end
    if opts.RunResearchChecks
        [report.research.impulse, report.summary.impulseResearch] = local_run_impulse_research(opts, outRoot);
    end
end

if any(opts.Profiles == "narrowband")
    [report.coverage.narrowband, report.summary.narrowbandCoverage] = local_run_narrowband_coverage(opts, outRoot);
    if opts.RunConfidence
        [report.confidence.narrowband, report.summary.narrowbandConfidence] = local_run_narrowband_confidence(opts, outRoot);
    end
    if opts.RunResearchChecks
        [report.research.narrowband, report.summary.narrowbandResearch] = local_run_narrowband_research(opts, outRoot);
    end
end

if any(opts.Profiles == "rayleigh_multipath")
    [report.coverage.rayleigh_multipath, report.summary.rayleighCoverage] = local_run_rayleigh_coverage(opts, outRoot);
    if opts.RunConfidence
        [report.confidence.rayleigh_multipath, report.summary.rayleighConfidence] = local_run_rayleigh_confidence(opts, outRoot);
    end
    if opts.RunResearchChecks
        [report.research.rayleigh_multipath, report.summary.rayleighResearch] = local_run_rayleigh_research(opts, outRoot);
    end
end

save(fullfile(outRoot, 'report.mat'), 'report');
local_print_top_summary(report);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = 'validate_three_links_6db';
addParameter(p, 'Profiles', ["impulse" "narrowband" "rayleigh_multipath"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, 'EbN0', 6, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, 'JsrDb', 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, 'MaxBurstSec', 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, 'MaxElapsedSec', 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, 'RunConfidence', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'RunResearchChecks', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'SaveFigures', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'ResultsRoot', fullfile(pwd, 'results'), @(x) ischar(x) || isstring(x));
addParameter(p, 'Tag', string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')), @(x) ischar(x) || isstring(x));
parse(p, varargin{:});
opts = p.Results;
opts.Profiles = unique(string(opts.Profiles(:).'), 'stable');
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
end

function [tbl, summary] = local_run_impulse_coverage(opts, outRoot)
probs = [0.01 0.03 0.05];
ratios = [20 50 80];
rows = repmat(local_empty_primary_row(), 0, 1);
suiteRoot = fullfile(outRoot, 'impulse_coverage');
local_mkdir(suiteRoot);

for ip = 1:numel(probs)
    for ir = 1:numel(ratios)
        prob = probs(ip);
        ratio = ratios(ir);
        caseName = sprintf('prob_%0.2f_ratio_%d', prob, ratio);
        cfg = local_base_profile_cfg("impulse", opts, 1, "blanking", fullfile(suiteRoot, caseName));
        cfg.channel.impulseProb = prob;
        cfg.channel.impulseWeight = 1.0;
        cfg.channel.impulseToBgRatio = ratio;
        row = local_run_primary_case(cfg, "blanking", opts, "impulse", "coverage", caseName);
        row.paramA = prob;
        row.paramB = ratio;
        row.paramAText = "impulseProb";
        row.paramBText = "impulseToBgRatio";
        rows(end + 1, 1) = row; %#ok<AGROW>
    end
end

tbl = struct2table(rows);
writetable(tbl, fullfile(suiteRoot, 'summary.csv'));
summary = local_build_pass_summary(tbl, "impulse coverage");
end

function [tbl, summary] = local_run_impulse_confidence(opts, outRoot)
caseList = [0.03 50; 0.05 80];
rows = repmat(local_empty_primary_row(), 0, 1);
suiteRoot = fullfile(outRoot, 'impulse_confidence');
local_mkdir(suiteRoot);

for idx = 1:size(caseList, 1)
    prob = caseList(idx, 1);
    ratio = caseList(idx, 2);
    caseName = sprintf('prob_%0.2f_ratio_%d_f3', prob, round(ratio));
    cfg = local_base_profile_cfg("impulse", opts, 3, "blanking", fullfile(suiteRoot, caseName));
    cfg.channel.impulseProb = prob;
    cfg.channel.impulseWeight = 1.0;
    cfg.channel.impulseToBgRatio = ratio;
    row = local_run_primary_case(cfg, "blanking", opts, "impulse", "confidence", caseName);
    row.paramA = prob;
    row.paramB = ratio;
    row.paramAText = "impulseProb";
    row.paramBText = "impulseToBgRatio";
    rows(end + 1, 1) = row; %#ok<AGROW>
end

tbl = struct2table(rows);
writetable(tbl, fullfile(suiteRoot, 'summary.csv'));
summary = local_build_pass_summary(tbl, "impulse confidence");
end

function [tbl, summary] = local_run_impulse_research(opts, outRoot)
caseList = [0.03 50 0.50; 0.05 80 0.30];
rows = repmat(local_empty_compare_row(), 0, 1);
suiteRoot = fullfile(outRoot, 'impulse_research');
local_mkdir(suiteRoot);

for idx = 1:size(caseList, 1)
    prob = caseList(idx, 1);
    ratio = caseList(idx, 2);
    minImprove = caseList(idx, 3);
    caseName = sprintf('prob_%0.2f_ratio_%d_compare', prob, round(ratio));
    cfg = local_base_profile_cfg("impulse", opts, 1, ["none" "blanking"], fullfile(suiteRoot, caseName));
    cfg.channel.impulseProb = prob;
    cfg.channel.impulseWeight = 1.0;
    cfg.channel.impulseToBgRatio = ratio;
    row = local_run_compare_case(cfg, "none", "blanking", opts, "impulse", "research", caseName);
    row.paramA = prob;
    row.paramB = ratio;
    row.paramAText = "impulseProb";
    row.paramBText = "impulseToBgRatio";
    row.minImprovement = minImprove;
    row.pass = row.runOk && row.improvement >= minImprove;
    rows(end + 1, 1) = row; %#ok<AGROW>
end

tbl = struct2table(rows);
writetable(tbl, fullfile(suiteRoot, 'summary.csv'));
summary = local_build_pass_summary(tbl, "impulse research");
end

function [tbl, summary] = local_run_narrowband_coverage(opts, outRoot)
baseCenters = -3:0.5:3;
baseBw = 1.0;
extraCenters = [-2.5 0 2.5];
extraBw = [0.5 1.0 1.5];
pairs = [baseCenters(:), baseBw * ones(numel(baseCenters), 1)];
for ibw = 1:numel(extraBw)
    for ic = 1:numel(extraCenters)
        pairs(end + 1, :) = [extraCenters(ic) extraBw(ibw)]; %#ok<AGROW>
    end
end
pairs = unique(round(pairs, 9), 'rows', 'stable');

rows = repmat(local_empty_primary_row(), 0, 1);
suiteRoot = fullfile(outRoot, 'narrowband_coverage');
local_mkdir(suiteRoot);

for idx = 1:size(pairs, 1)
    center = pairs(idx, 1);
    bw = pairs(idx, 2);
    caseName = sprintf('center_%+0.1f_bw_%0.1f', center, bw);
    cfg = local_base_profile_cfg("narrowband", opts, 1, "narrowband_notch_soft", fullfile(suiteRoot, caseName));
    cfg.channel.narrowband.centerFreqPoints = center;
    cfg.channel.narrowband.bandwidthFreqPoints = bw;
    local_validate_narrowband_case(cfg);
    row = local_run_primary_case(cfg, "narrowband_notch_soft", opts, "narrowband", "coverage", caseName);
    row.paramA = center;
    row.paramB = bw;
    row.paramAText = "centerFreqPoints";
    row.paramBText = "bandwidthFreqPoints";
    rows(end + 1, 1) = row; %#ok<AGROW>
end

tbl = struct2table(rows);
writetable(tbl, fullfile(suiteRoot, 'summary.csv'));
summary = local_build_pass_summary(tbl, "narrowband coverage");
end

function [tbl, summary] = local_run_narrowband_confidence(opts, outRoot)
caseList = [-3 1.0; 0 1.0; 3 1.0];
rows = repmat(local_empty_primary_row(), 0, 1);
suiteRoot = fullfile(outRoot, 'narrowband_confidence');
local_mkdir(suiteRoot);

for idx = 1:size(caseList, 1)
    center = caseList(idx, 1);
    bw = caseList(idx, 2);
    caseName = sprintf('center_%+0.1f_bw_%0.1f_f3', center, bw);
    cfg = local_base_profile_cfg("narrowband", opts, 3, "narrowband_notch_soft", fullfile(suiteRoot, caseName));
    cfg.channel.narrowband.centerFreqPoints = center;
    cfg.channel.narrowband.bandwidthFreqPoints = bw;
    local_validate_narrowband_case(cfg);
    row = local_run_primary_case(cfg, "narrowband_notch_soft", opts, "narrowband", "confidence", caseName);
    row.paramA = center;
    row.paramB = bw;
    row.paramAText = "centerFreqPoints";
    row.paramBText = "bandwidthFreqPoints";
    rows(end + 1, 1) = row; %#ok<AGROW>
end

tbl = struct2table(rows);
writetable(tbl, fullfile(suiteRoot, 'summary.csv'));
summary = local_build_pass_summary(tbl, "narrowband confidence");
end

function [tbl, summary] = local_run_narrowband_research(opts, outRoot)
centers = -3:0.5:3;
rows = repmat(local_empty_compare_row(), 0, 1);
suiteRoot = fullfile(outRoot, 'narrowband_research');
local_mkdir(suiteRoot);

for idx = 1:numel(centers)
    center = centers(idx);
    caseName = sprintf('center_%+0.1f_compare', center);
    cfg = local_base_profile_cfg("narrowband", opts, 1, ["fh_erasure" "narrowband_notch_soft"], fullfile(suiteRoot, caseName));
    cfg.channel.narrowband.centerFreqPoints = center;
    cfg.channel.narrowband.bandwidthFreqPoints = 1.0;
    local_validate_narrowband_case(cfg);
    row = local_run_compare_case(cfg, "fh_erasure", "narrowband_notch_soft", opts, "narrowband", "research", caseName);
    row.paramA = center;
    row.paramB = 1.0;
    row.paramAText = "centerFreqPoints";
    row.paramBText = "bandwidthFreqPoints";
    row.minImprovement = 1e-12;
    row.pass = row.runOk && row.secondaryRawPer <= row.primaryRawPer + 1e-12;
    rows(end + 1, 1) = row; %#ok<AGROW>
end

tbl = struct2table(rows);
writetable(tbl, fullfile(suiteRoot, 'summary.csv'));
summary = local_build_pass_summary(tbl, "narrowband research");
end

function [tbl, summary] = local_run_rayleigh_coverage(opts, outRoot)
cases = local_rayleigh_cases();
rows = repmat(local_empty_primary_row(), 0, 1);
suiteRoot = fullfile(outRoot, 'rayleigh_coverage');
local_mkdir(suiteRoot);

for idx = 1:numel(cases)
    caseName = char(cases(idx).label);
    cfg = local_base_profile_cfg("rayleigh_multipath", opts, 1, "sc_fde_mmse", fullfile(suiteRoot, caseName));
    cfg.channel.multipath.pathDelaysSymbols = cases(idx).delays;
    cfg.channel.multipath.pathGainsDb = cases(idx).gains;
    row = local_run_primary_case(cfg, "sc_fde_mmse", opts, "rayleigh_multipath", "coverage", caseName);
    row.paramAText = "pathDelaysSymbols";
    row.paramBText = "pathGainsDb";
    row.paramAList = string(mat2str(cases(idx).delays));
    row.paramBList = string(mat2str(cases(idx).gains));
    rows(end + 1, 1) = row; %#ok<AGROW>
end

tbl = struct2table(rows);
writetable(tbl, fullfile(suiteRoot, 'summary.csv'));
summary = local_build_pass_summary(tbl, "rayleigh coverage");
end

function [tbl, summary] = local_run_rayleigh_confidence(opts, outRoot)
cases = local_rayleigh_cases();
rows = repmat(local_empty_primary_row(), 0, 1);
suiteRoot = fullfile(outRoot, 'rayleigh_confidence');
local_mkdir(suiteRoot);

for idx = 1:numel(cases)
    caseName = string(cases(idx).label) + "_f3";
    cfg = local_base_profile_cfg("rayleigh_multipath", opts, 3, "sc_fde_mmse", fullfile(suiteRoot, char(caseName)));
    cfg.channel.multipath.pathDelaysSymbols = cases(idx).delays;
    cfg.channel.multipath.pathGainsDb = cases(idx).gains;
    row = local_run_primary_case(cfg, "sc_fde_mmse", opts, "rayleigh_multipath", "confidence", char(caseName));
    row.paramAText = "pathDelaysSymbols";
    row.paramBText = "pathGainsDb";
    row.paramAList = string(mat2str(cases(idx).delays));
    row.paramBList = string(mat2str(cases(idx).gains));
    rows(end + 1, 1) = row; %#ok<AGROW>
end

tbl = struct2table(rows);
writetable(tbl, fullfile(suiteRoot, 'summary.csv'));
summary = local_build_pass_summary(tbl, "rayleigh confidence");
end

function [tbl, summary] = local_run_rayleigh_research(opts, outRoot)
cases = local_rayleigh_cases();
rows = repmat(local_empty_compare_row(), 0, 1);
suiteRoot = fullfile(outRoot, 'rayleigh_research');
local_mkdir(suiteRoot);

for idx = 1:numel(cases)
    cfgPrimary = local_base_profile_cfg("rayleigh_multipath", opts, 1, "sc_fde_mmse", fullfile(suiteRoot, char(string(cases(idx).label) + "_2rx")));
    cfgPrimary.channel.multipath.pathDelaysSymbols = cases(idx).delays;
    cfgPrimary.channel.multipath.pathGainsDb = cases(idx).gains;

    cfgBaseline = local_base_profile_cfg("rayleigh_multipath", opts, 1, "sc_fde_mmse", fullfile(suiteRoot, char(string(cases(idx).label) + "_1rx")));
    cfgBaseline.channel.multipath.pathDelaysSymbols = cases(idx).delays;
    cfgBaseline.channel.multipath.pathGainsDb = cases(idx).gains;
    cfgBaseline.profileRx.cfg.rxDiversity.enable = false;
    cfgBaseline.profileRx.cfg.rxDiversity.nRx = 1;

    row = local_run_dual_config_compare_case(cfgBaseline, cfgPrimary, "1rx", "2rx_branch_sc_fde", opts, "rayleigh_multipath", "research", char(cases(idx).label));
    row.paramAText = "pathDelaysSymbols";
    row.paramBText = "pathGainsDb";
    row.paramAList = string(mat2str(cases(idx).delays));
    row.paramBList = string(mat2str(cases(idx).gains));
    row.minImprovement = 0.0;
    row.pass = row.runOk && row.secondaryRawPer <= row.primaryRawPer + 1e-12;
    rows(end + 1, 1) = row; %#ok<AGROW>
end

tbl = struct2table(rows);
avgImprove = mean(tbl.improvement(tbl.runOk), 'omitnan');
avgSecondaryRawPer = mean(tbl.secondaryRawPer(tbl.runOk), 'omitnan');
if ~isempty(tbl)
    tbl.pass = tbl.pass & avgImprove >= 0.40 & avgSecondaryRawPer <= 0.40;
end
writetable(tbl, fullfile(suiteRoot, 'summary.csv'));
summary = local_build_pass_summary(tbl, "rayleigh research");
summary.avgImprovement = avgImprove;
summary.avgSecondaryRawPer = avgSecondaryRawPer;
summary.requirementAvgImprovement = 0.40;
summary.requirementAvgSecondaryRawPer = 0.40;
summary.groupPass = isfinite(avgImprove) && isfinite(avgSecondaryRawPer) && avgImprove >= 0.40 && avgSecondaryRawPer <= 0.40 && all(tbl.pass);
end

function cfg = local_base_profile_cfg(profileName, opts, nFrames, methods, resultsDir)
cfg = default_params( ...
    'linkProfileName', profileName, ...
    'strictModelLoad', false, ...
    'requireTrainedMlModels', false, ...
    'loadMlModels', strings(1, 0));
cfg.linkBudget.ebN0dBList = double(opts.EbN0);
cfg.linkBudget.jsrDbList = double(opts.JsrDb);
cfg.sim.nFramesPerPoint = double(nFrames);
cfg.sim.useParallel = false;
cfg.sim.saveFigures = logical(opts.SaveFigures);
cfg.sim.resultsDir = string(resultsDir);
cfg.commonTx.source.useBuiltinImage = true;
cfg.profileRx.cfg.methods = string(methods(:).');
end

function row = local_run_primary_case(cfg, methodName, opts, profileName, suiteName, caseName)
row = local_empty_primary_row();
row.profile = string(profileName);
row.suite = string(suiteName);
row.caseName = string(caseName);
row.method = string(methodName);
row.runDir = string(cfg.sim.resultsDir);
local_mkdir(cfg.sim.resultsDir);

try
    [results, elapsedSec] = local_run_simulation(cfg);
    m = local_extract_method_metrics(results, methodName, opts.EbN0);
    row.runOk = true;
    row.elapsedSec = elapsedSec;
    row.burstSec = double(results.tx.burstDurationSec);
    row.ber = m.ber;
    row.rawPer = m.rawPer;
    row.per = m.per;
    row.frontEndSuccess = m.frontEndSuccess;
    row.headerSuccess = m.headerSuccess;
    row.sessionSuccess = m.sessionSuccess;
    row.payloadSuccess = m.payloadSuccess;
    row.pass = local_primary_pass(row, opts);
    save(fullfile(cfg.sim.resultsDir, 'results.mat'), 'results');
    fprintf('[ACPT] %-18s %-12s %-28s elapsed=%6.2fs burst=%6.2fs rawPER=%7.4f PER=%7.4f pass=%d\n', ...
        char(profileName), char(suiteName), char(caseName), row.elapsedSec, row.burstSec, row.rawPer, row.per, row.pass);
catch ME
    row.errorMessage = string(ME.message);
    fprintf('[ACPT] %-18s %-12s %-28s FAILED: %s\n', ...
        char(profileName), char(suiteName), char(caseName), ME.message);
end
end

function row = local_run_compare_case(cfg, primaryMethod, secondaryMethod, opts, profileName, suiteName, caseName)
row = local_empty_compare_row();
row.profile = string(profileName);
row.suite = string(suiteName);
row.caseName = string(caseName);
row.primaryLabel = string(primaryMethod);
row.secondaryLabel = string(secondaryMethod);
row.runDir = string(cfg.sim.resultsDir);
local_mkdir(cfg.sim.resultsDir);

try
    [results, elapsedSec] = local_run_simulation(cfg);
    m1 = local_extract_method_metrics(results, primaryMethod, opts.EbN0);
    m2 = local_extract_method_metrics(results, secondaryMethod, opts.EbN0);
    row.runOk = true;
    row.elapsedSec = elapsedSec;
    row.burstSec = double(results.tx.burstDurationSec);
    row.primaryRawPer = m1.rawPer;
    row.secondaryRawPer = m2.rawPer;
    row.primaryPer = m1.per;
    row.secondaryPer = m2.per;
    row.improvement = local_improvement_ratio(m1.rawPer, m2.rawPer);
    save(fullfile(cfg.sim.resultsDir, 'results.mat'), 'results');
    fprintf('[ACPT] %-18s %-12s %-28s compare %s->%s rawPER %.4f -> %.4f improve=%.3f\n', ...
        char(profileName), char(suiteName), char(caseName), char(primaryMethod), char(secondaryMethod), ...
        row.primaryRawPer, row.secondaryRawPer, row.improvement);
catch ME
    row.errorMessage = string(ME.message);
    fprintf('[ACPT] %-18s %-12s %-28s FAILED: %s\n', ...
        char(profileName), char(suiteName), char(caseName), ME.message);
end
end

function row = local_run_dual_config_compare_case(cfgPrimary, cfgSecondary, primaryLabel, secondaryLabel, opts, profileName, suiteName, caseName)
row = local_empty_compare_row();
row.profile = string(profileName);
row.suite = string(suiteName);
row.caseName = string(caseName);
row.primaryLabel = string(primaryLabel);
row.secondaryLabel = string(secondaryLabel);
row.runDir = string(cfgSecondary.sim.resultsDir);
local_mkdir(cfgPrimary.sim.resultsDir);
local_mkdir(cfgSecondary.sim.resultsDir);

try
    [resPrimary, elapsedPrimary] = local_run_simulation(cfgPrimary);
    [resSecondary, elapsedSecondary] = local_run_simulation(cfgSecondary);
    mPrimary = local_extract_method_metrics(resPrimary, "sc_fde_mmse", opts.EbN0);
    mSecondary = local_extract_method_metrics(resSecondary, "sc_fde_mmse", opts.EbN0);
    row.runOk = true;
    row.elapsedSec = elapsedPrimary + elapsedSecondary;
    row.burstSec = double(resSecondary.tx.burstDurationSec);
    row.primaryRawPer = mPrimary.rawPer;
    row.secondaryRawPer = mSecondary.rawPer;
    row.primaryPer = mPrimary.per;
    row.secondaryPer = mSecondary.per;
    row.improvement = local_improvement_ratio(mPrimary.rawPer, mSecondary.rawPer);
    save(fullfile(cfgPrimary.sim.resultsDir, 'results.mat'), 'resPrimary');
    save(fullfile(cfgSecondary.sim.resultsDir, 'results.mat'), 'resSecondary');
    fprintf('[ACPT] %-18s %-12s %-28s compare %s->%s rawPER %.4f -> %.4f improve=%.3f\n', ...
        char(profileName), char(suiteName), char(caseName), char(primaryLabel), char(secondaryLabel), ...
        row.primaryRawPer, row.secondaryRawPer, row.improvement);
catch ME
    row.errorMessage = string(ME.message);
    fprintf('[ACPT] %-18s %-12s %-28s FAILED: %s\n', ...
        char(profileName), char(suiteName), char(caseName), ME.message);
end
end

function [results, elapsedSec] = local_run_simulation(cfg)
tStart = tic;
results = simulate(cfg);
elapsedSec = toc(tStart);
end

function m = local_extract_method_metrics(results, methodName, ebN0dB)
methods = string(results.methods(:));
mIdx = find(methods == string(methodName), 1, 'first');
if isempty(mIdx)
    error('Method %s not present in results.methods.', char(string(methodName)));
end
ebList = double(results.ebN0dB(:));
eIdx = find(abs(ebList - double(ebN0dB)) < 1e-9, 1, 'first');
if isempty(eIdx)
    error('Eb/N0 %.6g dB not present in results.ebN0dB.', ebN0dB);
end
bob = results.packetDiagnostics.bob;
m = struct();
m.ber = double(results.ber(mIdx, eIdx));
m.rawPer = double(results.rawPer(mIdx, eIdx));
m.per = double(results.per(mIdx, eIdx));
m.frontEndSuccess = double(bob.frontEndSuccessRateByMethod(mIdx, eIdx));
m.headerSuccess = double(bob.headerSuccessRateByMethod(mIdx, eIdx));
m.sessionSuccess = double(bob.sessionSuccessRateByMethod(mIdx, eIdx));
m.payloadSuccess = double(bob.payloadSuccessRate(mIdx, eIdx));
end

function pass = local_primary_pass(row, opts)
pass = row.runOk ...
    && isfinite(row.per) && row.per <= 1e-12 ...
    && isfinite(row.sessionSuccess) && row.sessionSuccess >= 1 - 1e-12 ...
    && isfinite(row.burstSec) && row.burstSec < double(opts.MaxBurstSec) ...
    && isfinite(row.elapsedSec) && row.elapsedSec < double(opts.MaxElapsedSec);
end

function ratio = local_improvement_ratio(beforeVal, afterVal)
if ~(isfinite(beforeVal) && isfinite(afterVal))
    ratio = NaN;
    return;
end
if beforeVal <= 0
    ratio = double(afterVal <= beforeVal);
    return;
end
ratio = max(min((beforeVal - afterVal) / beforeVal, 1), -inf);
end

function local_validate_narrowband_case(cfg)
runtimeCfg = compile_runtime_config(cfg);
waveform = resolve_waveform_cfg(runtimeCfg);
[maxAbsCenter, ~] = narrowband_center_freq_points_limit(runtimeCfg.fh, waveform, cfg.channel.narrowband.bandwidthFreqPoints);
center = double(cfg.channel.narrowband.centerFreqPoints);
if abs(center) > maxAbsCenter + 1e-9
    error('Invalid narrowband center %.6g for bw %.6g. Max |center| is %.6g.', ...
        center, double(cfg.channel.narrowband.bandwidthFreqPoints), maxAbsCenter);
end
end

function cases = local_rayleigh_cases()
cases = struct( ...
    'label', {"d012_g0m6m10", "d024_g0m6m10", "d014_g0m8m14", "d034_g0m6m12"}, ...
    'delays', {[0 1 2], [0 2 4], [0 1 4], [0 3 4]}, ...
    'gains', {[0 -6 -10], [0 -6 -10], [0 -8 -14], [0 -6 -12]});
end

function row = local_empty_primary_row()
row = struct( ...
    'profile', "", ...
    'suite', "", ...
    'caseName', "", ...
    'method', "", ...
    'runDir', "", ...
    'runOk', false, ...
    'errorMessage', "", ...
    'paramAText', "", ...
    'paramBText', "", ...
    'paramA', NaN, ...
    'paramB', NaN, ...
    'paramAList', "", ...
    'paramBList', "", ...
    'elapsedSec', NaN, ...
    'burstSec', NaN, ...
    'ber', NaN, ...
    'rawPer', NaN, ...
    'per', NaN, ...
    'frontEndSuccess', NaN, ...
    'headerSuccess', NaN, ...
    'sessionSuccess', NaN, ...
    'payloadSuccess', NaN, ...
    'pass', false);
end

function row = local_empty_compare_row()
row = struct( ...
    'profile', "", ...
    'suite', "", ...
    'caseName', "", ...
    'primaryLabel', "", ...
    'secondaryLabel', "", ...
    'runDir', "", ...
    'runOk', false, ...
    'errorMessage', "", ...
    'paramAText', "", ...
    'paramBText', "", ...
    'paramA', NaN, ...
    'paramB', NaN, ...
    'paramAList', "", ...
    'paramBList', "", ...
    'elapsedSec', NaN, ...
    'burstSec', NaN, ...
    'primaryRawPer', NaN, ...
    'secondaryRawPer', NaN, ...
    'primaryPer', NaN, ...
    'secondaryPer', NaN, ...
    'improvement', NaN, ...
    'minImprovement', NaN, ...
    'pass', false);
end

function summary = local_build_pass_summary(tbl, suiteLabel)
summary = struct();
summary.suite = string(suiteLabel);
summary.nCases = height(tbl);
if height(tbl) == 0
    summary.nPass = 0;
    summary.maxBurstSec = NaN;
    summary.maxElapsedSec = NaN;
    summary.maxPer = NaN;
    summary.maxRawPer = NaN;
    summary.allPass = true;
    return;
end
if ismember('pass', string(tbl.Properties.VariableNames))
    summary.nPass = nnz(tbl.pass);
    summary.allPass = all(tbl.pass);
else
    summary.nPass = NaN;
    summary.allPass = false;
end
if ismember('burstSec', string(tbl.Properties.VariableNames))
    summary.maxBurstSec = max(tbl.burstSec, [], 'omitnan');
else
    summary.maxBurstSec = NaN;
end
if ismember('elapsedSec', string(tbl.Properties.VariableNames))
    summary.maxElapsedSec = max(tbl.elapsedSec, [], 'omitnan');
else
    summary.maxElapsedSec = NaN;
end
if ismember('per', string(tbl.Properties.VariableNames))
    summary.maxPer = max(tbl.per, [], 'omitnan');
elseif ismember('secondaryPer', string(tbl.Properties.VariableNames))
    summary.maxPer = max(tbl.secondaryPer, [], 'omitnan');
else
    summary.maxPer = NaN;
end
if ismember('rawPer', string(tbl.Properties.VariableNames))
    summary.maxRawPer = max(tbl.rawPer, [], 'omitnan');
elseif ismember('secondaryRawPer', string(tbl.Properties.VariableNames))
    summary.maxRawPer = max(tbl.secondaryRawPer, [], 'omitnan');
else
    summary.maxRawPer = NaN;
end
end

function local_print_top_summary(report)
fprintf('\n===== Three-Link Acceptance Summary =====\n');
summaryNames = fieldnames(report.summary);
for idx = 1:numel(summaryNames)
    s = report.summary.(summaryNames{idx});
    fprintf('%-22s pass=%d/%d allPass=%d maxPER=%.4g maxRawPER=%.4g maxBurst=%.2fs maxElapsed=%.2fs\n', ...
        char(s.suite), double(s.nPass), double(s.nCases), double(s.allPass), ...
        double(s.maxPer), double(s.maxRawPer), double(s.maxBurstSec), double(s.maxElapsedSec));
end
fprintf('results: %s\n', char(report.outRoot));
end

function local_mkdir(pathStr)
if ~(isfolder(pathStr) || exist(pathStr, 'dir'))
    mkdir(pathStr);
end
end
