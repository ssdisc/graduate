function report = validate_impulse_ml_compare(varargin)
%VALIDATE_IMPULSE_ML_COMPARE Compare impulse traditional and ML front-ends.
%
% This script uses the refactored low-overhead impulse profile and one full
% 256-long-edge image frame per case by default.

opts = local_parse_inputs_local(varargin{:});
repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, 'src')));

outRoot = fullfile(char(opts.ResultsRoot), "validate_impulse_ml_compare", char(opts.Tag));
if ~exist(outRoot, 'dir')
    mkdir(outRoot);
end

[preloaded, mlAvailable] = local_load_ml_models_local(opts);
methods = local_resolve_methods_local(opts, mlAvailable);

rows = repmat(local_empty_row_local(), 0, 1);
caseIndex = 0;
for ip = 1:numel(opts.ImpulseProb)
    for ir = 1:numel(opts.ImpulseToBgRatio)
        caseIndex = caseIndex + 1;
        prob = double(opts.ImpulseProb(ip));
        ratio = double(opts.ImpulseToBgRatio(ir));
        caseName = sprintf('prob_%0.3f_ratio_%0.0f', prob, ratio);
        runDir = fullfile(outRoot, caseName);
        if ~exist(runDir, 'dir')
            mkdir(runDir);
        end

        cfg = default_params( ...
            "linkProfileName", "impulse", ...
            "loadMlModels", strings(1, 0), ...
            "strictModelLoad", false, ...
            "requireTrainedMlModels", true);
        cfg.linkBudget.ebN0dBList = double(opts.EbN0);
        cfg.linkBudget.jsrDbList = double(opts.JsrDb);
        cfg.sim.nFramesPerPoint = double(opts.NFrames);
        cfg.sim.useParallel = false;
        cfg.sim.saveFigures = false;
        cfg.sim.resultsDir = string(runDir);
        cfg.channel.impulseProb = prob;
        cfg.channel.impulseWeight = 1.0;
        cfg.channel.impulseToBgRatio = ratio;
        cfg.profileRx.cfg.methods = methods;
        cfg.extensions.ml.preloaded = preloaded;

        tStart = tic;
        try
            results = simulate(cfg);
            elapsedSec = toc(tStart);
            save(fullfile(runDir, 'results.mat'), 'results');
            for methodIdx = 1:numel(methods)
                row = local_result_row_local(results, methodIdx);
                row.caseIndex = caseIndex;
                row.caseName = string(caseName);
                row.impulseProb = prob;
                row.impulseToBgRatio = ratio;
                row.method = methods(methodIdx);
                row.elapsedSec = elapsedSec;
                row.burstSec = double(results.tx.burstDurationSec);
                row.runDir = string(runDir);
                row.runOk = true;
                row.pass = local_pass_local(row, opts);
                rows(end + 1, 1) = row; %#ok<AGROW>
            end
            fprintf('[IMP-ML] %-24s elapsed=%6.2fs burst=%6.2fs methods=%s\n', ...
                caseName, elapsedSec, double(results.tx.burstDurationSec), strjoin(cellstr(methods), ','));
        catch ME
            elapsedSec = toc(tStart);
            for methodIdx = 1:numel(methods)
                row = local_empty_row_local();
                row.caseIndex = caseIndex;
                row.caseName = string(caseName);
                row.impulseProb = prob;
                row.impulseToBgRatio = ratio;
                row.method = methods(methodIdx);
                row.elapsedSec = elapsedSec;
                row.runDir = string(runDir);
                row.errorMessage = string(ME.message);
                rows(end + 1, 1) = row; %#ok<AGROW>
            end
            fprintf('[IMP-ML] %-24s FAILED: %s\n', caseName, ME.message);
        end
    end
end

tbl = struct2table(rows);
writetable(tbl, fullfile(outRoot, 'summary.csv'));

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
report.outRoot = string(outRoot);
report.opts = opts;
report.methods = methods;
report.mlAvailable = mlAvailable;
report.summaryTable = tbl;
report.summary = local_summary_local(tbl, opts);
save(fullfile(outRoot, 'report.mat'), 'report');
disp(report.summary);
end

function opts = local_parse_inputs_local(varargin)
p = inputParser();
p.FunctionName = 'validate_impulse_ml_compare';
addParameter(p, 'ImpulseProb', [0.01 0.03 0.05], @(x) isnumeric(x) && isvector(x));
addParameter(p, 'ImpulseToBgRatio', [20 50 80], @(x) isnumeric(x) && isvector(x));
addParameter(p, 'Methods', ["none" "blanking" "clipping" "ml_cnn"], @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, 'EbN0', 6, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, 'JsrDb', 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, 'NFrames', 1, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, 'MaxBurstSec', 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, 'MaxElapsedSec', 60, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x > 0);
addParameter(p, 'CnnModelPath', fullfile(pwd, 'models', 'impulse_cnn_model.mat'), @(x) ischar(x) || isstring(x));
addParameter(p, 'GruModelPath', fullfile(pwd, 'models', 'impulse_gru_model.mat'), @(x) ischar(x) || isstring(x));
addParameter(p, 'LrModelPath', fullfile(pwd, 'models', 'impulse_lr_model.mat'), @(x) ischar(x) || isstring(x));
addParameter(p, 'RequireMl', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'ResultsRoot', fullfile(pwd, 'results'), @(x) ischar(x) || isstring(x));
addParameter(p, 'Tag', string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')), @(x) ischar(x) || isstring(x));
parse(p, varargin{:});
opts = p.Results;
opts.Methods = unique(string(opts.Methods(:).'), 'stable');
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
opts.RequireMl = logical(opts.RequireMl);
end

function [preloaded, mlAvailable] = local_load_ml_models_local(opts)
preloaded = struct();
mlAvailable = struct("lr", false, "cnn", false, "gru", false);

[model, loaded] = load_pretrained_model(opts.LrModelPath, @ml_impulse_lr_model, ...
    "strict", false, "requireTrained", false, "allowBatchFallback", true);
if loaded && isfield(model, "trained") && logical(model.trained)
    preloaded.impulseLr = model;
    mlAvailable.lr = true;
end

[model, loaded] = load_pretrained_model(opts.CnnModelPath, @ml_cnn_impulse_model, ...
    "strict", false, "requireTrained", false, "allowBatchFallback", true);
if loaded && isfield(model, "trained") && logical(model.trained)
    preloaded.impulseCnn = model;
    mlAvailable.cnn = true;
end

[model, loaded] = load_pretrained_model(opts.GruModelPath, @ml_gru_impulse_model, ...
    "strict", false, "requireTrained", false, "allowBatchFallback", true);
if loaded && isfield(model, "trained") && logical(model.trained)
    preloaded.impulseGru = model;
    mlAvailable.gru = true;
end
end

function methods = local_resolve_methods_local(opts, mlAvailable)
requested = string(opts.Methods(:).');
keep = true(size(requested));
for idx = 1:numel(requested)
    method = lower(requested(idx));
    switch method
        case "ml_blanking"
            keep(idx) = logical(mlAvailable.lr);
        case {"ml_cnn" "ml_cnn_hard"}
            keep(idx) = logical(mlAvailable.cnn);
        case {"ml_gru" "ml_gru_hard"}
            keep(idx) = logical(mlAvailable.gru);
    end
end
if opts.RequireMl && any(~keep)
    missing = requested(~keep);
    error("Requested trained ML methods are unavailable: %s.", strjoin(cellstr(missing), ", "));
end
methods = requested(keep);
if isempty(methods)
    error("No methods left to compare after filtering unavailable trained ML models.");
end
end

function row = local_result_row_local(results, methodIdx)
bob = results.packetDiagnostics.bob;
row = local_empty_row_local();
row.ber = double(results.ber(methodIdx, 1));
row.rawPer = double(results.rawPer(methodIdx, 1));
row.per = double(results.per(methodIdx, 1));
row.frontEndSuccess = double(bob.frontEndSuccessRateByMethod(methodIdx, 1));
row.headerSuccess = double(bob.headerSuccessRateByMethod(methodIdx, 1));
row.sessionSuccess = double(bob.sessionSuccessRateByMethod(methodIdx, 1));
row.payloadSuccess = double(bob.payloadSuccessRate(methodIdx, 1));
end

function pass = local_pass_local(row, opts)
pass = row.runOk ...
    && isfinite(row.per) && row.per <= 1e-12 ...
    && isfinite(row.burstSec) && row.burstSec < double(opts.MaxBurstSec) ...
    && isfinite(row.elapsedSec) && row.elapsedSec < double(opts.MaxElapsedSec);
end

function row = local_empty_row_local()
row = struct( ...
    "caseIndex", NaN, ...
    "caseName", "", ...
    "impulseProb", NaN, ...
    "impulseToBgRatio", NaN, ...
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

function summary = local_summary_local(tbl, opts)
summary = struct();
summary.nRows = height(tbl);
summary.nCases = numel(unique(tbl.caseIndex(isfinite(tbl.caseIndex))));
summary.methods = string(unique(tbl.method, 'stable')).';
summary.nPass = sum(tbl.pass);
summary.maxBurstSec = max(tbl.burstSec, [], 'omitnan');
summary.maxElapsedSec = max(tbl.elapsedSec, [], 'omitnan');
summary.maxPer = max(tbl.per, [], 'omitnan');
summary.maxRawPer = max(tbl.rawPer, [], 'omitnan');
summary.bestByRawPer = local_best_method_summary_local(tbl, "rawPer");
summary.bestByBer = local_best_method_summary_local(tbl, "ber");
summary.performanceTarget = struct( ...
    "maxBurstSec", double(opts.MaxBurstSec), ...
    "maxElapsedSec", double(opts.MaxElapsedSec), ...
    "perTarget", 0);
end

function out = local_best_method_summary_local(tbl, metricName)
methods = string(unique(tbl.method, 'stable')).';
out = struct();
for method = methods
    use = tbl.runOk & tbl.method == method;
    values = tbl.(metricName)(use);
    out.(matlab.lang.makeValidName(char(method))) = mean(values, 'omitnan');
end
end
