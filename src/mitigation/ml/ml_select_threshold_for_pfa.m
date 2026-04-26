function [threshold, chosenMetrics, selection] = ml_select_threshold_for_pfa(scores, truth, pfaTarget, opts)
%ML_SELECT_THRESHOLD_FOR_PFA  在满足PFA约束前提下基于验证集指标选择检测阈值。
arguments
    scores
    truth
    pfaTarget (1,1) double {mustBeGreaterThanOrEqual(pfaTarget, 0), mustBeLessThanOrEqual(pfaTarget, 1)}
    opts.policy (1,1) string = "min_pe_under_pfa"
    opts.pfaSlack (1,1) double {mustBeNonnegative} = 0
    opts.maxCandidates (1,1) double {mustBeInteger, mustBePositive} = 257
    opts.beta (1,1) double {mustBePositive} = 2.0
end

scores = double(scores(:));
truth = logical(truth(:));

valid = isfinite(scores);
scores = scores(valid);
truth = truth(valid);

if isempty(scores)
    threshold = 0.5;
    chosenMetrics = ml_binary_metrics(scores, truth, threshold);
    selection = struct( ...
        "policy", string(opts.policy), ...
        "pfaTarget", pfaTarget, ...
        "pfaSlack", opts.pfaSlack, ...
        "candidateCount", 1, ...
        "feasibleCount", 0, ...
        "fallbackUsed", true, ...
        "fallbackReason", "empty_scores", ...
        "chosenThreshold", threshold, ...
        "chosenMetrics", chosenMetrics);
    return;
end

negScores = scores(~truth);
if isempty(negScores)
    threshold = 0.5;
    chosenMetrics = ml_binary_metrics(scores, truth, threshold);
    selection = struct( ...
        "policy", string(opts.policy), ...
        "pfaTarget", pfaTarget, ...
        "pfaSlack", opts.pfaSlack, ...
        "candidateCount", 1, ...
        "feasibleCount", 0, ...
        "fallbackUsed", true, ...
        "fallbackReason", "no_negative_samples", ...
        "chosenThreshold", threshold, ...
        "chosenMetrics", chosenMetrics);
    return;
end

candidates = local_candidate_thresholds(scores, negScores, pfaTarget, opts.maxCandidates);
metricsCell = cell(numel(candidates), 1);
pdArr = nan(numel(candidates), 1);
pfaArr = nan(numel(candidates), 1);
peArr = nan(numel(candidates), 1);
precisionArr = nan(numel(candidates), 1);
fbetaArr = nan(numel(candidates), 1);
for k = 1:numel(candidates)
    metricsNow = ml_binary_metrics(scores, truth, candidates(k));
    metricsCell{k} = metricsNow;
    pdArr(k) = metricsNow.pd;
    pfaArr(k) = metricsNow.pfa;
    peArr(k) = metricsNow.pe;
    precisionArr(k) = metricsNow.precision;
    fbetaArr(k) = local_fbeta_local(metricsNow.precision, metricsNow.recall, opts.beta);
end

feasibleLimit = pfaTarget * (1 + opts.pfaSlack);
feasible = isfinite(pfaArr) & (pfaArr <= feasibleLimit);
fallbackUsed = false;
fallbackReason = "";
searchIdx = find(feasible);
if isempty(searchIdx)
    fallbackUsed = true;
    fallbackReason = "no_threshold_within_pfa_limit";
    searchIdx = (1:numel(candidates)).';
end

bestIdx = local_select_best_index(searchIdx, string(opts.policy), pdArr, pfaArr, peArr, precisionArr, fbetaArr, candidates);
threshold = candidates(bestIdx);
chosenMetrics = metricsCell{bestIdx};
selection = struct( ...
    "policy", string(opts.policy), ...
    "beta", double(opts.beta), ...
    "pfaTarget", pfaTarget, ...
    "pfaSlack", opts.pfaSlack, ...
    "candidateCount", numel(candidates), ...
    "feasibleCount", nnz(feasible), ...
    "fallbackUsed", fallbackUsed, ...
    "fallbackReason", string(fallbackReason), ...
    "chosenThreshold", threshold, ...
    "chosenMetrics", chosenMetrics, ...
    "candidateThresholds", candidates(:), ...
    "candidatePd", pdArr, ...
    "candidatePfa", pfaArr, ...
    "candidatePe", peArr, ...
    "candidatePrecision", precisionArr, ...
    "candidateFbeta", fbetaArr);
end

function candidates = local_candidate_thresholds(scores, negScores, pfaTarget, maxCandidates)
scores = double(scores(:));
negScores = double(negScores(:));
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
end

function bestIdx = local_select_best_index(searchIdx, policy, pdArr, pfaArr, peArr, precisionArr, fbetaArr, candidates)
searchIdx = searchIdx(:);
pdNow = pdArr(searchIdx);
pfaNow = pfaArr(searchIdx);
peNow = peArr(searchIdx);
precisionNow = precisionArr(searchIdx);
fbetaNow = fbetaArr(searchIdx);
candidatesNow = candidates(searchIdx);

pdNow(~isfinite(pdNow)) = -inf;
pfaNow(~isfinite(pfaNow)) = inf;
peNow(~isfinite(peNow)) = inf;
precisionNow(~isfinite(precisionNow)) = -inf;
fbetaNow(~isfinite(fbetaNow)) = -inf;

switch lower(policy)
    case "min_pe_under_pfa"
        rank = [peNow, pfaNow, -pdNow, candidatesNow];
    case "max_fbeta_under_pfa"
        rank = [-fbetaNow, pfaNow, peNow, -pdNow, candidatesNow];
    case "max_pd_under_pfa"
        rank = [-pdNow, pfaNow, -precisionNow, peNow, candidatesNow];
    case "min_pe"
        rank = [peNow, pfaNow, -pdNow, candidatesNow];
    otherwise
        error("未知的阈值选择策略: %s", policy);
end

[~, order] = sortrows(rank);
bestIdx = searchIdx(order(1));
end

function value = local_fbeta_local(precision, recall, beta)
precision = double(precision);
recall = double(recall);
beta = double(beta);
if ~(isfinite(precision) && isfinite(recall) && isfinite(beta) && beta > 0)
    value = NaN;
    return;
end
den = beta^2 * precision + recall;
if den <= 0
    value = NaN;
    return;
end
value = (1 + beta^2) * precision * recall / den;
end
