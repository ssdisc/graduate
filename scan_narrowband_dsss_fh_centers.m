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
    row.method = "narrowband_notch_soft";

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
    cfg.profileRx.cfg.methods = "narrowband_notch_soft";
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
        save(fullfile(runDir, 'results.mat'), 'results');
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
addParameter(p, 'ResultsRoot', fullfile(pwd, 'results'), @(x) ischar(x) || isstring(x));
addParameter(p, 'Tag', string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')), @(x) ischar(x) || isstring(x));
parse(p, varargin{:});
opts = p.Results;
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
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
