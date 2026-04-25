function summaryTable = scan_impulse_cases(varargin)
%SCAN_IMPULSE_CASES  Sweep impulse-channel parameter combinations for the impulse profile.

opts = local_parse_inputs(varargin{:});

addpath(genpath(fullfile(fileparts(mfilename("fullpath")), "src")));

pBase = default_params( ...
    "linkProfileName", "impulse", ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", logical(opts.RequireTrainedMlModels), ...
    "loadMlModels", string(opts.LoadMlModels(:).'));

pBase.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
pBase.sim.saveFigures = logical(opts.SaveFigures);
pBase.sim.useParallel = false;
pBase.linkBudget.ebN0dBList = double(opts.EbN0);
pBase.linkBudget.jsrDbList = double(opts.JsrDb);
pBase.mitigation.methods = string(opts.Method);
if isfield(pBase.mitigation, "binding") && isstruct(pBase.mitigation.binding) ...
        && isfield(pBase.mitigation.binding, "impulseMethods")
    pBase.mitigation.binding.impulseMethods = unique([ ...
        string(pBase.mitigation.binding.impulseMethods(:).') ...
        string(opts.Method)], "stable");
end
pBase = local_force_requested_impulse_ml_models(pBase, opts);

if isfinite(opts.SampleRateHz)
    pBase.waveform.sampleRateHz = double(opts.SampleRateHz);
    pBase.waveform.symbolRateHz = pBase.waveform.sampleRateHz / double(pBase.waveform.sps);
end
if strlength(opts.LdpcRate) > 0
    pBase.fec.ldpc.rate = opts.LdpcRate;
end
if isfinite(opts.PayloadBitsPerPacket)
    pBase.packet.payloadBitsPerPacket = double(opts.PayloadBitsPerPacket);
end
if isfinite(opts.RsK)
    pBase.outerRs.dataPacketsPerBlock = double(opts.RsK);
end
if isfinite(opts.RsP)
    pBase.outerRs.parityPacketsPerBlock = double(opts.RsP);
end
if strlength(opts.ThresholdStrategy) > 0
    pBase.mitigation.thresholdStrategy = opts.ThresholdStrategy;
end
if isfinite(opts.ThresholdAlpha)
    pBase.mitigation.thresholdAlpha = double(opts.ThresholdAlpha);
end
if isfinite(opts.ThresholdFixed)
    pBase.mitigation.thresholdFixed = double(opts.ThresholdFixed);
end

validate_link_profile(pBase);

outRoot = fullfile(char(opts.ResultsRoot), "scan_impulse_cases_" + string(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

rows = repmat(local_empty_row(), 0, 1);
caseIndex = 0;
for ip = 1:numel(opts.ImpulseProbList)
    for ir = 1:numel(opts.ImpulseToBgRatioList)
        caseIndex = caseIndex + 1;

        p = pBase;
        p.channel.impulseProb = double(opts.ImpulseProbList(ip));
        p.channel.impulseToBgRatio = double(opts.ImpulseToBgRatioList(ir));
        p.sim.resultsDir = fullfile(outRoot, sprintf("case_%02d_p_%0.4f_r_%0.1f", ...
            caseIndex, p.channel.impulseProb, p.channel.impulseToBgRatio));
        if ~exist(p.sim.resultsDir, "dir")
            mkdir(p.sim.resultsDir);
        end

        row = local_empty_row();
        row.caseIndex = caseIndex;
        row.impulseProb = p.channel.impulseProb;
        row.impulseToBgRatio = p.channel.impulseToBgRatio;
        row.methodLabel = string(opts.Method);

        fprintf("[IMPULSE] case %d: prob=%.4f, ratio=%.1f\n", ...
            caseIndex, row.impulseProb, row.impulseToBgRatio);

        try
            results = simulate(p);
            [berVal, rawPerVal, perVal, frontVal, headerVal, payloadVal, methodLabel] = ...
                local_single_method_metric(results, double(opts.EbN0));
            row.runOk = true;
            row.methodLabel = methodLabel;
            row.ber = berVal;
            row.rawPer = rawPerVal;
            row.per = perVal;
            row.frontEndSuccess = frontVal;
            row.headerSuccess = headerVal;
            row.payloadSuccess = payloadVal;
            row.burstDurationSec = double(results.tx.burstDurationSec);
            fprintf("[IMPULSE]    method=%s, rawPER=%.4f, PER=%.4f, burst=%.3fs\n", ...
                char(row.methodLabel), row.rawPer, row.per, row.burstDurationSec);
        catch ME
            row.errorMessage = string(ME.message);
            fprintf("[IMPULSE]    failed: %s\n", ME.message);
        end

        rows(end + 1) = row; %#ok<AGROW>
    end
end

summaryTable = struct2table(rows);
summaryCsv = fullfile(outRoot, "impulse_case_summary.csv");
writetable(summaryTable, summaryCsv);
fprintf("[IMPULSE] Summary written: %s\n", summaryCsv);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "scan_impulse_cases";

addParameter(p, "ImpulseProbList", [0.01 0.03 0.05], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "ImpulseToBgRatioList", [20 50 80], @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "EbN0", 8, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "JsrDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NFramesPerPoint", 1, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "Method", "clipping", @(x) ischar(x) || isstring(x));
addParameter(p, "LoadMlModels", strings(1, 0), @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "RequireTrainedMlModels", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "SampleRateHz", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "LdpcRate", "", @(x) ischar(x) || isstring(x));
addParameter(p, "PayloadBitsPerPacket", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "RsK", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "RsP", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "ThresholdStrategy", "", @(x) ischar(x) || isstring(x));
addParameter(p, "ThresholdAlpha", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "ThresholdFixed", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "SaveFigures", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results"), @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", string(datetime("now", "Format", "yyyyMMdd_HHmmss")), @(x) ischar(x) || isstring(x));

parse(p, varargin{:});
opts = p.Results;
opts.Method = string(opts.Method);
opts.LoadMlModels = string(opts.LoadMlModels);
opts.LdpcRate = string(opts.LdpcRate);
opts.ThresholdStrategy = string(opts.ThresholdStrategy);
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
end

function row = local_empty_row()
row = struct( ...
    "caseIndex", NaN, ...
    "impulseProb", NaN, ...
    "impulseToBgRatio", NaN, ...
    "runOk", false, ...
    "errorMessage", "", ...
    "methodLabel", "", ...
    "ber", NaN, ...
    "rawPer", NaN, ...
    "per", NaN, ...
    "frontEndSuccess", NaN, ...
    "headerSuccess", NaN, ...
    "payloadSuccess", NaN, ...
    "burstDurationSec", NaN);
end

function [berVal, rawPerVal, perVal, frontVal, headerVal, payloadVal, methodLabel] = ...
        local_single_method_metric(results, ebN0dB)
if ~(isfield(results, "methods") && numel(results.methods) == 1)
    error("scan_impulse_cases expects exactly one receiver method, got %d.", numel(results.methods));
end

methodLabel = string(results.methods(1));
eb = double(results.ebN0dB(:));
eIdx = find(abs(eb - double(ebN0dB)) < 1e-9, 1, "first");
if isempty(eIdx)
    error("Requested Eb/N0 %.6g dB not found in results.", ebN0dB);
end

berVal = double(results.ber(1, eIdx));
rawPerVal = double(results.rawPer(1, eIdx));
perVal = double(results.per(1, eIdx));
frontVal = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(1, eIdx));
headerVal = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(1, eIdx));
payloadVal = double(results.packetDiagnostics.bob.payloadSuccessRate(1, eIdx));
end

function pOut = local_force_requested_impulse_ml_models(pIn, opts)
pOut = pIn;
requested = lower(string(opts.LoadMlModels(:).'));
if isempty(requested)
    return;
end

modelDir = fullfile(pwd, "models");
if ~exist(modelDir, "dir")
    error("Model directory not found: %s", modelDir);
end

if any(string(opts.Method) == "ml_blanking") && any(requested == "lr")
    [model, ~] = load_pretrained_model( ...
        fullfile(modelDir, "impulse_lr_model.mat"), @ml_impulse_lr_model, ...
        "requireTrained", logical(opts.RequireTrainedMlModels), ...
        "strict", true, ...
        "allowBatchFallback", true, ...
        "expectedContext", []);
    pOut.mitigation.ml = model;
end

if any(string(opts.Method) == ["ml_cnn" "ml_cnn_hard"]) && any(requested == "cnn")
    [model, ~] = load_pretrained_model( ...
        fullfile(modelDir, "impulse_cnn_model.mat"), @ml_cnn_impulse_model, ...
        "requireTrained", logical(opts.RequireTrainedMlModels), ...
        "strict", true, ...
        "allowBatchFallback", true, ...
        "expectedContext", []);
    pOut.mitigation.mlCnn = model;
end

if any(string(opts.Method) == ["ml_gru" "ml_gru_hard"]) && any(requested == "gru")
    [model, ~] = load_pretrained_model( ...
        fullfile(modelDir, "impulse_gru_model.mat"), @ml_gru_impulse_model, ...
        "requireTrained", logical(opts.RequireTrainedMlModels), ...
        "strict", true, ...
        "allowBatchFallback", true, ...
        "expectedContext", []);
    pOut.mitigation.mlGru = model;
end
end
