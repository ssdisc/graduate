function summaryTable = scan_narrowband_centers(varargin)
%SCAN_NARROWBAND_CENTERS  Sweep narrowband centerFreqPoints and summarize link metrics.
%
% This script runs simulate() for a list of narrowband center-frequency points
% and exports a compact CSV focusing on BER/front-end/header success.
%
% Usage examples:
%   scan_narrowband_centers()
%   scan_narrowband_centers("CenterFreqPoints", -5.5:0.5:5.5)
%   scan_narrowband_centers("Methods", ["none" "fh_erasure"], "EbN0dBList", [8 10])
%
% Name-Value options:
%   "CenterFreqPoints"   : vector of points to test. If empty, auto-generate by
%                          spacing 0.5 across the valid range.
%   "Step"               : auto-generated sweep step (default 0.5).
%   "EbN0dBList"         : Eb/N0 sweep list for each run (default [8 10]).
%   "JsrDbList"          : JSR list (default 0).
%   "Methods"            : mitigation method list (default ["none" "fh_erasure"]).
%   "NFramesPerPoint"    : frames per Eb/N0 point (default 5).
%   "SaveFigures"        : whether simulate() saves full figures (default false).
%   "ResultsRoot"        : root folder for per-center run outputs (default results).
%   "Tag"                : output folder tag suffix (default timestamp).
%
% Return:
%   summaryTable         : table with one row per center point and key metrics.

opts = local_parse_inputs(varargin{:});

addpath(genpath(fullfile(fileparts(mfilename("fullpath")), "src")));

pBase = default_params( ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false, ...
    "loadMlModels", strings(1, 0));

% Keep only requested methods and channel-compatible methods.
if ~isempty(opts.Methods)
    pBase.mitigation.methods = string(opts.Methods(:).');
end
[activeMethods, ~, ~] = resolve_mitigation_methods(pBase.mitigation, pBase.channel);
pBase.mitigation.methods = activeMethods;

% Per-point simulation baseline config.
pBase.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
pBase.sim.saveFigures = logical(opts.SaveFigures);
pBase.sim.useParallel = false;
pBase.linkBudget.ebN0dBList = double(opts.EbN0dBList(:).');
pBase.linkBudget.jsrDbList = double(opts.JsrDbList(:).');

centerPoints = double(opts.CenterFreqPoints(:).');
if isempty(centerPoints)
    centerPoints = local_default_center_points(pBase, double(opts.Step));
end
centerPoints = unique(centerPoints, "stable");

outRoot = fullfile(char(opts.ResultsRoot), "scan_narrowband_centers_" + string(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

fprintf("========================================\n");
fprintf("Center sweep count: %d\n", numel(centerPoints));
fprintf("Eb/N0 list: %s dB\n", mat2str(double(pBase.linkBudget.ebN0dBList)));
fprintf("JSR list: %s dB\n", mat2str(double(pBase.linkBudget.jsrDbList)));
fprintf("Methods: %s\n", strjoin(cellstr(string(pBase.mitigation.methods)), ", "));
fprintf("Output root: %s\n", outRoot);
fprintf("========================================\n\n");

rows = repmat(local_empty_row(), numel(centerPoints), 1);
for idx = 1:numel(centerPoints)
    center = centerPoints(idx);
    fprintf("[SCAN] (%d/%d) centerFreqPoints=%.6g\n", idx, numel(centerPoints), center);

    p = pBase;
    p.channel.narrowband.centerFreqPoints = center;
    p.sim.resultsDir = fullfile(outRoot, sprintf("center_%+0.3f", center));
    if ~exist(p.sim.resultsDir, "dir")
        mkdir(p.sim.resultsDir);
    end

    row = local_empty_row();
    row.centerFreqPoints = center;
    row.runOk = false;
    row.runDir = "";
    row.errorMessage = "";
    row.berNoneEbN0_8 = NaN;
    row.berNoneEbN0_10 = NaN;
    row.frontNoneEbN0_8 = NaN;
    row.frontNoneEbN0_10 = NaN;
    row.headerNoneEbN0_8 = NaN;
    row.headerNoneEbN0_10 = NaN;
    row.payloadNoneEbN0_8 = NaN;
    row.payloadNoneEbN0_10 = NaN;
    row.berFhErasureEbN0_8 = NaN;
    row.berFhErasureEbN0_10 = NaN;
    row.frontFhErasureEbN0_8 = NaN;
    row.frontFhErasureEbN0_10 = NaN;
    row.headerFhErasureEbN0_8 = NaN;
    row.headerFhErasureEbN0_10 = NaN;
    row.payloadFhErasureEbN0_8 = NaN;
    row.payloadFhErasureEbN0_10 = NaN;

    try
        results = simulate(p);
        row.runOk = true;
        row.runDir = local_run_dir_from_results(results);

        [ber8, front8, header8, payload8] = local_metric_at(results, "none", 8);
        [ber10, front10, header10, payload10] = local_metric_at(results, "none", 10);
        row.berNoneEbN0_8 = ber8;
        row.berNoneEbN0_10 = ber10;
        row.frontNoneEbN0_8 = front8;
        row.frontNoneEbN0_10 = front10;
        row.headerNoneEbN0_8 = header8;
        row.headerNoneEbN0_10 = header10;
        row.payloadNoneEbN0_8 = payload8;
        row.payloadNoneEbN0_10 = payload10;

        [berFh8, frontFh8, headerFh8, payloadFh8] = local_metric_at(results, "fh_erasure", 8);
        [berFh10, frontFh10, headerFh10, payloadFh10] = local_metric_at(results, "fh_erasure", 10);
        row.berFhErasureEbN0_8 = berFh8;
        row.berFhErasureEbN0_10 = berFh10;
        row.frontFhErasureEbN0_8 = frontFh8;
        row.frontFhErasureEbN0_10 = frontFh10;
        row.headerFhErasureEbN0_8 = headerFh8;
        row.headerFhErasureEbN0_10 = headerFh10;
        row.payloadFhErasureEbN0_8 = payloadFh8;
        row.payloadFhErasureEbN0_10 = payloadFh10;

        fprintf("[SCAN]       ok, runDir=%s, none(BER@8=%.4f, BER@10=%.4f), fh_erasure(BER@8=%.4f, BER@10=%.4f)\n", ...
            char(string(row.runDir)), ...
            row.berNoneEbN0_8, row.berNoneEbN0_10, ...
            row.berFhErasureEbN0_8, row.berFhErasureEbN0_10);
    catch ME
        row.errorMessage = string(ME.message);
        fprintf("[SCAN]       failed: %s\n", ME.message);
    end

    rows(idx) = row;
end

summaryTable = struct2table(rows);
summaryCsv = fullfile(outRoot, "center_scan_summary.csv");
writetable(summaryTable, summaryCsv);
fprintf("\n[SCAN] Summary written: %s\n", summaryCsv);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "scan_narrowband_centers";

addParameter(p, "CenterFreqPoints", [], @(x) isnumeric(x) && isvector(x));
addParameter(p, "Step", 0.5, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, "EbN0dBList", [8 10], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "JsrDbList", 0, @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "Methods", ["none" "fh_erasure"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "NFramesPerPoint", 5, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "SaveFigures", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results"), @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", string(datetime("now", "Format", "yyyyMMdd_HHmmss")), @(x) ischar(x) || isstring(x));

parse(p, varargin{:});
opts = p.Results;
opts.Methods = string(opts.Methods);
opts.Tag = string(opts.Tag);
opts.ResultsRoot = string(opts.ResultsRoot);
end

function pts = local_default_center_points(p, step)
waveform = resolve_waveform_cfg(p);
[maxAbs, ~] = narrowband_center_freq_points_limit(p.fh, waveform, p.channel.narrowband.bandwidthFreqPoints);
maxAbs = floor(maxAbs / step) * step;
if maxAbs <= 0
    pts = 0;
    return;
end
pts = -maxAbs:step:maxAbs;
end

function row = local_empty_row()
row = struct( ...
    "centerFreqPoints", NaN, ...
    "runOk", false, ...
    "runDir", "", ...
    "errorMessage", "", ...
    "berNoneEbN0_8", NaN, ...
    "berNoneEbN0_10", NaN, ...
    "frontNoneEbN0_8", NaN, ...
    "frontNoneEbN0_10", NaN, ...
    "headerNoneEbN0_8", NaN, ...
    "headerNoneEbN0_10", NaN, ...
    "payloadNoneEbN0_8", NaN, ...
    "payloadNoneEbN0_10", NaN, ...
    "berFhErasureEbN0_8", NaN, ...
    "berFhErasureEbN0_10", NaN, ...
    "frontFhErasureEbN0_8", NaN, ...
    "frontFhErasureEbN0_10", NaN, ...
    "headerFhErasureEbN0_8", NaN, ...
    "headerFhErasureEbN0_10", NaN, ...
    "payloadFhErasureEbN0_8", NaN, ...
    "payloadFhErasureEbN0_10", NaN);
end

function runDir = local_run_dir_from_results(results)
runDir = "";
if ~(isfield(results, "params") && isstruct(results.params) ...
        && isfield(results.params, "sim") && isstruct(results.params.sim) ...
        && isfield(results.params.sim, "resultsDir"))
    return;
end
rootDir = string(results.params.sim.resultsDir);
if strlength(rootDir) == 0 || ~isfolder(rootDir)
    return;
end
runDir = rootDir;
end

function [berVal, frontVal, headerVal, payloadVal] = local_metric_at(results, methodName, ebN0dB)
berVal = NaN;
frontVal = NaN;
headerVal = NaN;
payloadVal = NaN;

if ~(isfield(results, "methods") && isfield(results, "ebN0dB") && isfield(results, "ber"))
    return;
end

methods = string(results.methods(:));
mIdx = find(methods == string(methodName), 1, "first");
if isempty(mIdx)
    return;
end

eb = double(results.ebN0dB(:));
eIdx = find(abs(eb - double(ebN0dB)) < 1e-9, 1, "first");
if isempty(eIdx)
    return;
end

berVal = double(results.ber(mIdx, eIdx));

if isfield(results, "packetDiagnostics") && isfield(results.packetDiagnostics, "bob")
    bob = results.packetDiagnostics.bob;
    if isfield(bob, "frontEndSuccessRateByMethod") && size(bob.frontEndSuccessRateByMethod, 1) >= mIdx
        frontVal = double(bob.frontEndSuccessRateByMethod(mIdx, eIdx));
    elseif isfield(bob, "frontEndSuccessRate")
        frontVal = double(bob.frontEndSuccessRate(eIdx));
    end
    if isfield(bob, "headerSuccessRateByMethod") && size(bob.headerSuccessRateByMethod, 1) >= mIdx
        headerVal = double(bob.headerSuccessRateByMethod(mIdx, eIdx));
    elseif isfield(bob, "headerSuccessRate")
        headerVal = double(bob.headerSuccessRate(eIdx));
    end
    if isfield(bob, "payloadSuccessRate") && size(bob.payloadSuccessRate, 1) >= mIdx
        payloadVal = double(bob.payloadSuccessRate(mIdx, eIdx));
    end
end
end
