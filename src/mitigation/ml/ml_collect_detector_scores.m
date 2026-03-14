function [scores, truth] = ml_collect_detector_scores(rxSet, ySet, detectorFn)
%ML_COLLECT_DETECTOR_SCORES  收集序列检测器在数据集上的分数与标签。

scores = zeros(0, 1);
truth = false(0, 1);
for b = 1:numel(rxSet)
    [~, ~, ~, pImpulse] = detectorFn(complex(rxSet{b}));
    scores = [scores; double(pImpulse(:))];
    truth = [truth; logical(ySet{b}(:))];
end
end
