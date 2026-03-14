function split = ml_split_dataset_indices(nItems, valFraction, testFraction, splitSeed)
%ML_SPLIT_DATASET_INDICES  按块划分 train/val/test 索引。

arguments
    nItems (1,1) double {mustBeInteger, mustBePositive}
    valFraction (1,1) double {mustBeGreaterThanOrEqual(valFraction, 0), mustBeLessThan(valFraction, 1)}
    testFraction (1,1) double {mustBeGreaterThanOrEqual(testFraction, 0), mustBeLessThan(testFraction, 1)}
    splitSeed (1,1) double = 1
end

if valFraction + testFraction >= 1
    error("valFraction + testFraction 必须小于 1。");
end

nVal = floor(nItems * valFraction);
nTest = floor(nItems * testFraction);

if valFraction > 0 && nVal == 0 && nItems >= 3
    nVal = 1;
end
if testFraction > 0 && nTest == 0 && nItems >= 3
    nTest = 1;
end

while nVal + nTest >= nItems
    if nTest >= nVal && nTest > 0
        nTest = nTest - 1;
    elseif nVal > 0
        nVal = nVal - 1;
    else
        break;
    end
end

nTrain = nItems - nVal - nTest;
if nTrain <= 0
    error("划分后训练集为空，请增加 nBlocks 或减小验证/测试占比。");
end

oldRng = rng;
cleanupObj = onCleanup(@() rng(oldRng));
rng(splitSeed, 'twister');
perm = randperm(nItems);

split = struct();
split.seed = splitSeed;
split.trainIdx = sort(perm(1:nTrain));
split.valIdx = sort(perm(nTrain + (1:nVal)));
split.testIdx = sort(perm(nTrain + nVal + (1:nTest)));
split.nTrain = numel(split.trainIdx);
split.nVal = numel(split.valIdx);
split.nTest = numel(split.testIdx);
split.trainFraction = split.nTrain / nItems;
split.valFraction = split.nVal / nItems;
split.testFraction = split.nTest / nItems;
clear cleanupObj;
end
