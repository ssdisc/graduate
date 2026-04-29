function report = validate_security_profiles(varargin)
%VALIDATE_SECURITY_PROFILES Validate Bob/Warden/Eve security conditions on the three refactored profiles.

opts = local_parse_inputs(varargin{:});
repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

profiles = string(opts.Profiles(:).');
outRoot = fullfile(char(opts.ResultsRoot), "validate_security_profiles", char(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

summaryRows = repmat(local_empty_summary_row(), 0, 1);
layerRows = repmat(local_empty_layer_row(), 0, 1);

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
    cfg.profileRx.cfg.methods = local_best_method(profileName);
    cfg.commonTx.security.chaosEncrypt.enable = true;
    cfg = local_apply_profile_case(profileName, cfg, opts);

    cfg.extensions.eve.enable = true;
    cfg.extensions.eve.linkGainOffsetDb = double(opts.EveLinkGainOffsetDb);
    cfg.extensions.eve.assumptions.protocol = "protocol_aware";
    cfg.extensions.eve.assumptions.fh = "known";
    cfg.extensions.eve.assumptions.scramble = "known";
    cfg.extensions.eve.assumptions.chaos = string(opts.EveChaosAssumption);
    cfg.extensions.eve.assumptions.chaosApproxDelta = double(opts.EveChaosApproxDelta);

    cfg.extensions.warden.enable = true;
    cfg.extensions.warden.warden.enable = true;
    cfg.extensions.warden.warden.linkGainOffsetDb = double(opts.WardenLinkGainOffsetDb);
    cfg.extensions.warden.warden.nTrials = double(opts.WardenTrials);
    cfg.extensions.warden.warden.nObs = double(opts.WardenObs);
    cfg.extensions.warden.warden.useParallel = false;
    if logical(opts.ScreenAllWardenLayers)
        cfg.extensions.warden.warden.enabledLayers = local_warden_screen_layers();
    end

    validate_link_profile(cfg);
    fprintf("[SEC] profile=%s Eb/N0=%s JSR=%.2f dB method=%s EveChaos=%s WardenLayers=%s\n", ...
        char(profileName), mat2str(double(opts.EbN0List(:).')), double(opts.JsrDb), ...
        char(cfg.profileRx.cfg.methods), char(cfg.extensions.eve.assumptions.chaos), ...
        strjoin(cellstr(string(cfg.extensions.warden.warden.enabledLayers)), ","));

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

    summaryRows = [summaryRows; local_summary_rows_from_results(profileName, results, elapsedSec, runDir, opts)]; %#ok<AGROW>
    layerRows = [layerRows; local_layer_rows_from_results(profileName, results, opts)]; %#ok<AGROW>
end

summaryTable = struct2table(summaryRows);
layerTable = struct2table(layerRows);
keepTable = local_build_keep_table(layerTable, summaryTable, opts);

writetable(summaryTable, fullfile(outRoot, "security_summary.csv"));
writetable(layerTable, fullfile(outRoot, "warden_layer_screen.csv"));
writetable(keepTable, fullfile(outRoot, "warden_layer_keep.csv"));

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.outRoot = string(outRoot);
report.opts = opts;
report.summaryTable = summaryTable;
report.layerTable = layerTable;
report.keepTable = keepTable;
report.summary = local_overall_summary(summaryTable, keepTable);
save(fullfile(outRoot, "report.mat"), "report");
disp(report.summary);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "validate_security_profiles";
addParameter(p, "Profiles", ["impulse" "narrowband" "rayleigh_multipath"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "EbN0List", [4 6 8], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "JsrDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NFramesPerPoint", 1, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "ImpulseProb", 0.03, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0 && x <= 1);
addParameter(p, "NarrowbandCenter", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NarrowbandBandwidth", 1.0, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "RayleighDelays", [0 2 4], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "RayleighGainsDb", [0 -6 -10], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "EveLinkGainOffsetDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "EveChaosAssumption", "wrong_key", @(x) ischar(x) || isstring(x));
addParameter(p, "EveChaosApproxDelta", 1e-10, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 0);
addParameter(p, "WardenLinkGainOffsetDb", -10, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "WardenTrials", 80, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 10);
addParameter(p, "WardenObs", 4096, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 16);
addParameter(p, "WardenPeThreshold", 0.40, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "ScreenAllWardenLayers", true, @(x) islogical(x) || isnumeric(x));
addParameter(p, "EveBerThreshold", 0.45, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "EvePsnrThreshold", 8.0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "EveSsimThreshold", 0.05, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "BurstThresholdSec", 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "ExportTables", true, @(x) islogical(x) || isnumeric(x));
addParameter(p, "MakeFigures", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results"), @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", string(datetime("now", "Format", "yyyyMMdd_HHmmss")), @(x) ischar(x) || isstring(x));
parse(p, varargin{:});
opts = p.Results;
opts.Profiles = string(opts.Profiles);
opts.EveChaosAssumption = string(opts.EveChaosAssumption);
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
end

function method = local_best_method(profileName)
switch string(profileName)
    case "impulse"
        method = "blanking";
    case "narrowband"
        method = "fh_erasure";
    case "rayleigh_multipath"
        method = "sc_fde_mmse";
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

function layerNames = local_warden_screen_layers()
layerNames = ["energyNp" "energyOpt" "energyOptUncertain" "energyFhNarrow" "cyclostationaryOpt"];
end

function rows = local_summary_rows_from_results(profileName, results, elapsedSec, runDir, opts)
nPoints = numel(results.ebN0dB);
rows = repmat(local_empty_summary_row(), nPoints, 1);
methodIdx = 1;
primaryLayer = string(results.covert.warden.primaryLayer);
enabledLayers = local_get_enabled_warden_layers(results.covert.warden);
for pointIdx = 1:nPoints
    row = local_empty_summary_row();
    row.profile = string(profileName);
    row.method = string(results.methods(methodIdx));
    row.pointIndex = pointIdx;
    row.ebN0dB = double(results.ebN0dB(pointIdx));
    row.jsrDb = double(results.jsrDb(pointIdx));
    row.bobBer = double(results.ber(methodIdx, pointIdx));
    row.bobRawPer = double(results.rawPer(methodIdx, pointIdx));
    row.bobPer = double(results.per(methodIdx, pointIdx));
    row.bobPsnr = double(results.imageMetrics.original.communication.psnr(methodIdx, pointIdx));
    row.burstSec = double(results.tx.burstDurationSec);
    row.elapsedSec = double(elapsedSec);

    row.eveChaosAssumption = string(results.eve.assumptions.chaos);
    row.eveBer = double(results.eve.ber(methodIdx, pointIdx));
    row.eveRawPer = double(results.eve.rawPer(methodIdx, pointIdx));
    row.evePer = double(results.eve.per(methodIdx, pointIdx));
    row.evePsnr = double(results.eve.imageMetrics.original.communication.psnr(methodIdx, pointIdx));
    row.eveSsim = double(results.eve.imageMetrics.original.communication.ssim(methodIdx, pointIdx));

    row.wardenPrimaryLayer = primaryLayer;
    row.wardenPrimaryPe = local_get_warden_metric(results.covert.warden, primaryLayer, "pe", pointIdx);
    row.wardenEnabledLayers = join(enabledLayers, ",");
    row.wardenEnabledLayers = row.wardenEnabledLayers(1);
    row.wardenMinEnabledPe = local_min_enabled_warden_pe(results.covert.warden, enabledLayers, pointIdx);

    row.bobPass = row.bobPer == 0 && row.burstSec < double(opts.BurstThresholdSec);
    row.antiCrackingPass = row.eveBer >= double(opts.EveBerThreshold) ...
        && row.evePsnr <= double(opts.EvePsnrThreshold) ...
        && row.eveSsim <= double(opts.EveSsimThreshold);
    row.antiInterceptionPass = row.wardenMinEnabledPe >= double(opts.WardenPeThreshold);
    row.overallPass = row.bobPass && row.antiCrackingPass && row.antiInterceptionPass;
    row.runDir = string(runDir);
    rows(pointIdx) = row;
end
end

function rows = local_layer_rows_from_results(profileName, results, opts)
layerNames = string(fieldnames(results.covert.warden.layers));
nPoints = numel(results.ebN0dB);
rows = repmat(local_empty_layer_row(), numel(layerNames) * nPoints, 1);
dst = 1;
for layerIdx = 1:numel(layerNames)
    layerName = layerNames(layerIdx);
    layer = results.covert.warden.layers.(char(layerName));
    for pointIdx = 1:nPoints
        row = local_empty_layer_row();
        row.profile = string(profileName);
        row.layer = layerName;
        row.pointIndex = pointIdx;
        row.ebN0dB = double(results.ebN0dB(pointIdx));
        row.jsrDb = double(results.jsrDb(pointIdx));
        row.bobPer = double(results.per(1, pointIdx));
        row.bobPass = row.bobPer == 0 && double(results.tx.burstDurationSec) < double(opts.BurstThresholdSec);
        row.pd = double(layer.pd(pointIdx));
        row.pfa = double(layer.pfa(pointIdx));
        row.pmd = double(layer.pmd(pointIdx));
        row.pe = double(layer.pe(pointIdx));
        row.pass = row.bobPass && row.pe >= double(opts.WardenPeThreshold);
        rows(dst) = row;
        dst = dst + 1;
    end
end
end

function value = local_get_warden_metric(wardenResults, layerName, metricName, pointIdx)
value = NaN;
if ~(isfield(wardenResults, "layers") && isfield(wardenResults.layers, char(layerName)))
    return;
end
layer = wardenResults.layers.(char(layerName));
if ~(isfield(layer, metricName) && numel(layer.(metricName)) >= pointIdx)
    return;
end
value = double(layer.(metricName)(pointIdx));
end

function layerNames = local_get_enabled_warden_layers(wardenResults)
if isfield(wardenResults, "enabledLayers")
    layerNames = string(wardenResults.enabledLayers(:).');
    return;
end
layerNames = string(fieldnames(wardenResults.layers)).';
end

function value = local_min_enabled_warden_pe(wardenResults, enabledLayers, pointIdx)
values = nan(1, numel(enabledLayers));
for idx = 1:numel(enabledLayers)
    values(idx) = local_get_warden_metric(wardenResults, enabledLayers(idx), "pe", pointIdx);
end
value = min(values, [], "omitnan");
if isempty(value) || ~isfinite(value)
    value = NaN;
end
end

function t = local_build_keep_table(layerTable, ~, ~)
profiles = unique(string(layerTable.profile), "stable");
keyTable = unique(layerTable(:, ["profile" "layer"]), "rows");
rows = repmat(struct( ...
    "profile", "", ...
    "layer", "", ...
    "nBobPassPoints", 0, ...
    "nLayerPassPoints", 0, ...
    "minPeAtBobPass", NaN, ...
    "maxPeAtBobPass", NaN, ...
    "keepRecommended", false, ...
    "passEbN0dBList", ""), height(keyTable), 1);
dst = 1;
for profileIdx = 1:numel(profiles)
    profileName = profiles(profileIdx);
    profileMask = string(layerTable.profile) == profileName;
    layerNames = unique(string(layerTable.layer(profileMask)), "stable");
    for layerIdx = 1:numel(layerNames)
        layerName = layerNames(layerIdx);
        mask = profileMask & string(layerTable.layer) == layerName;
        tblNow = layerTable(mask, :);
        bobPassMask = logical(tblNow.bobPass);
        passMask = logical(tblNow.pass);
        passEb = unique(double(tblNow.ebN0dB(passMask)));
        rows(dst, 1) = struct( ...
            "profile", profileName, ...
            "layer", layerName, ...
            "nBobPassPoints", nnz(bobPassMask), ...
            "nLayerPassPoints", nnz(passMask), ...
            "minPeAtBobPass", min(double(tblNow.pe(bobPassMask)), [], "omitnan"), ...
            "maxPeAtBobPass", max(double(tblNow.pe(bobPassMask)), [], "omitnan"), ...
            "keepRecommended", any(passMask), ...
            "passEbN0dBList", local_join_numeric_vector(passEb));
        dst = dst + 1;
    end
end
t = struct2table(rows);
end

function summary = local_overall_summary(summaryTable, keepTable)
summary = struct();
summary.nRows = height(summaryTable);
summary.profiles = unique(string(summaryTable.profile), "stable").';
summary.passProfiles = unique(string(summaryTable.profile(summaryTable.overallPass)), "stable").';
summary.maxBurstSec = max(summaryTable.burstSec, [], "omitnan");
summary.maxElapsedSec = max(summaryTable.elapsedSec, [], "omitnan");
summary.recommendedKeepLayers = keepTable(:, ["profile" "layer" "keepRecommended" "passEbN0dBList"]);
end

function row = local_empty_summary_row()
row = struct( ...
    "profile", "", ...
    "method", "", ...
    "pointIndex", NaN, ...
    "ebN0dB", NaN, ...
    "jsrDb", NaN, ...
    "bobBer", NaN, ...
    "bobRawPer", NaN, ...
    "bobPer", NaN, ...
    "bobPsnr", NaN, ...
    "burstSec", NaN, ...
    "elapsedSec", NaN, ...
    "eveChaosAssumption", "", ...
    "eveBer", NaN, ...
    "eveRawPer", NaN, ...
    "evePer", NaN, ...
    "evePsnr", NaN, ...
    "eveSsim", NaN, ...
    "wardenPrimaryLayer", "", ...
    "wardenPrimaryPe", NaN, ...
    "wardenEnabledLayers", "", ...
    "wardenMinEnabledPe", NaN, ...
    "bobPass", false, ...
    "antiCrackingPass", false, ...
    "antiInterceptionPass", false, ...
    "overallPass", false, ...
    "runDir", "");
end

function row = local_empty_layer_row()
row = struct( ...
    "profile", "", ...
    "layer", "", ...
    "pointIndex", NaN, ...
    "ebN0dB", NaN, ...
    "jsrDb", NaN, ...
    "bobPer", NaN, ...
    "bobPass", false, ...
    "pd", NaN, ...
    "pfa", NaN, ...
    "pmd", NaN, ...
    "pe", NaN, ...
    "pass", false);
end

function txt = local_join_numeric_vector(values)
values = double(values(:).');
if isempty(values)
    txt = "";
    return;
end
parts = compose("%.6g", values);
txt = join(parts, ",");
txt = txt(1);
end
