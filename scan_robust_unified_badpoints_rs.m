function report = scan_robust_unified_badpoints_rs(varargin)
%SCAN_ROBUST_UNIFIED_BADPOINTS_RS Increment RS overhead on robust_unified
%bad narrowband points until both points reach PER=0 or the case list ends.

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
report.rows = repmat(local_empty_row(), size(opts.RsCases, 1), 1);
report.firstPassIndex = NaN;

for caseIdx = 1:size(opts.RsCases, 1)
    kData = double(opts.RsCases(caseIdx, 1));
    kParity = double(opts.RsCases(caseIdx, 2));
    row = local_empty_row();
    row.caseIndex = caseIdx;
    row.rsDataPacketsPerBlock = kData;
    row.rsParityPacketsPerBlock = kParity;
    row.caseName = sprintf("rs_k%d_p%d", kData, kParity);
    row.runDir = string(fullfile(outRoot, char(row.caseName)));
    local_mkdir(char(row.runDir));

    try
        perList = nan(1, numel(opts.Centers));
        rawPerList = nan(1, numel(opts.Centers));
        headerList = nan(1, numel(opts.Centers));
        phyHeaderList = nan(1, numel(opts.Centers));
        sessionTransportList = nan(1, numel(opts.Centers));
        packetSessionList = nan(1, numel(opts.Centers));
        payloadList = nan(1, numel(opts.Centers));
        frontList = nan(1, numel(opts.Centers));
        elapsedList = nan(1, numel(opts.Centers));
        burstList = nan(1, numel(opts.Centers));
        runDirs = strings(1, numel(opts.Centers));

        for centerIdx = 1:numel(opts.Centers)
            center = double(opts.Centers(centerIdx));
            spec = local_base_spec(opts, row.runDir, center);
            spec.commonTx.outerRs.dataPacketsPerBlock = kData;
            spec.commonTx.outerRs.parityPacketsPerBlock = kParity;
            validate_link_profile(spec);

            tStart = tic;
            results = run_link_profile(spec);
            elapsedList(centerIdx) = toc(tStart);

            perList(centerIdx) = double(results.per(1, 1));
            rawPerList(centerIdx) = double(results.rawPer(1, 1));
            frontList(centerIdx) = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(1, 1));
            phyHeaderList(centerIdx) = double(results.packetDiagnostics.bob.phyHeaderSuccessRateByMethod(1, 1));
            headerList(centerIdx) = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(1, 1));
            sessionTransportList(centerIdx) = double(results.packetDiagnostics.bob.sessionTransportSuccessRateByMethod(1, 1));
            packetSessionList(centerIdx) = double(results.packetDiagnostics.bob.packetSessionSuccessRateByMethod(1, 1));
            payloadList(centerIdx) = double(results.packetDiagnostics.bob.payloadSuccessRate(1, 1));
            burstList(centerIdx) = double(results.tx.burstDurationSec);
            runDirs(centerIdx) = string(results.params.sim.resultsDir);

            local_save_case_result_local(row.runDir, center, results, spec, opts);
            fprintf("[RU-RS] case=%s center=%+.1f PER=%.4g rawPER=%.4g phy=%.4g sessTx=%.4g pktSess=%.4g payload=%.4g burst=%.3fs elapsed=%.3fs\n", ...
                char(row.caseName), center, perList(centerIdx), rawPerList(centerIdx), ...
                phyHeaderList(centerIdx), sessionTransportList(centerIdx), packetSessionList(centerIdx), ...
                payloadList(centerIdx), burstList(centerIdx), elapsedList(centerIdx));
        end

        row.runOk = true;
        row.pass = all(perList <= 0 + 1e-12);
        row.maxPer = max(perList, [], "omitnan");
        row.maxRawPer = max(rawPerList, [], "omitnan");
        row.minPhyHeaderSuccess = min(phyHeaderList, [], "omitnan");
        row.minHeaderSuccess = min(headerList, [], "omitnan");
        row.minSessionTransportSuccess = min(sessionTransportList, [], "omitnan");
        row.minPacketSessionSuccess = min(packetSessionList, [], "omitnan");
        row.minPayloadSuccess = min(payloadList, [], "omitnan");
        row.minFrontEndSuccess = min(frontList, [], "omitnan");
        row.maxElapsedSec = max(elapsedList, [], "omitnan");
        row.maxBurstSec = max(burstList, [], "omitnan");
        row.centers = string(mat2str(opts.Centers));
        row.perList = string(mat2str(perList, 4));
        row.rawPerList = string(mat2str(rawPerList, 4));
        row.phyHeaderSuccessList = string(mat2str(phyHeaderList, 4));
        row.headerSuccessList = string(mat2str(headerList, 4));
        row.sessionTransportSuccessList = string(mat2str(sessionTransportList, 4));
        row.packetSessionSuccessList = string(mat2str(packetSessionList, 4));
        row.payloadSuccessList = string(mat2str(payloadList, 4));
        row.frontEndSuccessList = string(mat2str(frontList, 4));
        row.elapsedListSec = string(mat2str(elapsedList, 4));
        row.burstListSec = string(mat2str(burstList, 4));
        row.caseRunDirs = strjoin(runDirs, ";");

        report.rows(caseIdx) = row;
        if row.pass
            report.firstPassIndex = caseIdx;
            fprintf("[RU-RS] PASS case=%s maxPER=%.4g maxRawPER=%.4g burst=%.3fs elapsed=%.3fs\n", ...
                char(row.caseName), row.maxPer, row.maxRawPer, row.maxBurstSec, row.maxElapsedSec);
            if logical(opts.StopOnFirstPass)
                report.rows = report.rows(1:caseIdx);
                break;
            end
        else
            fprintf("[RU-RS] FAIL case=%s maxPER=%.4g maxRawPER=%.4g minPhyHeader=%.4g minHeader=%.4g minSession=%.4g minPayload=%.4g\n", ...
                char(row.caseName), row.maxPer, row.maxRawPer, row.minPhyHeaderSuccess, ...
                row.minHeaderSuccess, row.minSessionTransportSuccess, row.minPayloadSuccess);
        end
    catch ME
        row.errorMessage = string(ME.message);
        report.rows(caseIdx) = row;
        fprintf("[RU-RS] FAILED case=%s: %s\n", char(row.caseName), ME.message);
    end
end

tbl = struct2table(report.rows);
writetable(tbl, fullfile(outRoot, "summary.csv"));
save(fullfile(outRoot, "report.mat"), "report");
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "scan_robust_unified_badpoints_rs";
addParameter(p, "Centers", [-3 3], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "RsCases", [4 5; 4 6; 4 7; 4 8; 3 6; 3 8; 2 8; 2 10], ...
    @(x) isnumeric(x) && ismatrix(x) && size(x, 2) == 2 && ~isempty(x));
addParameter(p, "EbN0dB", 6, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "JsrDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "BurstThresholdSec", 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "ElapsedThresholdSec", 300, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "NFramesPerPoint", 1, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "StopOnFirstPass", true, @(x) islogical(x) || isnumeric(x));
addParameter(p, "SaveFullResults", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results", "scan_robust_unified_badpoints_rs"), @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", "robust_unified_badpoints_rs_" + string(datetime("now", "Format", "yyyyMMdd_HHmmss")), @(x) ischar(x) || isstring(x));
parse(p, varargin{:});

opts = p.Results;
opts.Centers = double(opts.Centers(:).');
opts.RsCases = double(opts.RsCases);
opts.StopOnFirstPass = logical(opts.StopOnFirstPass);
opts.SaveFullResults = logical(opts.SaveFullResults);
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
end

function spec = local_base_spec(opts, runDir, center)
spec = default_link_spec( ...
    "linkProfileName", "robust_unified", ...
    "loadMlModels", string.empty(1, 0), ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false);
spec.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
spec.sim.saveFigures = false;
spec.sim.useParallel = false;
spec.sim.resultsDir = string(fullfile(char(runDir), sprintf("center_%+0.1f", center)));
spec.linkBudget.ebN0dBList = double(opts.EbN0dB);
spec.linkBudget.jsrDbList = double(opts.JsrDb);

spec.channel.impulseProb = 0.0;
spec.channel.impulseWeight = 0.0;
spec.channel.impulseToBgRatio = 0.0;
spec.channel.narrowband.enable = true;
spec.channel.narrowband.weight = 1.0;
spec.channel.narrowband.centerFreqPoints = double(center);
runtimeTmp = compile_runtime_config(spec);
spec.channel.narrowband.bandwidthFreqPoints = ...
    narrowband_prespread_fh_bandwidth_points(runtimeTmp.fh, runtimeTmp.waveform, runtimeTmp.dsss);
spec.channel.multipath.enable = false;
local_validate_narrowband_center_local(spec);
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

function local_save_case_result_local(caseRoot, center, results, spec, opts)
savePath = fullfile(char(caseRoot), sprintf("center_%+0.1f_result.mat", center));
if logical(opts.SaveFullResults)
    save(savePath, "results", "spec", "-v7.3");
else
    caseResult = struct( ...
        "center", double(center), ...
        "per", double(results.per(1, 1)), ...
        "phyHeaderSuccess", double(results.packetDiagnostics.bob.phyHeaderSuccessRateByMethod(1, 1)), ...
        "rawPer", double(results.rawPer(1, 1)), ...
        "headerSuccess", double(results.packetDiagnostics.bob.headerSuccessRateByMethod(1, 1)), ...
        "sessionTransportSuccess", double(results.packetDiagnostics.bob.sessionTransportSuccessRateByMethod(1, 1)), ...
        "packetSessionSuccess", double(results.packetDiagnostics.bob.packetSessionSuccessRateByMethod(1, 1)), ...
        "payloadSuccess", double(results.packetDiagnostics.bob.payloadSuccessRate(1, 1)), ...
        "frontEndSuccess", double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(1, 1)), ...
        "burstSec", double(results.tx.burstDurationSec));
    save(savePath, "caseResult", "spec");
end
end

function local_mkdir(dirPath)
if ~exist(dirPath, "dir")
    mkdir(dirPath);
end
end

function row = local_empty_row()
row = struct( ...
    "caseIndex", NaN, ...
    "caseName", "", ...
    "runDir", "", ...
    "runOk", false, ...
    "pass", false, ...
    "rsDataPacketsPerBlock", NaN, ...
    "rsParityPacketsPerBlock", NaN, ...
    "maxPer", NaN, ...
    "maxRawPer", NaN, ...
    "minPhyHeaderSuccess", NaN, ...
    "minHeaderSuccess", NaN, ...
    "minSessionTransportSuccess", NaN, ...
    "minPacketSessionSuccess", NaN, ...
    "minPayloadSuccess", NaN, ...
    "minFrontEndSuccess", NaN, ...
    "maxElapsedSec", NaN, ...
    "maxBurstSec", NaN, ...
    "centers", "", ...
    "perList", "", ...
    "rawPerList", "", ...
    "phyHeaderSuccessList", "", ...
    "headerSuccessList", "", ...
    "sessionTransportSuccessList", "", ...
    "packetSessionSuccessList", "", ...
    "payloadSuccessList", "", ...
    "frontEndSuccessList", "", ...
    "elapsedListSec", "", ...
    "burstListSec", "", ...
    "caseRunDirs", "", ...
    "errorMessage", "");
end
