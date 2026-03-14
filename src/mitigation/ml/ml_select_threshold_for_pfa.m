function threshold = ml_select_threshold_for_pfa(scores, truth, pfaTarget)
%ML_SELECT_THRESHOLD_FOR_PFA  根据目标虚警率选择检测阈值。

scores = double(scores(:));
truth = logical(truth(:));

valid = isfinite(scores);
scores = scores(valid);
truth = truth(valid);

negScores = scores(~truth);
if isempty(negScores)
    threshold = 0.5;
    return;
end

negScores = sort(negScores);
idxQ = max(1, min(numel(negScores), ceil((1 - pfaTarget) * numel(negScores))));
threshold = negScores(idxQ);
end
