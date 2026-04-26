function metrics = ml_binary_metrics(scores, truth, threshold)
%ML_BINARY_METRICS  计算二分类检测的常用指标。

scores = double(scores(:));
truth = logical(truth(:));

valid = isfinite(scores);
scores = scores(valid);
truth = truth(valid);

pred = scores >= threshold;
pos = truth;
neg = ~truth;

metrics = struct();
metrics.threshold = threshold;
metrics.nSamples = numel(scores);
metrics.nPos = sum(pos);
metrics.nNeg = sum(neg);
metrics.tp = sum(pred & pos);
metrics.fp = sum(pred & neg);
metrics.fn = sum(~pred & pos);
metrics.tn = sum(~pred & neg);
metrics.pd = local_safe_mean(pred(pos));
metrics.pfa = local_safe_mean(pred(neg));
metrics.tpr = metrics.pd;
metrics.fpr = metrics.pfa;
metrics.precision = local_safe_ratio(metrics.tp, metrics.tp + metrics.fp);
metrics.recall = metrics.pd;
metrics.f1 = local_fbeta(metrics.precision, metrics.recall, 1.0);
if isfinite(metrics.pd) && isfinite(metrics.pfa)
    metrics.pe = 0.5 * (metrics.pfa + 1 - metrics.pd);
else
    metrics.pe = NaN;
end
end

function y = local_safe_mean(x)
if isempty(x)
    y = NaN;
else
    y = mean(double(x));
end
end

function y = local_safe_ratio(num, den)
num = double(num);
den = double(den);
if ~(isfinite(num) && isfinite(den)) || den <= 0
    y = NaN;
else
    y = num / den;
end
end

function y = local_fbeta(precision, recall, beta)
precision = double(precision);
recall = double(recall);
beta = double(beta);
if ~(isfinite(precision) && isfinite(recall) && isfinite(beta) && beta > 0)
    y = NaN;
    return;
end
den = beta^2 * precision + recall;
if den <= 0
    y = NaN;
    return;
end
y = (1 + beta^2) * precision * recall / den;
end
