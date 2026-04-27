function summary = validate_robust_unified(opts)
%VALIDATE_ROBUST_UNIFIED Validate the fourth robust_unified profile.

arguments
    opts.EbN0dB (1,1) double {mustBeFinite} = 6
    opts.JsrDb (1,1) double {mustBeFinite} = 0
    opts.NFramesPerPoint (1,1) double {mustBeInteger, mustBePositive} = 1
    opts.BurstThresholdSec (1,1) double {mustBePositive} = 60
    opts.ElapsedThresholdSec (1,1) double {mustBePositive} = 60
    opts.Tag (1,1) string = "robust_unified_6db"
    opts.ResultsRoot (1,1) string = fullfile("results", "validate_robust_unified")
end

addpath(genpath("src"));

tag = string(opts.Tag);
outRoot = fullfile(string(opts.ResultsRoot), tag + "_" + string(datetime("now", "Format", "yyyyMMdd_HHmmss")));
if ~exist(char(outRoot), "dir")
    mkdir(char(outRoot));
end

caseNames = ["impulse" "narrowband" "rayleigh_multipath"];
rows = repmat(local_empty_row_local(), numel(caseNames), 1);

for caseIdx = 1:numel(caseNames)
    caseName = caseNames(caseIdx);
    runDir = fullfile(outRoot, caseName);
    if ~exist(char(runDir), "dir")
        mkdir(char(runDir));
    end

    row = local_empty_row_local();
    row.caseIndex = caseIdx;
    row.caseName = caseName;
    row.runDir = string(runDir);

    try
        spec = default_link_spec( ...
            "linkProfileName", "robust_unified", ...
            "loadMlModels", string.empty(1, 0), ...
            "strictModelLoad", false, ...
            "requireTrainedMlModels", false);
        spec.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
        spec.sim.resultsDir = runDir;
        spec.sim.saveFigures = false;
        spec.linkBudget.ebN0dBList = double(opts.EbN0dB);
        spec.linkBudget.jsrDbList = double(opts.JsrDb);
        spec = local_apply_case_channel_local(spec, caseName);

        validate_link_profile(spec);
        tStart = tic;
        results = run_link_profile(spec);
        elapsedSec = toc(tStart);

        row.runOk = true;
        row.method = string(results.methods(1));
        row.ebN0dB = double(results.ebN0dB(1));
        row.jsrDb = double(results.jsrDb(1));
        row.elapsedSec = elapsedSec;
        row.burstSec = double(results.tx.burstDurationSec);
        row.ber = double(results.ber(1, 1));
        row.rawPer = double(results.rawPer(1, 1));
        row.per = double(results.per(1, 1));
        row.frontEndSuccess = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(1, 1));
        row.headerSuccess = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(1, 1));
        row.sessionSuccess = double(results.packetDiagnostics.bob.sessionSuccessRateByMethod(1, 1));
        row.payloadSuccess = double(results.packetDiagnostics.bob.payloadSuccessRate(1, 1));
        row.pass = row.per == 0 ...
            && row.burstSec < double(opts.BurstThresholdSec) ...
            && row.elapsedSec < double(opts.ElapsedThresholdSec);
        save(fullfile(runDir, "results.mat"), "results", "spec", "elapsedSec");
    catch ME
        row.runOk = false;
        row.errorMessage = string(ME.message);
    end

    rows(caseIdx) = row;
    fprintf("[ROBUST] %-20s runOk=%d pass=%d PER=%.4g rawPER=%.4g burst=%.3fs elapsed=%.3fs\n", ...
        char(row.caseName), row.runOk, row.pass, row.per, row.rawPer, row.burstSec, row.elapsedSec);
    if strlength(row.errorMessage) > 0
        fprintf("[ROBUST]   error: %s\n", row.errorMessage);
    end
end

summary = struct2table(rows);
writetable(summary, fullfile(outRoot, "summary.csv"));
save(fullfile(outRoot, "summary.mat"), "summary");
fprintf("[ROBUST] summary: %s\n", fullfile(outRoot, "summary.csv"));
end

function spec = local_apply_case_channel_local(spec, caseName)
caseName = string(caseName);

spec.channel.impulseProb = 0.0;
spec.channel.impulseWeight = 0.0;
spec.channel.impulseToBgRatio = 0.0;
spec.channel.narrowband.enable = false;
spec.channel.narrowband.weight = 0.0;
spec.channel.multipath.enable = false;

switch caseName
    case "impulse"
        spec.channel.impulseProb = 0.03;
        spec.channel.impulseWeight = 1.0;
    case "narrowband"
        spec.channel.narrowband.enable = true;
        spec.channel.narrowband.weight = 1.0;
        spec.channel.narrowband.centerFreqPoints = 0;
        spec.channel.narrowband.bandwidthFreqPoints = 1;
    case "rayleigh_multipath"
        spec.channel.multipath.enable = true;
        spec.channel.multipath.pathDelaysSymbols = [0 2 4];
        spec.channel.multipath.pathGainsDb = [0 -6 -10];
        spec.channel.multipath.rayleigh = true;
    otherwise
        error("Unknown robust_unified validation case: %s.", char(caseName));
end
end

function row = local_empty_row_local()
row = struct( ...
    "caseIndex", NaN, ...
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
    "headerSuccess", NaN, ...
    "sessionSuccess", NaN, ...
    "payloadSuccess", NaN, ...
    "runDir", "", ...
    "errorMessage", "");
end
