function export_thesis_tables(outDir, results)
%EXPORT_THESIS_TABLES  Export thesis-friendly CSV tables from simulation results.
%
% 输入:
%   outDir  - 输出目录（必须已存在）
%   results - simulate() 返回的结果结构体
%
% 输出:
%   无（直接写 CSV 到磁盘）

arguments
    outDir {mustBeTextScalar}
    results (1,1) struct
end

outDir = string(outDir);
if ~isfolder(outDir)
    error("export_thesis_tables:MissingOutputDir", ...
        "Output directory does not exist: %s", outDir);
end

local_require_fields(results, ["methods" "ebN0dB" "jsrDb" "scan" "ber" "per" "packetDiagnostics" "linkBudget" "spectrum" "tx" "params"]);
local_require_fields(results.packetDiagnostics, "bob", "results.packetDiagnostics");
local_require_fields(results.linkBudget, "bob", "results.linkBudget");
local_require_fields(results.params, ["sim" "mod" "payload" "frame" "fh"], "results.params");
local_require_fields(results, "kl", "results");

methods = string(results.methods(:));
bobEbN0dB = double(results.ebN0dB(:));
bobJsrDb = double(results.jsrDb(:));
nMethods = numel(methods);
nPoints = numel(bobEbN0dB);
if numel(bobJsrDb) ~= nPoints
    error("export_thesis_tables:InvalidJsrPointCount", ...
        "results.jsrDb must contain %d points, got %d.", nPoints, numel(bobJsrDb));
end

berBob = local_require_metric_matrix(results.ber, nMethods, nPoints, "results.ber");
perBob = local_require_metric_matrix(results.per, nMethods, nPoints, "results.per");
[commMetricsBob, compMetricsBob] = local_get_image_metrics(results, nMethods, nPoints, "results");
scan = local_require_scan_struct(results.scan, nPoints, "results.scan");

bobDiag = results.packetDiagnostics.bob;
frontEndBob = local_require_point_vector(bobDiag, "frontEndSuccessRate", nPoints, "results.packetDiagnostics.bob");
headerBob = local_require_point_vector(bobDiag, "headerSuccessRate", nPoints, "results.packetDiagnostics.bob");
payloadBob = local_require_method_point_matrix(bobDiag, "payloadSuccessRate", nMethods, nPoints, "results.packetDiagnostics.bob");

bobBudget = local_require_budget_struct(results.linkBudget.bob, nPoints, "results.linkBudget.bob");

runSummary = local_build_run_summary_table(results, methods, nMethods, nPoints, scan);
pointOverview = local_build_point_overview_table( ...
    bobEbN0dB, bobJsrDb, bobBudget, scan, frontEndBob, headerBob, results, nPoints);
metricsBob = local_build_metric_table( ...
    methods, "bob", bobBudget.txPowerDb, bobEbN0dB, bobJsrDb, scan, berBob, perBob, payloadBob, ...
    commMetricsBob, compMetricsBob, frontEndBob, headerBob);

writetable(runSummary, fullfile(outDir, "run_summary.csv"));
writetable(pointOverview, fullfile(outDir, "points_overview.csv"));
writetable(metricsBob, fullfile(outDir, "metrics_bob.csv"));

if isfield(results, "eve")
    local_require_fields(results.eve, ["ebN0dB" "ber" "per" "packetDiagnostics"], "results.eve");
    local_require_fields(results.packetDiagnostics, "bob", "results.packetDiagnostics");
    if ~isfield(results.linkBudget, "eve")
        error("export_thesis_tables:MissingEveBudget", ...
            "results.linkBudget.eve is required when results.eve is present.");
    end

    eveEbN0dB = double(results.eve.ebN0dB(:));
    if numel(eveEbN0dB) ~= nPoints
        error("export_thesis_tables:InvalidEveEbN0", ...
            "results.eve.ebN0dB must contain %d points, got %d.", nPoints, numel(eveEbN0dB));
    end

    berEve = local_require_metric_matrix(results.eve.ber, nMethods, nPoints, "results.eve.ber");
    perEve = local_require_metric_matrix(results.eve.per, nMethods, nPoints, "results.eve.per");
    [commMetricsEve, compMetricsEve] = local_get_image_metrics(results.eve, nMethods, nPoints, "results.eve");

    eveDiag = results.eve.packetDiagnostics;
    frontEndEve = local_require_point_vector(eveDiag, "frontEndSuccessRate", nPoints, "results.eve.packetDiagnostics");
    headerEve = local_require_point_vector(eveDiag, "headerSuccessRate", nPoints, "results.eve.packetDiagnostics");
    payloadEve = local_require_method_point_matrix(eveDiag, "payloadSuccessRate", nMethods, nPoints, "results.eve.packetDiagnostics");

    eveBudget = local_require_budget_struct(results.linkBudget.eve, nPoints, "results.linkBudget.eve");

    metricsEve = local_build_metric_table( ...
        methods, "eve", eveBudget.txPowerDb, eveEbN0dB, bobJsrDb, scan, berEve, perEve, payloadEve, ...
        commMetricsEve, compMetricsEve, frontEndEve, headerEve);
    writetable(metricsEve, fullfile(outDir, "metrics_eve.csv"));
end

if isfield(results, "covert") && isfield(results.covert, "warden")
    wardenTable = local_build_warden_table(results.covert.warden, bobEbN0dB, bobJsrDb, scan, nPoints);
    writetable(wardenTable, fullfile(outDir, "warden_layers.csv"));
end
end

function t = local_build_run_summary_table(results, methods, nMethods, nPoints, scan)
packetConcealActive = false;
packetConcealMode = "";
if isfield(results, "packetConceal")
    if isfield(results.packetConceal, "active")
        packetConcealActive = logical(results.packetConceal.active);
    end
    if isfield(results.packetConceal, "mode")
        packetConcealMode = string(results.packetConceal.mode);
    end
end

eveEnable = isfield(results, "eve");
wardenEnable = isfield(results, "covert") && isfield(results.covert, "warden");

eveScramble = "";
eveFh = "";
eveChaos = "";
eveChaosApproxDelta = NaN;
if eveEnable && isfield(results.eve, "assumptions")
    assump = results.eve.assumptions;
    local_require_fields(assump, ["scramble" "fh" "chaos" "chaosApproxDelta"], "results.eve.assumptions");
    eveScramble = string(assump.scramble);
    eveFh = string(assump.fh);
    eveChaos = string(assump.chaos);
    eveChaosApproxDelta = double(assump.chaosApproxDelta);
end

wardenPrimaryLayer = "";
if wardenEnable && isfield(results.covert.warden, "primaryLayer")
    wardenPrimaryLayer = string(results.covert.warden.primaryLayer);
end

t = table( ...
    double(results.params.rngSeed), ...
    double(results.params.sim.nFramesPerPoint), ...
    string(results.params.mod.type), ...
    string(results.params.payload.codec), ...
    string(results.params.frame.sessionHeaderMode), ...
    logical(results.params.fh.enable), ...
    logical(packetConcealActive), ...
    string(packetConcealMode), ...
    string(scan.type), ...
    local_join_numeric_vector(scan.ebN0dBList), ...
    local_join_numeric_vector(scan.jsrDbList), ...
    double(scan.nSnr), ...
    double(scan.nJsr), ...
    local_join_string_vector(methods), ...
    nMethods, ...
    nPoints, ...
    local_join_numeric_vector(results.tx.configuredPowerLin), ...
    local_join_numeric_vector(results.tx.configuredPowerDb), ...
    double(results.linkBudget.noisePsdLin), ...
    double(results.tx.burstDurationSec), ...
    local_join_numeric_vector(results.tx.averagePowerLin), ...
    local_join_numeric_vector(results.tx.averagePowerDb), ...
    local_join_numeric_vector(results.tx.peakPowerLin), ...
    local_join_numeric_vector(results.tx.powerErrorLin), ...
    double(results.spectrum.bw99Hz), ...
    double(results.spectrum.etaBpsHz), ...
    logical(eveEnable), ...
    logical(wardenEnable), ...
    eveScramble, ...
    eveFh, ...
    eveChaos, ...
    eveChaosApproxDelta, ...
    wardenPrimaryLayer, ...
    'VariableNames', { ...
        'rngSeed', 'nFramesPerPoint', 'modType', 'payloadCodec', 'sessionHeaderMode', ...
        'fhEnable', ...
        'packetConcealActive', 'packetConcealMode', ...
        'scanType', 'ebN0dBList', 'jsrDbList', 'nSnr', 'nJsr', ...
        'methods', 'nMethods', 'nPoints', ...
        'txConfiguredPowerLinList', 'txConfiguredPowerDbList', 'noisePsdLin', ...
        'txBurstDurationSec', 'txMeasuredAveragePowerLinList', 'txMeasuredAveragePowerDbList', 'txPeakPowerLinList', 'txPowerErrorLinList', ...
        'bw99Hz', 'etaBpsHz', 'eveEnable', 'wardenEnable', ...
        'eveScrambleAssumption', 'eveFhAssumption', 'eveChaosAssumption', 'eveChaosApproxDelta', ...
        'wardenPrimaryLayer'});
end

function t = local_build_point_overview_table(bobEbN0dB, bobJsrDb, bobBudget, scan, frontEndBob, headerBob, results, nPoints)
pointIndex = (1:nPoints).';
klSignalVsNoise = local_require_point_vector(results.kl, "signalVsNoise", nPoints, "results.kl");
klNoiseVsSignal = local_require_point_vector(results.kl, "noiseVsSignal", nPoints, "results.kl");
klSymmetric = local_require_point_vector(results.kl, "symmetric", nPoints, "results.kl");

eveEbN0dB = nan(nPoints, 1);
eveFrontEnd = nan(nPoints, 1);
eveHeader = nan(nPoints, 1);
if isfield(results, "eve")
    eveBudget = local_require_budget_struct(results.linkBudget.eve, nPoints, "results.linkBudget.eve");
    eveEbN0dB = double(results.eve.ebN0dB(:));
    eveDiag = results.eve.packetDiagnostics;
    eveFrontEnd = local_require_point_vector(eveDiag, "frontEndSuccessRate", nPoints, "results.eve.packetDiagnostics");
    eveHeader = local_require_point_vector(eveDiag, "headerSuccessRate", nPoints, "results.eve.packetDiagnostics");
end

wardenEbN0dB = nan(nPoints, 1);
if isfield(results, "covert") && isfield(results.covert, "warden")
    if ~isfield(results.linkBudget, "warden")
        error("export_thesis_tables:MissingWardenBudget", ...
            "results.linkBudget.warden is required when results.covert.warden is present.");
    end
    wardenBudget = local_require_budget_struct(results.linkBudget.warden, nPoints, "results.linkBudget.warden");
    wardenEbN0dB = local_require_point_vector(results.covert.warden, "wardenEbN0dB", nPoints, "results.covert.warden");
end

t = table( ...
    pointIndex, ...
    scan.snrIndex, ...
    scan.jsrIndex, ...
    bobBudget.txPowerDb, ...
    bobEbN0dB, ...
    bobJsrDb, ...
    frontEndBob, ...
    headerBob, ...
    klSignalVsNoise, ...
    klNoiseVsSignal, ...
    klSymmetric, ...
    eveEbN0dB, ...
    eveFrontEnd, ...
    eveHeader, ...
    wardenEbN0dB, ...
    'VariableNames', { ...
        'pointIndex', 'snrIndex', 'jsrIndex', 'txPowerDb', 'bobEbN0dB', 'jsrDb', ...
        'bobFrontEndSuccessRate', 'bobHeaderSuccessRate', ...
        'klSignalVsNoise', 'klNoiseVsSignal', 'klSymmetric', ...
        'eveEbN0dB', 'eveFrontEndSuccessRate', 'eveHeaderSuccessRate', ...
        'wardenEbN0dB'});
end

function t = local_build_metric_table(methods, roleName, txPowerDb, ebN0dB, jsrDb, scan, ber, per, payloadSuccessRate, commMetrics, compMetrics, frontEndSuccessRate, headerSuccessRate)
nMethods = numel(methods);
nPoints = numel(ebN0dB);
pointIndex = repmat((1:nPoints).', nMethods, 1);
methodIndex = repelem((1:nMethods).', nPoints, 1);
berVec = reshape(ber.', [], 1);
perVec = reshape(per.', [], 1);
payloadVec = reshape(payloadSuccessRate.', [], 1);
commMseVec = reshape(commMetrics.mse.', [], 1);
commPsnrVec = reshape(commMetrics.psnr.', [], 1);
commSsimVec = reshape(commMetrics.ssim.', [], 1);
compMseVec = reshape(compMetrics.mse.', [], 1);
compPsnrVec = reshape(compMetrics.psnr.', [], 1);
compSsimVec = reshape(compMetrics.ssim.', [], 1);

t = table( ...
    repmat(string(roleName), nMethods * nPoints, 1), ...
    methodIndex, ...
    repelem(methods, nPoints, 1), ...
    pointIndex, ...
    repmat(double(scan.snrIndex(:)), nMethods, 1), ...
    repmat(double(scan.jsrIndex(:)), nMethods, 1), ...
    repmat(double(txPowerDb(:)), nMethods, 1), ...
    repmat(double(ebN0dB(:)), nMethods, 1), ...
    repmat(double(jsrDb(:)), nMethods, 1), ...
    repmat(double(frontEndSuccessRate(:)), nMethods, 1), ...
    repmat(double(headerSuccessRate(:)), nMethods, 1), ...
    berVec, ...
    perVec, ...
    payloadVec, ...
    commMseVec, ...
    commPsnrVec, ...
    commSsimVec, ...
    compMseVec, ...
    compPsnrVec, ...
    compSsimVec, ...
    'VariableNames', { ...
        'role', 'methodIndex', 'method', 'pointIndex', 'snrIndex', 'jsrIndex', 'txPowerDb', 'ebN0dB', 'jsrDb', ...
        'frontEndSuccessRate', 'headerSuccessRate', 'ber', 'per', 'payloadSuccessRate', ...
        'mseComm', 'psnrComm', 'ssimComm', 'mseComp', 'psnrComp', 'ssimComp'});
end

function t = local_build_warden_table(wardenResults, bobEbN0dB, bobJsrDb, scan, nPoints)
local_require_fields(wardenResults, ["referenceLink" "wardenEbN0dB" "layers"], "results.covert.warden");

wardenEbN0dB = local_require_point_vector(wardenResults, "wardenEbN0dB", nPoints, "results.covert.warden");
layerNames = string(fieldnames(wardenResults.layers));
if isempty(layerNames)
    error("export_thesis_tables:MissingWardenLayers", ...
        "results.covert.warden.layers must not be empty.");
end

rows = table();
for i = 1:numel(layerNames)
    layerName = layerNames(i);
    layer = wardenResults.layers.(layerName);
    local_require_fields(layer, ["pd" "pfa" "pe"], "results.covert.warden.layers." + layerName);
    pd = local_require_numeric_vector(layer.pd, nPoints, "results.covert.warden.layers." + layerName + ".pd");
    pfa = local_require_numeric_vector(layer.pfa, nPoints, "results.covert.warden.layers." + layerName + ".pfa");
    pe = local_require_numeric_vector(layer.pe, nPoints, "results.covert.warden.layers." + layerName + ".pe");

    pmd = nan(nPoints, 1);
    xi = nan(nPoints, 1);
    if isfield(layer, "pmd")
        pmd = local_require_numeric_vector(layer.pmd, nPoints, "results.covert.warden.layers." + layerName + ".pmd");
    end
    if isfield(layer, "xi")
        xi = local_require_numeric_vector(layer.xi, nPoints, "results.covert.warden.layers." + layerName + ".xi");
    end

    rows = [rows; table( ... %#ok<AGROW>
        repmat(layerName, nPoints, 1), ...
        repmat(string(wardenResults.referenceLink), nPoints, 1), ...
        (1:nPoints).', ...
        double(scan.snrIndex(:)), ...
        double(scan.jsrIndex(:)), ...
        bobEbN0dB, ...
        bobJsrDb, ...
        wardenEbN0dB, ...
        pd, pfa, pmd, pe, xi, ...
        'VariableNames', { ...
            'layer', 'referenceLink', 'pointIndex', 'snrIndex', 'jsrIndex', 'bobEbN0dB', 'jsrDb', 'wardenEbN0dB', ...
            'pd', 'pfa', 'pmd', 'pe', 'xi'})];
end

t = rows;
end

function budget = local_require_budget_struct(budgetIn, nPoints, structName)
local_require_fields(budgetIn, ["txPowerDb" "ebN0dB" "jsrDb"], structName);
budget = struct();
budget.txPowerDb = local_require_numeric_vector(budgetIn.txPowerDb, nPoints, structName + ".txPowerDb");
budget.ebN0dB = local_require_numeric_vector(budgetIn.ebN0dB, nPoints, structName + ".ebN0dB");
budget.jsrDb = local_require_numeric_vector(budgetIn.jsrDb, nPoints, structName + ".jsrDb");
end

function scan = local_require_scan_struct(scanIn, nPoints, structName)
local_require_fields(scanIn, ["type" "ebN0dBList" "jsrDbList" "snrIndex" "jsrIndex" "nSnr" "nJsr"], structName);
scan = struct();
scan.type = string(scanIn.type);
scan.ebN0dBList = double(scanIn.ebN0dBList(:));
scan.jsrDbList = double(scanIn.jsrDbList(:));
scan.snrIndex = local_require_numeric_vector(scanIn.snrIndex, nPoints, structName + ".snrIndex");
scan.jsrIndex = local_require_numeric_vector(scanIn.jsrIndex, nPoints, structName + ".jsrIndex");
scan.nSnr = double(scanIn.nSnr);
scan.nJsr = double(scanIn.nJsr);
end

function [commMetrics, compMetrics] = local_get_image_metrics(results, nMethods, nPoints, structName)
local_require_fields(results, "imageMetrics", structName);
local_require_fields(results.imageMetrics, ["communication" "compensated"], structName + ".imageMetrics");

commMetrics = local_require_metric_struct(results.imageMetrics.communication, nMethods, nPoints, structName + ".imageMetrics.communication");
compMetrics = local_require_metric_struct(results.imageMetrics.compensated, nMethods, nPoints, structName + ".imageMetrics.compensated");
end

function metrics = local_require_metric_struct(metricsIn, nMethods, nPoints, structName)
local_require_fields(metricsIn, ["mse" "psnr" "ssim"], structName);
metrics = struct();
metrics.mse = local_require_metric_matrix(metricsIn.mse, nMethods, nPoints, structName + ".mse");
metrics.psnr = local_require_metric_matrix(metricsIn.psnr, nMethods, nPoints, structName + ".psnr");
metrics.ssim = local_require_metric_matrix(metricsIn.ssim, nMethods, nPoints, structName + ".ssim");
end

function values = local_require_metric_matrix(valuesIn, nRows, nCols, fieldName)
values = double(valuesIn);
if ~ismatrix(values) || ~isequal(size(values), [nRows nCols]) || any(~isfinite(values(:)))
    error("export_thesis_tables:InvalidMetricMatrix", ...
        "%s must be a finite %d-by-%d matrix.", fieldName, nRows, nCols);
end
end

function values = local_require_method_point_matrix(s, fieldName, nMethods, nPoints, structName)
local_require_fields(s, fieldName, structName);
values = local_require_metric_matrix(s.(fieldName), nMethods, nPoints, structName + "." + fieldName);
end

function values = local_require_point_vector(s, fieldName, nPoints, structName)
local_require_fields(s, fieldName, structName);
values = local_require_numeric_vector(s.(fieldName), nPoints, structName + "." + fieldName);
end

function values = local_require_numeric_vector(valuesIn, nPoints, fieldName)
values = double(valuesIn(:));
if numel(values) ~= nPoints || any(~isfinite(values))
    error("export_thesis_tables:InvalidNumericVector", ...
        "%s must be a finite vector with %d elements.", fieldName, nPoints);
end
end

function local_require_fields(s, fieldNames, structName)
if nargin < 3
    structName = "struct";
end
fieldNames = string(fieldNames);
for i = 1:numel(fieldNames)
    fieldName = fieldNames(i);
    if ~isfield(s, fieldName)
        error("export_thesis_tables:MissingField", ...
            "Missing required field %s.%s.", structName, fieldName);
    end
end
end

function txt = local_join_string_vector(values)
values = string(values(:).');
txt = join(values, ",");
txt = txt(1);
end

function txt = local_join_numeric_vector(values)
values = double(values(:).');
parts = compose("%.6g", values);
txt = join(parts, ",");
txt = txt(1);
end
