function summaryTable = scan_rayleigh_multipath_cases(varargin)
%SCAN_RAYLEIGH_MULTIPATH_CASES  Sweep representative Rayleigh multipath scenarios.

opts = local_parse_inputs(varargin{:});

addpath(genpath(fullfile(fileparts(mfilename("fullpath")), "src")));

pBase = default_params( ...
    "linkProfileName", "rayleigh_multipath", ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", logical(opts.RequireTrainedMlModels), ...
    "loadMlModels", string(opts.LoadMlModels(:).'));

pBase.sim.nFramesPerPoint = double(opts.NFramesPerPoint);
pBase.sim.saveFigures = logical(opts.SaveFigures);
pBase.sim.useParallel = false;
pBase.linkBudget.ebN0dBList = double(opts.EbN0);
pBase.linkBudget.jsrDbList = double(opts.JsrDb);
if ~isempty(opts.MitigationMethods)
    pBase.profileRx.cfg.methods = string(opts.MitigationMethods(:).');
    if isfield(pBase.profileRx.cfg.mitigation, "binding") && isstruct(pBase.profileRx.cfg.mitigation.binding) ...
            && isfield(pBase.profileRx.cfg.mitigation.binding, "multipathMethods")
        pBase.profileRx.cfg.mitigation.binding.multipathMethods = unique([ ...
            string(pBase.profileRx.cfg.mitigation.binding.multipathMethods(:).') ...
            string(opts.MitigationMethods(:).')], "stable");
    end
end

if isfinite(opts.SampleRateHz)
    pBase.commonTx.waveform.sampleRateHz = double(opts.SampleRateHz);
    pBase.commonTx.waveform.symbolRateHz = pBase.commonTx.waveform.sampleRateHz / double(pBase.commonTx.waveform.sps);
end
if isfinite(opts.NFreqs)
    pBase.profileTx.cfg.fh.nFreqs = double(opts.NFreqs);
    pBase.profileTx.cfg.fh.freqSet = [];
end
if ~isempty(opts.FreqSet)
    pBase.profileTx.cfg.fh.freqSet = double(opts.FreqSet(:).');
    pBase.profileTx.cfg.fh.nFreqs = numel(pBase.profileTx.cfg.fh.freqSet);
end
if strlength(opts.ModType) > 0
    pBase.commonTx.modulation.type = opts.ModType;
end
if strlength(opts.LdpcRate) > 0
    pBase.commonTx.innerCode.ldpc.rate = opts.LdpcRate;
end
if ~isnan(opts.RxDiversityEnable)
    pBase.profileRx.cfg.rxDiversity.enable = logical(opts.RxDiversityEnable);
end
if isfinite(opts.RxDiversityNRx)
    pBase.profileRx.cfg.rxDiversity.nRx = double(opts.RxDiversityNRx);
end
if isfinite(opts.InterleaverRows)
    pBase.commonTx.interleaver.nRows = double(opts.InterleaverRows);
end
if isfinite(opts.PayloadBitsPerPacket)
    pBase.commonTx.packet.payloadBitsPerPacket = double(opts.PayloadBitsPerPacket);
end
if isfinite(opts.RsK)
    pBase.commonTx.outerRs.dataPacketsPerBlock = double(opts.RsK);
end
if isfinite(opts.RsP)
    pBase.commonTx.outerRs.parityPacketsPerBlock = double(opts.RsP);
end
if isfinite(opts.SymbolsPerHop)
    pBase.profileTx.cfg.fh.symbolsPerHop = double(opts.SymbolsPerHop);
end
if ~isnan(opts.PayloadDiversityEnable)
    pBase.profileTx.cfg.fh.payloadDiversity.enable = logical(opts.PayloadDiversityEnable);
end
if isfinite(opts.PayloadDiversityCopies)
    pBase.profileTx.cfg.fh.payloadDiversity.copies = double(opts.PayloadDiversityCopies);
end
if isfinite(opts.PayloadDiversityIndexOffset)
    pBase.profileTx.cfg.fh.payloadDiversity.indexOffset = double(opts.PayloadDiversityIndexOffset);
end
if isfinite(opts.ScFdeCpLenSymbols)
    pBase.profileTx.cfg.scFde.cpLenSymbols = double(opts.ScFdeCpLenSymbols);
end
if isfinite(opts.ScFdePilotLength)
    pBase.profileTx.cfg.scFde.pilotLength = double(opts.ScFdePilotLength);
end
if isfinite(opts.ScFdePilotMseThreshold)
    pBase.profileTx.cfg.scFde.fdePilotMseThreshold = double(opts.ScFdePilotMseThreshold);
end
if isfinite(opts.ScFdePilotMseMargin)
    pBase.profileTx.cfg.scFde.fdePilotMseMargin = double(opts.ScFdePilotMseMargin);
end
if isfinite(opts.ScFdeLambdaFactor)
    pBase.profileTx.cfg.scFde.lambdaFactor = double(opts.ScFdeLambdaFactor);
end
if ~isempty(opts.CompareMethods)
    pBase.profileRx.cfg.sync.multipathEq.compareMethods = string(opts.CompareMethods(:).');
end

[activeMethods, ~, ~] = resolve_profile_methods(pBase);
requestedMethods = unique(string(opts.MitigationMethods(:).'), "stable");
if ~isempty(requestedMethods) ...
        && (~isequal(size(activeMethods), size(requestedMethods)) || any(activeMethods ~= requestedMethods))
    error("scan_rayleigh_multipath_cases:InvalidMethods", ...
        "Requested methods %s are not valid for the rayleigh_multipath profile. Resolved methods: %s.", ...
        strjoin(cellstr(requestedMethods), ", "), ...
        strjoin(cellstr(activeMethods), ", "));
end
pBase.profileRx.cfg.methods = activeMethods;

validate_link_profile(pBase);

if numel(opts.PathDelayCases) ~= numel(opts.PathGainCases)
    error("PathDelayCases and PathGainCases must have the same length.");
end
if ~isempty(opts.CaseLabels) && numel(opts.CaseLabels) ~= numel(opts.PathDelayCases)
    error("CaseLabels length must match PathDelayCases when provided.");
end

outRoot = fullfile(char(opts.ResultsRoot), "scan_rayleigh_multipath_cases_" + string(opts.Tag));
if ~exist(outRoot, "dir")
    mkdir(outRoot);
end

rows = repmat(local_empty_row(), 0, 1);
for idx = 1:numel(opts.PathDelayCases)
    delays = double(opts.PathDelayCases{idx}(:).');
    gains = double(opts.PathGainCases{idx}(:).');
    if numel(delays) ~= numel(gains)
        error("PathDelayCases{%d} and PathGainCases{%d} length mismatch.", idx, idx);
    end

    p = pBase;
    p.channel.multipath.pathDelaysSymbols = delays;
    p.channel.multipath.pathGainsDb = gains;
    p.sim.resultsDir = fullfile(outRoot, sprintf("case_%02d", idx));
    if ~exist(p.sim.resultsDir, "dir")
        mkdir(p.sim.resultsDir);
    end

    row = local_empty_row();
    row.caseIndex = idx;
    if ~isempty(opts.CaseLabels)
        row.caseLabel = opts.CaseLabels(idx);
    else
        row.caseLabel = "case_" + string(idx);
    end
    row.pathDelaysSymbols = string(mat2str(delays));
    row.pathGainsDb = string(mat2str(gains));

    fprintf("[MP] case %d: %s, delays=%s, gains=%s\n", ...
        idx, char(row.caseLabel), mat2str(delays), mat2str(gains));

    try
        results = simulate(p);
        metricRows = local_metric_rows_for_case(results, double(opts.EbN0), row);
        for ir = 1:numel(metricRows)
            fprintf("[MP]    method=%s, rawPER=%.4f, PER=%.4f, burst=%.3fs\n", ...
                char(metricRows(ir).methodLabel), metricRows(ir).rawPer, ...
                metricRows(ir).per, metricRows(ir).burstDurationSec);
            rows(end + 1) = metricRows(ir); %#ok<AGROW>
        end
        continue;
    catch ME
        row.errorMessage = string(ME.message);
        fprintf("[MP]    failed: %s\n", ME.message);
    end

    rows(end + 1) = row; %#ok<AGROW>
end

summaryTable = struct2table(rows);
summaryCsv = fullfile(outRoot, "rayleigh_multipath_case_summary.csv");
writetable(summaryTable, summaryCsv);
fprintf("[MP] Summary written: %s\n", summaryCsv);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "scan_rayleigh_multipath_cases";

defaultDelayCases = { ...
    [0 1 2], ...
    [0 1 3], ...
    [0 2 4], ...
    [0 3 6], ...
    [0 1 3 5], ...
    [0 4 8]};
defaultGainCases = { ...
    [0 -12 -18], ...
    [0 -8 -14], ...
    [0 -6 -10], ...
    [0 -6 -12], ...
    [0 -5 -9 -13], ...
    [0 -4 -8]};

addParameter(p, "PathDelayCases", defaultDelayCases, @(x) iscell(x) && ~isempty(x));
addParameter(p, "PathGainCases", defaultGainCases, @(x) iscell(x) && ~isempty(x));
addParameter(p, "CaseLabels", strings(1, 0), @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "EbN0", 8, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "JsrDb", 0, @(x) isscalar(x) && isnumeric(x) && isfinite(x));
addParameter(p, "NFramesPerPoint", 1, @(x) isscalar(x) && isnumeric(x) && isfinite(x) && x >= 1);
addParameter(p, "LoadMlModels", strings(1, 0), @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "RequireTrainedMlModels", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "CompareMethods", strings(1, 0), @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "MitigationMethods", strings(1, 0), @(x) isstring(x) || ischar(x) || iscellstr(x));
addParameter(p, "SampleRateHz", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "NFreqs", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "FreqSet", [], @(x) isnumeric(x) && isvector(x));
addParameter(p, "ModType", "", @(x) ischar(x) || isstring(x));
addParameter(p, "LdpcRate", "", @(x) ischar(x) || isstring(x));
addParameter(p, "RxDiversityEnable", NaN, @(x) isscalar(x) && (islogical(x) || isnumeric(x)));
addParameter(p, "RxDiversityNRx", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "InterleaverRows", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "PayloadBitsPerPacket", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "RsK", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "RsP", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "SymbolsPerHop", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "PayloadDiversityEnable", NaN, @(x) isscalar(x) && (islogical(x) || isnumeric(x)));
addParameter(p, "PayloadDiversityCopies", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "PayloadDiversityIndexOffset", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "ScFdeCpLenSymbols", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "ScFdePilotLength", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "ScFdePilotMseThreshold", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "ScFdePilotMseMargin", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "ScFdeLambdaFactor", NaN, @(x) isscalar(x) && isnumeric(x));
addParameter(p, "SaveFigures", false, @(x) islogical(x) || isnumeric(x));
addParameter(p, "ResultsRoot", fullfile(pwd, "results"), @(x) ischar(x) || isstring(x));
addParameter(p, "Tag", string(datetime("now", "Format", "yyyyMMdd_HHmmss")), @(x) ischar(x) || isstring(x));

parse(p, varargin{:});
opts = p.Results;
opts.CaseLabels = string(opts.CaseLabels);
opts.LoadMlModels = string(opts.LoadMlModels);
opts.CompareMethods = string(opts.CompareMethods);
opts.MitigationMethods = string(opts.MitigationMethods);
opts.FreqSet = double(opts.FreqSet(:).');
opts.ModType = string(opts.ModType);
opts.LdpcRate = string(opts.LdpcRate);
opts.ResultsRoot = string(opts.ResultsRoot);
opts.Tag = string(opts.Tag);
end

function row = local_empty_row()
row = struct( ...
    "caseIndex", NaN, ...
    "caseLabel", "", ...
    "pathDelaysSymbols", "", ...
    "pathGainsDb", "", ...
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

function metricRows = local_metric_rows_for_case(results, ebN0dB, rowTemplate)
if ~(isfield(results, "methods") && ~isempty(results.methods))
    error("scan_rayleigh_multipath_cases requires non-empty results.methods.");
end

eb = double(results.ebN0dB(:));
eIdx = find(abs(eb - double(ebN0dB)) < 1e-9, 1, "first");
if isempty(eIdx)
    error("Requested Eb/N0 %.6g dB not found in results.", ebN0dB);
end

methods = string(results.methods(:));
metricRows = repmat(rowTemplate, numel(methods), 1);
for i = 1:numel(methods)
    metricRows(i).runOk = true;
    metricRows(i).methodLabel = methods(i);
    metricRows(i).ber = double(results.ber(i, eIdx));
    metricRows(i).rawPer = double(results.rawPer(i, eIdx));
    metricRows(i).per = double(results.per(i, eIdx));
    metricRows(i).frontEndSuccess = double(results.packetDiagnostics.bob.frontEndSuccessRateByMethod(i, eIdx));
    metricRows(i).headerSuccess = double(results.packetDiagnostics.bob.headerSuccessRateByMethod(i, eIdx));
    metricRows(i).payloadSuccess = double(results.packetDiagnostics.bob.payloadSuccessRate(i, eIdx));
    metricRows(i).burstDurationSec = double(results.tx.burstDurationSec);
end
end
