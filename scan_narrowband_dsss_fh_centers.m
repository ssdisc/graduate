function report = scan_narrowband_dsss_fh_centers(varargin)
%SCAN_NARROWBAND_DSSS_FH_CENTERS Scan narrowband centers for the DSSS+FH profile.
%
% The scan uses the reconstructed narrowband profile with payload DSSS,
% chaotic FH, and no payload diversity. It runs one full 256-long-edge image
% frame per center by default.

opts = local_parse_inputs_local(varargin{:});
repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, 'src')));

outRoot = fullfile(char(opts.ResultsRoot), "scan_narrowband_dsss_fh", char(opts.Tag));
if ~exist(outRoot, 'dir')
    mkdir(outRoot);
end

centers = double(opts.Centers(:).');
rows = repmat(local_empty_row_local(), numel(centers), 1);

for idx = 1:numel(centers)
    center = centers(idx);
    caseName = sprintf("center_%+0.1f_bw_%0.1f", center, double(opts.Bandwidth));
    runDir = fullfile(outRoot, char(caseName));
    if ~exist(runDir, 'dir')
        mkdir(runDir);
    end

    row = local_empty_row_local();
    row.centerFreqPoints = center;
    row.bandwidthFreqPoints = double(opts.Bandwidth);
    row.runDir = string(runDir);
    row.method = string(opts.Method);

    cfg = default_params( ...
        "linkProfileName", "narrowband", ...
        "loadMlModels", strings(1, 0), ...
        "strictModelLoad", false, ...
        "requireTrainedMlModels", false);
    cfg.linkBudget.ebN0dBList = double(opts.EbN0);
    cfg.linkBudget.jsrDbList = double(opts.JsrDb);
    cfg.sim.nFramesPerPoint = double(opts.NFrames);
    cfg.sim.useParallel = false;
    cfg.sim.saveFigures = false;
    cfg.sim.resultsDir = string(runDir);
    cfg.profileRx.cfg.methods = string(opts.Method);
    if strlength(opts.ResidualModelPath) > 0
        s = load(char(opts.ResidualModelPath), 'model');
        if ~(isfield(s, 'model') && isstruct(s.model))
            error("ResidualModelPath must contain a struct variable named model.");
        end
        if ~isnan(opts.ResidualApplyGain)
            s.model.applyGain = double(opts.ResidualApplyGain);
        end
        if ~isnan(opts.ResidualMaxResidualNorm)
            s.model.maxResidualNorm = double(opts.ResidualMaxResidualNorm);
        end
        cfg.extensions.ml.preloaded.narrowbandResidual = s.model;
    end
    cfg.channel.narrowband.centerFreqPoints = center;
    cfg.channel.narrowband.bandwidthFreqPoints = double(opts.Bandwidth);

    try
        local_validate_center_support_local(cfg);
        tStart = tic;
        results = simulate(cfg);
        row.elapsedSec = toc(tStart);
        row.runOk = true;
        row.burstSec = double(results.tx.burstDurationSec);
        row.ber = double(results.ber(1, 1));
        row.rawPer = double(results.rawPer(1, 1));
        row.per = double(results.per(1, 1));
        row.frontEndSuccess = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(1, 1));
        row.headerSuccess = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(1, 1));
        row.sessionSuccess = double(results.packetDiagnostics.bob.sessionSuccessRateByMethod(1, 1));
        row.payloadSuccess = double(results.packetDiagnostics.bob.payloadSuccessRate(1, 1));
        row.pass = row.per <= double(opts.MaxPer) ...
            && row.burstSec < double(opts.MaxBurstSec) ...
            && row.elapsedSec < double(opts.MaxElapsedSec);
        local_save_case_artifact_local(runDir, results, row, cfg, opts);
        fprintf('[NB-DSSS-FH] %s elapsed=%6.2fs burst=%6.2fs rawPER=%7.4f PER=%7.4f pass=%d\n', ...
            char(caseName), row.elapsedSec, row.burstSec, row.rawPer, row.per, row.pass);
    catch ME
        row.errorMessage = string(ME.message);
        fprintf('[NB-DSSS-FH] %s FAILED: %s\n', char(caseName), ME.message);
    end

    rows(idx) = row;
end

tbl = struct2table(rows);
writetable(tbl, fullfile(outRoot, 'summary.csv'));

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.outRoot = string(outRoot);
report.opts = opts;
report.summaryTable = tbl;
report.summary = local_summary_local(tbl);
save(fullfile(outRoot, 'report.mat'), 'report');
disp(report.summary);
end

function opts = local_parse_inputs_local(varargin)
p = inputParser();
p.FunctionName = 'scan_narrowband_dsss_fh_centers';
addParameter(p, 'Centers', -3:0.5:3, @(x) isnumeric(x) && isvector(x));
addParameter(p, 'Bandwidth', 1.0, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, 'EbN0', 6, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, 'JsrDb', 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, 'NFrames', 1, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, 'MaxPer', 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 0);
addParameter(p, 'MaxBurstSec', 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, 'MaxElapsedSec', 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, 'Method', "fh_erasure", @(x) ischar(x) || isstring(x));
addParameter(p, 'ResidualModelPath', "", @(x) ischar(x) || isstring(x));
addParameter(p, 'ResidualApplyGain', NaN, @(x) isscalar(x) && isnumeric(x) && (isnan(x) || (isfinite(x) && x >= 0 && x <= 1)));
addParameter(p, 'ResidualMaxResidualNorm', NaN, @(x) isscalar(x) && isnumeric(x) && (isnan(x) || (isfinite(x) && x > 0)));
addParameter(p, 'SaveFullResults', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'ResultsRoot', fullfile(pwd, 'results'), @(x) ischar(x) || isstring(x));
addParameter(p, 'Tag', string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')), @(x) ischar(x) || isstring(x));
parse(p, varargin{:});
opts = p.Results;
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
opts.Method = string(opts.Method);
if ~isscalar(opts.Method) || strlength(opts.Method) == 0
    error("scan_narrowband_dsss_fh_centers: Method must be a non-empty scalar string.");
end
opts.ResidualModelPath = string(opts.ResidualModelPath);
opts.SaveFullResults = logical(opts.SaveFullResults);
if ~isscalar(opts.ResidualModelPath)
    error("scan_narrowband_dsss_fh_centers: ResidualModelPath must be a scalar string.");
end
end

function local_save_case_artifact_local(runDir, results, row, cfg, opts)
if logical(opts.SaveFullResults)
    save(fullfile(runDir, 'results.mat'), 'results', 'row', 'cfg', '-v7.3');
    return;
end

caseResult = struct();
caseResult.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
caseResult.row = row;
caseResult.cfgSummary = local_cfg_summary_local(cfg);
caseResult.methods = string(results.methods(:).');
caseResult.ebN0dB = double(results.ebN0dB(:).');
caseResult.jsrDb = double(results.jsrDb(:).');
caseResult.ber = double(results.ber);
caseResult.rawPer = double(results.rawPer);
caseResult.per = double(results.per);
caseResult.burstDurationSec = double(results.tx.burstDurationSec);
caseResult.packetDiagnostics = local_packet_diag_summary_local(results);
save(fullfile(runDir, 'case_result.mat'), 'caseResult');
end

function cfgSummary = local_cfg_summary_local(cfg)
cfgSummary = struct();
cfgSummary.linkProfileName = string(cfg.linkProfileName);
cfgSummary.ebN0dBList = double(cfg.linkBudget.ebN0dBList);
cfgSummary.jsrDbList = double(cfg.linkBudget.jsrDbList);
cfgSummary.nFramesPerPoint = double(cfg.sim.nFramesPerPoint);
cfgSummary.methods = string(cfg.profileRx.cfg.methods(:).');
cfgSummary.narrowband = cfg.channel.narrowband;
if isfield(cfg, 'profileTx') && isfield(cfg.profileTx, 'cfg')
    cfgSummary.profileTxCfg = cfg.profileTx.cfg;
end
end

function diagSummary = local_packet_diag_summary_local(results)
diagSummary = struct();
if ~(isfield(results, 'packetDiagnostics') && isfield(results.packetDiagnostics, 'bob'))
    return;
end
bob = results.packetDiagnostics.bob;
fields = ["frontEndSuccessRateByMethod" "headerSuccessRateByMethod" ...
    "sessionSuccessRateByMethod" "payloadSuccessRate"];
for idx = 1:numel(fields)
    name = char(fields(idx));
    if isfield(bob, name)
        diagSummary.(name) = double(bob.(name));
    end
end
end

function local_validate_center_support_local(cfg)
runtimeCfg = compile_runtime_config(cfg);
waveform = resolve_waveform_cfg(runtimeCfg);
[maxCenter, info] = narrowband_center_freq_points_limit(runtimeCfg.fh, waveform, runtimeCfg.channel.narrowband.bandwidthFreqPoints);
center = abs(double(runtimeCfg.channel.narrowband.centerFreqPoints));
if center > maxCenter
    error("narrowband center %.6g exceeds valid +/-%.6g FH-point range for bandwidth %.6g (spacingNorm %.6g).", ...
        double(runtimeCfg.channel.narrowband.centerFreqPoints), maxCenter, ...
        double(runtimeCfg.channel.narrowband.bandwidthFreqPoints), double(info.spacingNorm));
end
validate_link_profile(cfg);
end

function row = local_empty_row_local()
row = struct( ...
    "centerFreqPoints", NaN, ...
    "bandwidthFreqPoints", NaN, ...
    "method", "", ...
    "runOk", false, ...
    "pass", false, ...
    "elapsedSec", NaN, ...
    "burstSec", NaN, ...
    "ber", NaN, ...
    "rawPer", NaN, ...
    "per", NaN, ...
    "frontEndSuccess", NaN, ...
    "headerSuccess", NaN, ...
    "sessionSuccess", NaN, ...
    "payloadSuccess", NaN, ...
    "runDir", "", ...
    "errorMessage", "");
end

function summary = local_summary_local(tbl)
summary = struct();
summary.nCases = height(tbl);
summary.nRunOk = sum(tbl.runOk);
summary.nPass = sum(tbl.pass);
summary.maxElapsedSec = max(tbl.elapsedSec, [], 'omitnan');
summary.maxBurstSec = max(tbl.burstSec, [], 'omitnan');
summary.maxPer = max(tbl.per, [], 'omitnan');
summary.maxRawPer = max(tbl.rawPer, [], 'omitnan');
summary.minHeaderSuccess = min(tbl.headerSuccess, [], 'omitnan');
summary.minSessionSuccess = min(tbl.sessionSuccess, [], 'omitnan');
summary.minPayloadSuccess = min(tbl.payloadSuccess, [], 'omitnan');
end
