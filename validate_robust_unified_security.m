function report = validate_robust_unified_security(varargin)
%VALIDATE_ROBUST_UNIFIED_SECURITY Sidecar Eve/Warden evaluation for robust_unified.

opts = local_parse_inputs(varargin{:});
repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

outRoot = fullfile(char(opts.ResultsRoot), char(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

cases = string(opts.Cases(:).');
summaryRows = repmat(local_empty_summary_row(), 0, 1);
layerRows = repmat(local_empty_layer_row(), 0, 1);

for caseIdx = 1:numel(cases)
    caseName = lower(cases(caseIdx));
    runDir = fullfile(outRoot, char(caseName));
    if ~exist(runDir, "dir")
        mkdir(runDir);
    end

    [row, curLayerRows] = local_run_case(caseIdx, caseName, runDir, opts);
    summaryRows = [summaryRows; row]; %#ok<AGROW>
    layerRows = [layerRows; curLayerRows]; %#ok<AGROW>

    fprintf("[RU-SEC] %-20s runOk=%d bobPass=%d antiCrack=%d covert=%d overall=%d ", ...
        char(row.caseName), row.runOk, row.bobPass, row.antiCrackingPass, ...
        row.covertnessPass, row.overallPass);
    fprintf("BobPER=%.4g EveBER=%.4g EvePSNR=%.3g WardenMinPe=%.4g elapsed=%.3fs\n", ...
        row.bobPer, row.eveBer, row.evePsnr, row.wardenMinEnabledPe, row.elapsedSec);
    if strlength(row.errorMessage) > 0
        fprintf("[RU-SEC]   error: %s\n", row.errorMessage);
    end
end

summaryTable = struct2table(summaryRows);
layerTable = struct2table(layerRows);
writetable(summaryTable, fullfile(outRoot, "robust_unified_security_summary.csv"));
writetable(layerTable, fullfile(outRoot, "robust_unified_warden_layers.csv"));

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.outRoot = string(outRoot);
report.opts = opts;
report.summaryTable = summaryTable;
report.layerTable = layerTable;
report.summary = local_overall_summary(summaryTable);
save(fullfile(outRoot, "report.mat"), "report");
disp(report.summary);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "validate_robust_unified_security";
addParameter(p, "Cases", ["impulse" "narrowband" "rayleigh_multipath"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "EbN0dB", 6, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "JsrDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NFramesPerPoint", 1, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "ImpulseProb", 0.03, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0 && x <= 1);
addParameter(p, "NarrowbandCenter", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NarrowbandBandwidth", NaN, @(x) isscalar(x) && isnumeric(x) && (isnan(x) || (isfinite(x) && x > 0)));
addParameter(p, "RayleighDelays", [0 2 4], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "RayleighGainsDb", [0 -6 -10], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "EveLinkGainOffsetDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "EveChaosAssumption", "wrong_key", @(x) ischar(x) || isstring(x));
addParameter(p, "EveChaosApproxDelta", 1e-10, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 0);
addParameter(p, "WardenLinkGainOffsetDb", -10, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "WardenLayers", ["energyNp" "energyOptUncertain" "energyFhNarrow" "cyclostationaryOpt"], ...
    @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "WardenPrimaryLayer", "energyOptUncertain", @(x) ischar(x) || isstring(x));
addParameter(p, "WardenTrials", 40, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 10);
addParameter(p, "WardenObs", 4096, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 16);
addParameter(p, "WardenNoiseUncertaintyDb", 1.0, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 0);
addParameter(p, "WardenExtraDelaySamples", 4096, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 0);
addParameter(p, "WardenPeThreshold", 0.40, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "EveBerThreshold", 0.45, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "EvePsnrThreshold", 8.0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "EveSsimThreshold", 0.05, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "ExportTables", true, @(x) islogical(x) || isnumeric(x));
addParameter(p, "MakeFigures", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "SaveFullResults", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results", "validate_robust_unified_security"), @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", "robust_unified_security_" + string(datetime("now", "Format", "yyyyMMdd_HHmmss")), @(x) ischar(x) || isstring(x));
parse(p, varargin{:});
opts = p.Results;
opts.Cases = unique(lower(string(opts.Cases(:).')), "stable");
opts.EveChaosAssumption = string(opts.EveChaosAssumption);
opts.WardenLayers = unique(string(opts.WardenLayers(:).'), "stable");
opts.WardenPrimaryLayer = string(opts.WardenPrimaryLayer);
opts.ExportTables = logical(opts.ExportTables);
opts.MakeFigures = logical(opts.MakeFigures);
opts.SaveFullResults = logical(opts.SaveFullResults);
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
if ~ismember(opts.WardenPrimaryLayer, opts.WardenLayers)
    error("WardenPrimaryLayer must be included in WardenLayers.");
end
end

function [row, layerRows] = local_run_case(caseIdx, caseName, runDir, opts)
row = local_empty_summary_row();
row.caseIndex = caseIdx;
row.caseName = string(caseName);
row.runDir = string(runDir);
layerRows = repmat(local_empty_layer_row(), 0, 1);

try
    spec = local_build_case_spec(caseName, runDir, opts);
    validate_link_profile(spec);

    tStart = tic;
    results = run_link_profile(spec);
    elapsedSec = toc(tStart);

    if logical(opts.ExportTables)
        export_thesis_tables(runDir, results);
    end
    if logical(opts.MakeFigures)
        save_figures(runDir, results);
    end

    row = local_summary_row_from_results(row, results, elapsedSec, opts);
    layerRows = local_layer_rows_from_results(row, results, opts);
    local_save_case_artifact(runDir, row, layerRows, spec, results, opts);
catch ME
    row.runOk = false;
    row.errorMessage = string(ME.message);
    save(fullfile(runDir, "case_error.mat"), "row", "ME");
end
end

function spec = local_build_case_spec(caseName, runDir, opts)
spec = default_link_spec( ...
    "linkProfileName", "robust_unified", ...
    "loadMlModels", string.empty(1, 0), ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false);

spec.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
spec.sim.useParallel = false;
spec.sim.saveFigures = false;
spec.sim.resultsDir = string(runDir);
spec.linkBudget.ebN0dBList = double(opts.EbN0dB);
spec.linkBudget.jsrDbList = double(opts.JsrDb);
spec.profileRx.cfg.methods = "robust_combo";
spec.commonTx.security.chaosEncrypt.enable = true;
spec.commonTx.security.chaosEncrypt.packetIndependent = true;

spec = local_apply_case_channel(spec, caseName, opts);
spec = local_enable_sidecars(spec, opts);
end

function spec = local_enable_sidecars(spec, opts)
spec.extensions.eve.enable = true;
spec.extensions.eve.linkGainOffsetDb = double(opts.EveLinkGainOffsetDb);
spec.extensions.eve.assumptions.protocol = "protocol_aware";
spec.extensions.eve.assumptions.fh = "known";
spec.extensions.eve.assumptions.scramble = "known";
spec.extensions.eve.assumptions.chaos = string(opts.EveChaosAssumption);
spec.extensions.eve.assumptions.chaosApproxDelta = double(opts.EveChaosApproxDelta);
spec.extensions.eve.rxDiversity = spec.profileRx.cfg.rxDiversity;

spec.extensions.warden.enable = true;
spec.extensions.warden.warden.enable = true;
spec.extensions.warden.warden.referenceLink = "independent";
spec.extensions.warden.warden.linkGainOffsetDb = double(opts.WardenLinkGainOffsetDb);
spec.extensions.warden.warden.enabledLayers = string(opts.WardenLayers);
spec.extensions.warden.warden.primaryLayer = string(opts.WardenPrimaryLayer);
spec.extensions.warden.warden.nTrials = double(opts.WardenTrials);
spec.extensions.warden.warden.nObs = double(opts.WardenObs);
spec.extensions.warden.warden.noiseUncertaintyDb = double(opts.WardenNoiseUncertaintyDb);
spec.extensions.warden.warden.extraDelaySamples = double(opts.WardenExtraDelaySamples);
spec.extensions.warden.warden.useParallel = false;
spec.extensions.warden.warden.fhNarrowband.enable = any(opts.WardenLayers == "energyFhNarrow");
spec.extensions.warden.warden.fhNarrowband.scanAllBins = true;
spec.extensions.warden.warden.cyclostationary.enable = any(opts.WardenLayers == "cyclostationaryOpt");
end

function spec = local_apply_case_channel(spec, caseName, opts)
caseName = lower(string(caseName));
spec.channel.impulseProb = 0.0;
spec.channel.impulseWeight = 0.0;
spec.channel.impulseToBgRatio = 0.0;
spec.channel.narrowband.enable = false;
spec.channel.narrowband.weight = 0.0;
spec.channel.narrowband.centerFreqPoints = double(opts.NarrowbandCenter);
spec.channel.narrowband.bandwidthFreqPoints = local_resolve_narrowband_bandwidth(spec, opts);
spec.channel.multipath.enable = false;
spec.channel.multipath.pathDelaysSymbols = double(opts.RayleighDelays(:).');
spec.channel.multipath.pathGainsDb = double(opts.RayleighGainsDb(:).');
spec.channel.multipath.rayleigh = true;

switch caseName
    case "impulse"
        spec = local_enable_impulse(spec, opts);
    case "narrowband"
        spec = local_enable_narrowband(spec);
    case "rayleigh_multipath"
        spec = local_enable_rayleigh(spec);
    case "impulse_narrowband"
        spec = local_enable_impulse(spec, opts);
        spec = local_enable_narrowband(spec);
    case "impulse_rayleigh"
        spec = local_enable_impulse(spec, opts);
        spec = local_enable_rayleigh(spec);
    case "narrowband_rayleigh"
        spec = local_enable_narrowband(spec);
        spec = local_enable_rayleigh(spec);
    case "all_three"
        spec = local_enable_impulse(spec, opts);
        spec = local_enable_narrowband(spec);
        spec = local_enable_rayleigh(spec);
    otherwise
        error("Unknown robust_unified security case: %s.", char(caseName));
end

if numel(spec.channel.multipath.pathDelaysSymbols) ~= numel(spec.channel.multipath.pathGainsDb)
    error("RayleighDelays and RayleighGainsDb must have the same length.");
end
if spec.channel.narrowband.enable
    local_validate_narrowband_center(spec);
end
end

function spec = local_enable_impulse(spec, opts)
spec.channel.impulseProb = double(opts.ImpulseProb);
spec.channel.impulseWeight = 1.0;
end

function spec = local_enable_narrowband(spec)
spec.channel.narrowband.enable = true;
spec.channel.narrowband.weight = 1.0;
end

function spec = local_enable_rayleigh(spec)
spec.channel.multipath.enable = true;
end

function bw = local_resolve_narrowband_bandwidth(spec, opts)
if ~isnan(double(opts.NarrowbandBandwidth))
    bw = double(opts.NarrowbandBandwidth);
    return;
end
runtimeCfg = compile_runtime_config(spec);
bw = narrowband_prespread_fh_bandwidth_points(runtimeCfg.fh, runtimeCfg.waveform, runtimeCfg.dsss);
end

function local_validate_narrowband_center(spec)
runtimeCfg = compile_runtime_config(spec);
[maxAbsCenter, ~] = narrowband_center_freq_points_limit( ...
    runtimeCfg.fh, runtimeCfg.waveform, spec.channel.narrowband.bandwidthFreqPoints);
if abs(double(spec.channel.narrowband.centerFreqPoints)) > maxAbsCenter
    error("Narrowband center %.6g exceeds valid range [-%.6g, %.6g].", ...
        double(spec.channel.narrowband.centerFreqPoints), maxAbsCenter, maxAbsCenter);
end
end

function row = local_summary_row_from_results(row, results, elapsedSec, opts)
methodIdx = 1;
pointIdx = 1;
row.runOk = true;
row.method = string(results.methods(methodIdx));
row.ebN0dB = double(results.ebN0dB(pointIdx));
row.jsrDb = double(results.jsrDb(pointIdx));
row.elapsedSec = double(elapsedSec);
row.burstSec = double(results.tx.burstDurationSec);
row.bobBer = double(results.ber(methodIdx, pointIdx));
row.bobRawPer = double(results.rawPer(methodIdx, pointIdx));
row.bobPer = double(results.per(methodIdx, pointIdx));
row.bobPerExact = local_optional_matrix_value(results, "perExact", methodIdx, pointIdx);
row.bobPsnr = double(results.imageMetrics.original.communication.psnr(methodIdx, pointIdx));
row.bobSsim = double(results.imageMetrics.original.communication.ssim(methodIdx, pointIdx));
row.bobPayloadSuccess = double(results.packetDiagnostics.bob.payloadSuccessRate(methodIdx, pointIdx));

row.eveLinkGainOffsetDb = double(opts.EveLinkGainOffsetDb);
row.eveChaosAssumption = string(results.eve.assumptions.chaos);
row.eveBer = double(results.eve.ber(methodIdx, pointIdx));
row.eveRawPer = double(results.eve.rawPer(methodIdx, pointIdx));
row.evePer = double(results.eve.per(methodIdx, pointIdx));
row.evePerExact = local_optional_matrix_value(results.eve, "perExact", methodIdx, pointIdx);
row.evePsnr = double(results.eve.imageMetrics.original.communication.psnr(methodIdx, pointIdx));
row.eveSsim = double(results.eve.imageMetrics.original.communication.ssim(methodIdx, pointIdx));

warden = results.covert.warden;
enabledLayers = string(warden.enabledLayers(:).');
row.wardenLinkGainOffsetDb = double(opts.WardenLinkGainOffsetDb);
row.wardenPrimaryLayer = string(warden.primaryLayer);
row.wardenPrimaryPe = local_get_warden_metric(warden, row.wardenPrimaryLayer, "pe", pointIdx);
row.wardenEnabledLayers = join(enabledLayers, ",");
row.wardenEnabledLayers = row.wardenEnabledLayers(1);
row.wardenMinEnabledPe = local_min_enabled_warden_pe(warden, enabledLayers, pointIdx);
row.wardenFhMonitorNFreqs = local_warden_fh_monitor_nfreqs(warden);

row.bobPass = row.bobPer == 0;
row.antiCrackingPass = row.eveBer >= double(opts.EveBerThreshold) ...
    && row.evePsnr <= double(opts.EvePsnrThreshold) ...
    && row.eveSsim <= double(opts.EveSsimThreshold);
row.covertnessPass = row.wardenMinEnabledPe >= double(opts.WardenPeThreshold);
row.overallPass = row.bobPass && row.antiCrackingPass && row.covertnessPass;
end

function rows = local_layer_rows_from_results(summaryRow, results, opts)
warden = results.covert.warden;
layerNames = string(warden.enabledLayers(:).');
rows = repmat(local_empty_layer_row(), numel(layerNames), 1);
for layerIdx = 1:numel(layerNames)
    layerName = layerNames(layerIdx);
    row = local_empty_layer_row();
    row.caseIndex = summaryRow.caseIndex;
    row.caseName = summaryRow.caseName;
    row.layer = layerName;
    row.ebN0dB = summaryRow.ebN0dB;
    row.jsrDb = summaryRow.jsrDb;
    row.wardenLinkGainOffsetDb = double(opts.WardenLinkGainOffsetDb);
    row.pd = local_get_warden_metric(warden, layerName, "pd", 1);
    row.pfa = local_get_warden_metric(warden, layerName, "pfa", 1);
    row.pmd = local_get_warden_metric(warden, layerName, "pmd", 1);
    row.xi = local_get_warden_metric(warden, layerName, "xi", 1);
    row.pe = local_get_warden_metric(warden, layerName, "pe", 1);
    row.pass = summaryRow.bobPass && row.pe >= double(opts.WardenPeThreshold);
    if layerName == "energyFhNarrow"
        row.fhMonitorNFreqs = local_warden_fh_monitor_nfreqs(warden);
        row.fhMonitorBandwidth = local_warden_fh_monitor_bandwidth(warden);
    end
    rows(layerIdx) = row;
end
end

function value = local_optional_matrix_value(s, fieldName, methodIdx, pointIdx)
value = NaN;
if isfield(s, fieldName) && ~isempty(s.(fieldName))
    x = s.(fieldName);
    if size(x, 1) >= methodIdx && size(x, 2) >= pointIdx
        value = double(x(methodIdx, pointIdx));
    end
end
end

function value = local_get_warden_metric(warden, layerName, metricName, pointIdx)
value = NaN;
if ~(isfield(warden, "layers") && isfield(warden.layers, char(layerName)))
    return;
end
layer = warden.layers.(char(layerName));
if isfield(layer, metricName) && numel(layer.(metricName)) >= pointIdx
    value = double(layer.(metricName)(pointIdx));
end
end

function minPe = local_min_enabled_warden_pe(warden, enabledLayers, pointIdx)
vals = nan(1, numel(enabledLayers));
for idx = 1:numel(enabledLayers)
    vals(idx) = local_get_warden_metric(warden, enabledLayers(idx), "pe", pointIdx);
end
valid = isfinite(vals);
if any(valid)
    minPe = min(vals(valid));
else
    minPe = NaN;
end
end

function nFreqs = local_warden_fh_monitor_nfreqs(warden)
nFreqs = NaN;
if isfield(warden, "layers") && isfield(warden.layers, "energyFhNarrow")
    layer = warden.layers.energyFhNarrow;
    if isfield(layer, "fhNarrowband") && isstruct(layer.fhNarrowband) ...
            && isfield(layer.fhNarrowband, "nFreqs")
        nFreqs = double(layer.fhNarrowband.nFreqs);
    end
end
end

function bandwidth = local_warden_fh_monitor_bandwidth(warden)
bandwidth = NaN;
if isfield(warden, "layers") && isfield(warden.layers, "energyFhNarrow")
    layer = warden.layers.energyFhNarrow;
    if isfield(layer, "fhNarrowband") && isstruct(layer.fhNarrowband) ...
            && isfield(layer.fhNarrowband, "bandwidth")
        bandwidth = double(layer.fhNarrowband.bandwidth);
    end
end
end

function local_save_case_artifact(runDir, row, layerRows, spec, results, opts)
if logical(opts.SaveFullResults)
    save(fullfile(runDir, "results.mat"), "results", "spec", "row", "layerRows", "-v7.3");
else
    caseResult = row;
    save(fullfile(runDir, "case_result.mat"), "caseResult", "layerRows", "spec");
end
end

function summary = local_overall_summary(summaryTable)
summary = struct();
summary.nCases = height(summaryTable);
if summary.nCases == 0
    summary.nRunOk = 0;
    summary.nOverallPass = 0;
    summary.passCases = strings(1, 0);
    summary.failCases = strings(1, 0);
    return;
end
summary.nRunOk = sum(logical(summaryTable.runOk));
summary.nBobPass = sum(logical(summaryTable.bobPass));
summary.nAntiCrackingPass = sum(logical(summaryTable.antiCrackingPass));
summary.nCovertnessPass = sum(logical(summaryTable.covertnessPass));
summary.nOverallPass = sum(logical(summaryTable.overallPass));
summary.passCases = string(summaryTable.caseName(logical(summaryTable.overallPass))).';
summary.failCases = string(summaryTable.caseName(~logical(summaryTable.overallPass))).';
end

function row = local_empty_summary_row()
row = struct( ...
    "caseIndex", NaN, ...
    "caseName", "", ...
    "method", "", ...
    "runOk", false, ...
    "bobPass", false, ...
    "antiCrackingPass", false, ...
    "covertnessPass", false, ...
    "overallPass", false, ...
    "ebN0dB", NaN, ...
    "jsrDb", NaN, ...
    "elapsedSec", NaN, ...
    "burstSec", NaN, ...
    "bobBer", NaN, ...
    "bobRawPer", NaN, ...
    "bobPer", NaN, ...
    "bobPerExact", NaN, ...
    "bobPsnr", NaN, ...
    "bobSsim", NaN, ...
    "bobPayloadSuccess", NaN, ...
    "eveLinkGainOffsetDb", NaN, ...
    "eveChaosAssumption", "", ...
    "eveBer", NaN, ...
    "eveRawPer", NaN, ...
    "evePer", NaN, ...
    "evePerExact", NaN, ...
    "evePsnr", NaN, ...
    "eveSsim", NaN, ...
    "wardenLinkGainOffsetDb", NaN, ...
    "wardenPrimaryLayer", "", ...
    "wardenPrimaryPe", NaN, ...
    "wardenEnabledLayers", "", ...
    "wardenMinEnabledPe", NaN, ...
    "wardenFhMonitorNFreqs", NaN, ...
    "runDir", "", ...
    "errorMessage", "");
end

function row = local_empty_layer_row()
row = struct( ...
    "caseIndex", NaN, ...
    "caseName", "", ...
    "layer", "", ...
    "ebN0dB", NaN, ...
    "jsrDb", NaN, ...
    "wardenLinkGainOffsetDb", NaN, ...
    "pd", NaN, ...
    "pfa", NaN, ...
    "pmd", NaN, ...
    "xi", NaN, ...
    "pe", NaN, ...
    "pass", false, ...
    "fhMonitorNFreqs", NaN, ...
    "fhMonitorBandwidth", NaN);
end
