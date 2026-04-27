function report = sweep_profile_ebn0(varargin)
%SWEEP_PROFILE_EBN0 Run thesis-oriented Eb/N0 sweeps on refactored profiles.
%
% This script is intentionally profile-scoped. It does not revive the legacy
% global mitigation catalog; each profile is swept only over methods that are
% valid for that profile.

opts = local_parse_inputs(varargin{:});
repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

profiles = string(opts.Profiles(:).');
outRoot = fullfile(char(opts.ResultsRoot), "sweep_profile_ebn0", char(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

allRows = repmat(local_empty_row(), 0, 1);
profileReports = struct();

for profileIdx = 1:numel(profiles)
    profileName = normalize_link_profile_name(profiles(profileIdx));
    runDir = fullfile(outRoot, char(profileName));
    if ~exist(runDir, "dir")
        mkdir(runDir);
    end

    cfg = default_params( ...
        "linkProfileName", profileName, ...
        "loadMlModels", strings(1, 0), ...
        "strictModelLoad", false, ...
        "requireTrainedMlModels", false);
    cfg.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
    cfg.sim.useParallel = false;
    cfg.sim.saveFigures = false;
    cfg.sim.resultsDir = string(runDir);
    cfg.linkBudget.ebN0dBList = double(opts.EbN0List(:).');
    cfg.linkBudget.jsrDbList = double(opts.JsrDb);
    cfg.profileRx.cfg.methods = local_profile_methods(profileName, opts);
    cfg = local_apply_profile_case(profileName, cfg, opts);
    cfg = local_apply_extensions(cfg, opts);

    validate_link_profile(cfg);
    fprintf("[SWEEP] profile=%s Eb/N0=%s JSR=%.2f dB methods=%s\n", ...
        char(profileName), mat2str(double(opts.EbN0List(:).')), double(opts.JsrDb), ...
        strjoin(cellstr(string(cfg.profileRx.cfg.methods)), ","));

    tStart = tic;
    results = simulate(cfg);
    elapsedSec = toc(tStart);
    save(fullfile(runDir, "results.mat"), "results", "-v7.3");

    if logical(opts.ExportTables)
        export_thesis_tables(runDir, results);
    end
    if logical(opts.MakeFigures)
        save_figures(runDir, results);
    end

    rows = local_rows_from_results(profileName, results, elapsedSec, runDir);
    allRows = [allRows; rows]; %#ok<AGROW>
    profileReports.(char(profileName)) = struct( ...
        "runDir", string(runDir), ...
        "elapsedSec", elapsedSec, ...
        "summary", local_profile_summary(rows));
end

summaryTable = struct2table(allRows);
writetable(summaryTable, fullfile(outRoot, "summary.csv"));

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.outRoot = string(outRoot);
report.opts = opts;
report.summaryTable = summaryTable;
report.profileReports = profileReports;
report.summary = local_overall_summary(summaryTable);
save(fullfile(outRoot, "report.mat"), "report");
disp(report.summary);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "sweep_profile_ebn0";
addParameter(p, "Profiles", ["impulse" "narrowband" "rayleigh_multipath"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "EbN0List", [0 2 4 6 8 10], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "JsrDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NFramesPerPoint", 3, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "ImpulseMethods", ["none" "clipping" "blanking"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "NarrowbandMethods", ["none" "fh_erasure" "narrowband_notch_soft"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "RayleighMethods", ["none" "sc_fde_mmse"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "ImpulseProb", 0.03, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0 && x <= 1);
addParameter(p, "NarrowbandCenter", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NarrowbandBandwidth", 1.0, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "RayleighDelays", [0 2 4], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "RayleighGainsDb", [0 -6 -10], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "EnableEve", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "EveLinkGainOffsetDb", -10, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "EnableWarden", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "WardenLinkGainOffsetDb", -10, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "WardenTrials", 200, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 10);
addParameter(p, "WardenObs", 4096, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 16);
addParameter(p, "ExportTables", true, @(x) islogical(x) || isnumeric(x));
addParameter(p, "MakeFigures", true, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results"), @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", string(datetime("now", "Format", "yyyyMMdd_HHmmss")), @(x) ischar(x) || isstring(x));
parse(p, varargin{:});
opts = p.Results;
opts.Profiles = string(opts.Profiles);
opts.ImpulseMethods = string(opts.ImpulseMethods);
opts.NarrowbandMethods = string(opts.NarrowbandMethods);
opts.RayleighMethods = string(opts.RayleighMethods);
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
end

function methods = local_profile_methods(profileName, opts)
switch string(profileName)
    case "impulse"
        methods = string(opts.ImpulseMethods(:).');
    case "narrowband"
        methods = string(opts.NarrowbandMethods(:).');
    case "rayleigh_multipath"
        methods = string(opts.RayleighMethods(:).');
    otherwise
        error("Unsupported profileName: %s", char(profileName));
end
end

function cfg = local_apply_profile_case(profileName, cfg, opts)
switch string(profileName)
    case "impulse"
        cfg.channel.impulseProb = double(opts.ImpulseProb);
    case "narrowband"
        cfg.channel.narrowband.centerFreqPoints = double(opts.NarrowbandCenter);
        cfg.channel.narrowband.bandwidthFreqPoints = double(opts.NarrowbandBandwidth);
        local_validate_narrowband_center(cfg);
    case "rayleigh_multipath"
        delays = double(opts.RayleighDelays(:).');
        gains = double(opts.RayleighGainsDb(:).');
        if numel(delays) ~= numel(gains)
            error("RayleighDelays and RayleighGainsDb must have the same length.");
        end
        cfg.channel.multipath.pathDelaysSymbols = delays;
        cfg.channel.multipath.pathGainsDb = gains;
    otherwise
        error("Unsupported profileName: %s", char(profileName));
end
end

function cfg = local_apply_extensions(cfg, opts)
if logical(opts.EnableEve)
    cfg.extensions.eve.enable = true;
    cfg.extensions.eve.linkGainOffsetDb = double(opts.EveLinkGainOffsetDb);
end
if logical(opts.EnableWarden)
    cfg.extensions.warden.enable = true;
    cfg.extensions.warden.warden.enable = true;
    cfg.extensions.warden.warden.linkGainOffsetDb = double(opts.WardenLinkGainOffsetDb);
    cfg.extensions.warden.warden.nTrials = double(opts.WardenTrials);
    cfg.extensions.warden.warden.nObs = double(opts.WardenObs);
    cfg.extensions.warden.warden.useParallel = false;
end
end

function local_validate_narrowband_center(cfg)
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

function rows = local_rows_from_results(profileName, results, elapsedSec, runDir)
methods = string(results.methods(:));
nMethods = numel(methods);
nPoints = numel(results.ebN0dB);
rows = repmat(local_empty_row(), nMethods * nPoints, 1);
dst = 1;
for methodIdx = 1:nMethods
    for pointIdx = 1:nPoints
        row = local_empty_row();
        row.profile = string(profileName);
        row.method = methods(methodIdx);
        row.pointIndex = pointIdx;
        row.ebN0dB = double(results.ebN0dB(pointIdx));
        row.jsrDb = double(results.jsrDb(pointIdx));
        row.ber = double(results.ber(methodIdx, pointIdx));
        row.rawPer = double(results.rawPer(methodIdx, pointIdx));
        row.per = double(results.per(methodIdx, pointIdx));
        row.frontEndSuccess = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(methodIdx, pointIdx));
        row.headerSuccess = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(methodIdx, pointIdx));
        row.sessionSuccess = double(results.packetDiagnostics.bob.sessionSuccessRateByMethod(methodIdx, pointIdx));
        row.payloadSuccess = double(results.packetDiagnostics.bob.payloadSuccessRate(methodIdx, pointIdx));
        row.burstSec = double(results.tx.burstDurationSec);
        row.elapsedSec = double(elapsedSec);
        row.runDir = string(runDir);
        row.passAt6dB = row.ebN0dB == 6 && row.per == 0 && row.burstSec < 60;
        rows(dst) = row;
        dst = dst + 1;
    end
end
end

function row = local_empty_row()
row = struct( ...
    "profile", "", ...
    "method", "", ...
    "pointIndex", NaN, ...
    "ebN0dB", NaN, ...
    "jsrDb", NaN, ...
    "ber", NaN, ...
    "rawPer", NaN, ...
    "per", NaN, ...
    "frontEndSuccess", NaN, ...
    "headerSuccess", NaN, ...
    "sessionSuccess", NaN, ...
    "payloadSuccess", NaN, ...
    "burstSec", NaN, ...
    "elapsedSec", NaN, ...
    "passAt6dB", false, ...
    "runDir", "");
end

function summary = local_profile_summary(rows)
tbl = struct2table(rows);
summary = struct();
summary.nRows = height(tbl);
summary.minBer = min(tbl.ber, [], "omitnan");
summary.maxPer = max(tbl.per, [], "omitnan");
summary.maxRawPer = max(tbl.rawPer, [], "omitnan");
summary.burstSec = max(tbl.burstSec, [], "omitnan");
summary.elapsedSec = max(tbl.elapsedSec, [], "omitnan");
end

function summary = local_overall_summary(tbl)
summary = struct();
summary.nRows = height(tbl);
summary.profiles = unique(tbl.profile, "stable").';
summary.methods = unique(tbl.method, "stable").';
summary.maxBurstSec = max(tbl.burstSec, [], "omitnan");
summary.maxElapsedSec = max(tbl.elapsedSec, [], "omitnan");
summary.maxPerAt6dB = max(tbl.per(tbl.ebN0dB == 6), [], "omitnan");
end
