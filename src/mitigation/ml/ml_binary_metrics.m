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
metrics.pd = local_safe_mean(pred(pos));
metrics.pfa = local_safe_mean(pred(neg));
metrics.tpr = metrics.pd;
metrics.fpr = metrics.pfa;
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
