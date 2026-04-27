function summary = validate_robust_unified_mixed(opts)
%VALIDATE_ROBUST_UNIFIED_MIXED Compare robust_unified under mixed single-frame interference.

arguments
    opts.EbN0dB (1,1) double {mustBeFinite} = 6
    opts.JsrDb (1,1) double {mustBeFinite} = 0
    opts.NFramesPerPoint (1,1) double {mustBeInteger, mustBePositive} = 1
    opts.BurstThresholdSec (1,1) double {mustBePositive} = 60
    opts.ElapsedThresholdSec (1,1) double {mustBePositive} = 120
    opts.SaveFullResults (1,1) logical = false
    opts.Cases (1,:) string = ["impulse_narrowband" "impulse_rayleigh" "narrowband_rayleigh" "all_three"]
    opts.Variants (1,:) string = ["baseline" "mixed_soft"]
    opts.Tag (1,1) string = "robust_unified_mixed_6db"
    opts.ResultsRoot (1,1) string = fullfile("results", "validate_robust_unified_mixed")
end

addpath(genpath("src"));

cases = string(opts.Cases);
variants = string(opts.Variants);
outRoot = fullfile(string(opts.ResultsRoot), string(opts.Tag) + "_" + string(datetime("now", "Format", "yyyyMMdd_HHmmss")));
if ~exist(char(outRoot), "dir")
    mkdir(char(outRoot));
end

rows = repmat(local_empty_row_local(), numel(cases) * numel(variants), 1);
rowIdx = 0;
for caseIdx = 1:numel(cases)
    caseName = cases(caseIdx);
    for variantIdx = 1:numel(variants)
        variantName = variants(variantIdx);
        rowIdx = rowIdx + 1;
        runDir = fullfile(outRoot, caseName, variantName);
        if ~exist(char(runDir), "dir")
            mkdir(char(runDir));
        end

        row = local_empty_row_local();
        row.caseIndex = caseIdx;
        row.caseName = caseName;
        row.variant = variantName;
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
            spec = local_apply_variant_local(spec, variantName);

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
            local_save_case_artifact_local(runDir, row, spec, results, elapsedSec, opts);
        catch ME
            row.runOk = false;
            row.errorMessage = string(ME.message);
        end

        rows(rowIdx) = row;
        fprintf("[ROBUST-MIXED] %-20s %-10s runOk=%d pass=%d PER=%.4g rawPER=%.4g burst=%.3fs elapsed=%.3fs\n", ...
            char(row.caseName), char(row.variant), row.runOk, row.pass, row.per, row.rawPer, row.burstSec, row.elapsedSec);
        if strlength(row.errorMessage) > 0
            fprintf("[ROBUST-MIXED]   error: %s\n", row.errorMessage);
        end
    end
end

summary = struct2table(rows);
writetable(summary, fullfile(outRoot, "summary.csv"));
save(fullfile(outRoot, "summary.mat"), "summary");
fprintf("[ROBUST-MIXED] summary: %s\n", fullfile(outRoot, "summary.csv"));
end

function spec = local_apply_variant_local(spec, variantName)
variantName = lower(string(variantName));
switch variantName
    case "baseline"
        % Keep the active robust_unified default processing chain unchanged.
    case "mixed_soft"
        spec.profileRx.cfg.mitigation.robustMixed.enableFhSubbandExcision = true;
        spec.profileRx.cfg.mitigation.robustMixed.enableSampleNbiCancel = true;
        spec.profileRx.cfg.mitigation.robustMixed.enableScFdeNbiCancel = true;
        spec.profileRx.cfg.mitigation.robustMixed.enableFhReliabilityFloorWithMultipath = true;
    otherwise
        error("Unknown robust_unified mixed validation variant: %s.", char(variantName));
end
end

function spec = local_apply_case_channel_local(spec, caseName)
caseName = lower(string(caseName));
spec.channel.impulseProb = 0.0;
spec.channel.impulseWeight = 0.0;
spec.channel.impulseToBgRatio = 0.0;
spec.channel.narrowband.enable = false;
spec.channel.narrowband.weight = 0.0;
spec.channel.narrowband.centerFreqPoints = 0;
spec.channel.narrowband.bandwidthFreqPoints = local_robust_unified_narrowband_bandwidth_local(spec);
spec.channel.multipath.enable = false;
spec.channel.multipath.pathDelaysSymbols = [0 2 4];
spec.channel.multipath.pathGainsDb = [0 -6 -10];
spec.channel.multipath.rayleigh = true;

switch caseName
    case "impulse_narrowband"
        spec = local_enable_impulse_local(spec);
        spec = local_enable_narrowband_local(spec);
    case "impulse_rayleigh"
        spec = local_enable_impulse_local(spec);
        spec = local_enable_rayleigh_local(spec);
    case "narrowband_rayleigh"
        spec = local_enable_narrowband_local(spec);
        spec = local_enable_rayleigh_local(spec);
    case "all_three"
        spec = local_enable_impulse_local(spec);
        spec = local_enable_narrowband_local(spec);
        spec = local_enable_rayleigh_local(spec);
    otherwise
        error("Unknown robust_unified mixed validation case: %s.", char(caseName));
end
end

function spec = local_enable_impulse_local(spec)
spec.channel.impulseProb = 0.03;
spec.channel.impulseWeight = 1.0;
end

function spec = local_enable_narrowband_local(spec)
spec.channel.narrowband.enable = true;
spec.channel.narrowband.weight = 1.0;
spec.channel.narrowband.centerFreqPoints = 0;
spec.channel.narrowband.bandwidthFreqPoints = local_robust_unified_narrowband_bandwidth_local(spec);
end

function spec = local_enable_rayleigh_local(spec)
spec.channel.multipath.enable = true;
spec.channel.multipath.pathDelaysSymbols = [0 2 4];
spec.channel.multipath.pathGainsDb = [0 -6 -10];
spec.channel.multipath.rayleigh = true;
end

function bw = local_robust_unified_narrowband_bandwidth_local(spec)
runtimeCfg = compile_runtime_config(spec);
bw = narrowband_prespread_fh_bandwidth_points(runtimeCfg.fh, runtimeCfg.waveform, runtimeCfg.dsss);
end

function local_save_case_artifact_local(runDir, row, spec, results, elapsedSec, opts)
if logical(opts.SaveFullResults)
    save(fullfile(runDir, "results.mat"), "results", "spec", "elapsedSec", "-v7.3");
    return;
end
caseResult = row;
caseResult.savedFullResults = false;
caseResult.methods = string(results.methods(:).');
caseResult.txSummary = struct("burstDurationSec", double(results.tx.burstDurationSec));
caseResult.elapsedSec = elapsedSec;
save(fullfile(runDir, "case_result.mat"), "caseResult", "spec");
end

function row = local_empty_row_local()
row = struct( ...
    "caseIndex", NaN, ...
    "caseName", "", ...
    "variant", "", ...
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
