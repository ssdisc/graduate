function [threshold, chosenMetrics, selection] = ml_select_impulse_threshold(p, model, methodName, scores, truth, pfaTarget, opts)
%ML_SELECT_IMPULSE_THRESHOLD  Select impulse-detector threshold using sample or packet metrics.

arguments
    p (1,1) struct
    model (1,1) struct
    methodName (1,1) string
    scores
    truth
    pfaTarget (1,1) double {mustBeGreaterThanOrEqual(pfaTarget, 0), mustBeLessThanOrEqual(pfaTarget, 1)}
    opts.policy (1,1) string = "min_pe_under_pfa"
    opts.pfaSlack (1,1) double {mustBeNonnegative} = 0
    opts.maxCandidates (1,1) double {mustBeInteger, mustBePositive} = 257
    opts.evalFramesPerPoint (1,1) double {mustBeInteger, mustBePositive} = 2
    opts.evalEbN0dBList double = [6 8 10]
    opts.evalJsrDbList double = 0
    opts.evalRngSeed (1,1) double = NaN
    opts.verbose (1,1) logical = false
end

policy = lower(string(opts.policy));
samplePolicies = ["min_pe_under_pfa", "max_pd_under_pfa", "min_pe"];
packetPolicies = ["min_packet_ber", "min_packet_per"];

if any(policy == samplePolicies)
    [threshold, chosenMetrics, selection] = ml_select_threshold_for_pfa(scores, truth, pfaTarget, ...
        "policy", policy, "pfaSlack", opts.pfaSlack, "maxCandidates", opts.maxCandidates);
    return;
end
if ~any(policy == packetPolicies)
    error("ml_select_impulse_threshold:UnsupportedPolicy", ...
        "Unsupported impulse threshold policy: %s.", char(policy));
end

scores = double(scores(:));
truth = logical(truth(:));
valid = isfinite(scores);
scores = scores(valid);
truth = truth(valid);

[candidates, fallbackUsed, fallbackReason] = local_candidate_thresholds(scores, truth, pfaTarget, opts.maxCandidates);
candidateCount = numel(candidates);
sampleMetricsCell = cell(candidateCount, 1);
samplePd = nan(candidateCount, 1);
samplePfa = nan(candidateCount, 1);
samplePe = nan(candidateCount, 1);
packetMetricsCell = cell(candidateCount, 1);
meanBer = nan(candidateCount, 1);
meanPer = nan(candidateCount, 1);
meanFrontEnd = nan(candidateCount, 1);
meanHeader = nan(candidateCount, 1);
meanPayload = nan(candidateCount, 1);

evalRngSeed = opts.evalRngSeed;
if ~isfinite(evalRngSeed)
    evalRngSeed = ml_resolve_rng_seed(p, NaN) + 4096;
end
evalEbN0dBList = double(opts.evalEbN0dBList(:).');
evalJsrDbList = double(opts.evalJsrDbList(:).');

for k = 1:candidateCount
    thresholdNow = candidates(k);
    sampleMetricsNow = ml_binary_metrics(scores, truth, thresholdNow);
    sampleMetricsCell{k} = sampleMetricsNow;
    samplePd(k) = sampleMetricsNow.pd;
    samplePfa(k) = sampleMetricsNow.pfa;
    samplePe(k) = sampleMetricsNow.pe;

    modelNow = model;
    modelNow.threshold = thresholdNow;
    modelNow.trained = true;
    packetMetricsNow = local_evaluate_packet_threshold( ...
        p, modelNow, methodName, evalEbN0dBList, evalJsrDbList, opts.evalFramesPerPoint, evalRngSeed);
    packetMetricsCell{k} = packetMetricsNow;
    meanBer(k) = packetMetricsNow.meanBer;
    meanPer(k) = packetMetricsNow.meanPer;
    meanFrontEnd(k) = packetMetricsNow.meanFrontEndSuccessRate;
    meanHeader(k) = packetMetricsNow.meanHeaderSuccessRate;
    meanPayload(k) = packetMetricsNow.meanPayloadSuccessRate;

    if opts.verbose
        fprintf("[threshold-select] %s candidate %d/%d: thr=%.4f, BER=%.4f, PER=%.4f, header=%.4f, payload=%.4f\n", ...
            char(methodName), k, candidateCount, thresholdNow, meanBer(k), meanPer(k), meanHeader(k), meanPayload(k));
    end
end

bestIdx = local_select_packet_best_index(policy, meanBer, meanPer, meanHeader, meanPayload, candidates);
threshold = candidates(bestIdx);
chosenMetrics = struct( ...
    "policy", policy, ...
    "sampleMetrics", sampleMetricsCell{bestIdx}, ...
    "packetMetrics", packetMetricsCell{bestIdx});
selection = struct( ...
    "policy", policy, ...
    "pfaTarget", pfaTarget, ...
    "pfaSlack", opts.pfaSlack, ...
    "candidateCount", candidateCount, ...
    "fallbackUsed", fallbackUsed, ...
    "fallbackReason", string(fallbackReason), ...
    "chosenThreshold", threshold, ...
    "chosenMetrics", chosenMetrics, ...
    "candidateThresholds", candidates(:), ...
    "candidatePd", samplePd, ...
    "candidatePfa", samplePfa, ...
    "candidatePe", samplePe, ...
    "candidateMeanBer", meanBer, ...
    "candidateMeanPer", meanPer, ...
    "candidateMeanFrontEndSuccessRate", meanFrontEnd, ...
    "candidateMeanHeaderSuccessRate", meanHeader, ...
    "candidateMeanPayloadSuccessRate", meanPayload, ...
    "evalFramesPerPoint", double(opts.evalFramesPerPoint), ...
    "evalEbN0dBList", evalEbN0dBList, ...
    "evalJsrDbList", evalJsrDbList, ...
    "evalRngSeed", double(evalRngSeed));
end

function [candidates, fallbackUsed, fallbackReason] = local_candidate_thresholds(scores, truth, pfaTarget, maxCandidates)
fallbackUsed = false;
fallbackReason = "";
if isempty(scores)
    candidates = 0.5;
    fallbackUsed = true;
    fallbackReason = "empty_scores";
    return;
end

negScores = scores(~truth);
if isempty(negScores)
    candidates = 0.5;
    fallbackUsed = true;
    fallbackReason = "no_negative_samples";
    return;
end

if numel(scores) <= maxCandidates
    candidates = unique(scores);
else
    nGlobal = max(65, ceil(maxCandidates / 2));
    nTail = max(65, ceil(maxCandidates / 2));
    qGlobal = quantile(scores, linspace(0, 1, nGlobal));
    tailStart = max(0, 1 - 10 * max(pfaTarget, 1 / max(numel(negScores), 1)));
    qNeg = quantile(negScores, unique([linspace(0, 1, nTail), linspace(tailStart, 1, nTail)]));
    candidates = unique([qGlobal(:); qNeg(:)]);
end
candidates = unique([0; candidates(:); 1]);
if numel(candidates) > maxCandidates
    candidateIdx = unique(round(linspace(1, numel(candidates), maxCandidates)));
    candidates = candidates(candidateIdx);
end
end

function packetMetrics = local_evaluate_packet_threshold(p, model, methodName, ebN0dBList, jsrDbList, nFramesPerPoint, evalRngSeed)
pEval = p;
pEval.rngSeed = evalRngSeed;
pEval.sim.nFramesPerPoint = double(nFramesPerPoint);
pEval.sim.saveFigures = false;
pEval.sim.useParallel = false;
pEval.sim.parallelMode = "frames";
pEval.sim.nWorkers = 0;
pEval.sim.commonRandomFramesAcrossPoints = true;
pEval.linkBudget.ebN0dBList = ebN0dBList;
pEval.linkBudget.jsrDbList = jsrDbList;
pEval.mitigation.methods = string(methodName);
pEval.mitigation.requireTrainedModels = false;
if isfield(pEval.mitigation, "binding") && isstruct(pEval.mitigation.binding) && isfield(pEval.mitigation.binding, "enable")
    pEval.mitigation.binding.enable = false;
end
if isfield(pEval, "eve") && isstruct(pEval.eve) && isfield(pEval.eve, "enable")
    pEval.eve.enable = false;
end
if isfield(pEval, "covert") && isstruct(pEval.covert)
    if isfield(pEval.covert, "enable")
        pEval.covert.enable = false;
    end
    if isfield(pEval.covert, "warden") && isstruct(pEval.covert.warden) && isfield(pEval.covert.warden, "enable")
        pEval.covert.warden.enable = false;
    end
end
if isfield(pEval, "rxSync") && isstruct(pEval.rxSync) ...
        && isfield(pEval.rxSync, "multipathEq") && isstruct(pEval.rxSync.multipathEq)
    pEval.rxSync.multipathEq.compareMethods = "none";
end
pEval = local_force_pure_impulse_eval_channel(pEval);
pEval = local_apply_method_model(pEval, methodName, model);

resultsEval = [];
evalc("resultsEval = simulate(pEval);");
methodIdx = local_find_method_index(resultsEval.methods, methodName);
berByPoint = double(resultsEval.ber(methodIdx, :));
perByPoint = double(resultsEval.per(methodIdx, :));
frontEndByPoint = double(resultsEval.packetDiagnostics.bob.frontEndSuccessRateByMethod(methodIdx, :));
headerByPoint = double(resultsEval.packetDiagnostics.bob.headerSuccessRateByMethod(methodIdx, :));
payloadByPoint = double(resultsEval.packetDiagnostics.bob.payloadSuccessRate(methodIdx, :));

packetMetrics = struct( ...
    "meanBer", local_mean_finite_or_inf(berByPoint), ...
    "meanPer", local_mean_finite_or_inf(perByPoint), ...
    "meanFrontEndSuccessRate", local_mean_finite_or_zero(frontEndByPoint), ...
    "meanHeaderSuccessRate", local_mean_finite_or_zero(headerByPoint), ...
    "meanPayloadSuccessRate", local_mean_finite_or_zero(payloadByPoint), ...
    "berByPoint", berByPoint, ...
    "perByPoint", perByPoint, ...
    "frontEndSuccessRateByPoint", frontEndByPoint, ...
    "headerSuccessRateByPoint", headerByPoint, ...
    "payloadSuccessRateByPoint", payloadByPoint);
end

function pOut = local_force_pure_impulse_eval_channel(pIn)
pOut = pIn;
if isfield(pOut, "channel") && isstruct(pOut.channel)
    if isfield(pOut.channel, "singleTone") && isstruct(pOut.channel.singleTone)
        pOut.channel.singleTone.enable = false;
        if isfield(pOut.channel.singleTone, "weight")
            pOut.channel.singleTone.weight = 0;
        end
    end
    if isfield(pOut.channel, "narrowband") && isstruct(pOut.channel.narrowband)
        pOut.channel.narrowband.enable = false;
        if isfield(pOut.channel.narrowband, "weight")
            pOut.channel.narrowband.weight = 0;
        end
    end
    if isfield(pOut.channel, "sweep") && isstruct(pOut.channel.sweep)
        pOut.channel.sweep.enable = false;
        if isfield(pOut.channel.sweep, "weight")
            pOut.channel.sweep.weight = 0;
        end
    end
    if isfield(pOut.channel, "multipath") && isstruct(pOut.channel.multipath) ...
            && isfield(pOut.channel.multipath, "enable")
        pOut.channel.multipath.enable = false;
    end
end
end

function pOut = local_apply_method_model(pIn, methodName, model)
pOut = pIn;
methodName = lower(string(methodName));
switch methodName
    case "ml_blanking"
        pOut.mitigation.ml = model;
    case {"ml_cnn", "ml_cnn_hard"}
        pOut.mitigation.mlCnn = model;
    case {"ml_gru", "ml_gru_hard"}
        pOut.mitigation.mlGru = model;
    otherwise
        error("ml_select_impulse_threshold:UnsupportedMethod", ...
            "Unsupported impulse mitigation method for threshold selection: %s.", char(methodName));
end
end

function methodIdx = local_find_method_index(methods, methodName)
methods = lower(string(methods(:).'));
methodName = lower(string(methodName));
methodMatches = find(methods == methodName);
if isempty(methodMatches)
    error("ml_select_impulse_threshold:MethodMissingFromSimulation", ...
        "Method %s was not found in packet-threshold evaluation results.", char(methodName));
end
methodIdx = methodMatches(1);
end

function bestIdx = local_select_packet_best_index(policy, meanBer, meanPer, meanHeader, meanPayload, candidates)
meanBerRank = meanBer(:);
meanPerRank = meanPer(:);
meanHeaderRank = meanHeader(:);
meanPayloadRank = meanPayload(:);
candidates = candidates(:);
switch policy
    case "min_packet_ber"
        rank = [meanBerRank, meanPerRank, -meanPayloadRank, -meanHeaderRank, candidates];
    case "min_packet_per"
        rank = [meanPerRank, meanBerRank, -meanPayloadRank, -meanHeaderRank, candidates];
    otherwise
        error("ml_select_impulse_threshold:UnsupportedPacketPolicy", ...
            "Unsupported packet threshold policy: %s.", char(policy));
end
[~, order] = sortrows(rank);
bestIdx = order(1);
end

function value = local_mean_finite_or_inf(x)
x = double(x(:));
valid = isfinite(x);
if ~any(valid)
    value = inf;
else
    value = mean(x(valid));
end
end

function value = local_mean_finite_or_zero(x)
x = double(x(:));
valid = isfinite(x);
if ~any(valid)
    value = 0;
else
    value = mean(x(valid));
end
end
