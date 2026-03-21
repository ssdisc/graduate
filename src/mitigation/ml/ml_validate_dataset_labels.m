function summary = ml_validate_dataset_labels(dataset, opts)
%ML_VALIDATE_DATASET_LABELS  汇总并校验训练标签分布，避免病态训练集。
arguments
    dataset (1,1) struct
    opts.minPositiveRate (1,1) double {mustBeNonnegative} = 0.002
    opts.maxPositiveRate (1,1) double {mustBePositive} = 0.35
end

if ~(isfield(dataset, "impMask") && iscell(dataset.impMask) && ~isempty(dataset.impMask))
    error("训练数据缺少 impMask，无法校验标签分布。");
end
if ~(isfield(dataset, "labelPositiveRate") && ~isempty(dataset.labelPositiveRate))
    error("训练数据缺少 labelPositiveRate，无法校验标签分布。");
end

blockPosRate = double(dataset.labelPositiveRate(:));
nPos = 0;
nSamples = 0;
for k = 1:numel(dataset.impMask)
    mask = logical(dataset.impMask{k});
    nPos = nPos + nnz(mask);
    nSamples = nSamples + numel(mask);
end
overallPosRate = nPos / max(nSamples, 1);

summary = struct();
summary.nSamples = nSamples;
summary.nPositive = nPos;
summary.overallPosRate = overallPosRate;
summary.blockPosRateMean = mean(blockPosRate);
summary.blockPosRateMedian = median(blockPosRate);
summary.blockPosRateMin = min(blockPosRate);
summary.blockPosRateMax = max(blockPosRate);
if isfield(dataset, "labeling") && isstruct(dataset.labeling)
    summary.labeling = dataset.labeling;
end
if isfield(dataset, "channelSampling") && isstruct(dataset.channelSampling)
    summary.channelSampling = dataset.channelSampling;
end
if isfield(dataset, "channelProfileSummary") && isstruct(dataset.channelProfileSummary)
    summary.channelProfileSummary = dataset.channelProfileSummary;
end

if overallPosRate < opts.minPositiveRate || overallPosRate > opts.maxPositiveRate
    error("训练标签正样本率 %.2f%% 超出允许范围 [%.2f%%, %.2f%%]。请调整 labelScoreThreshold 或训练信道范围。", ...
        100 * overallPosRate, 100 * opts.minPositiveRate, 100 * opts.maxPositiveRate);
end
end
