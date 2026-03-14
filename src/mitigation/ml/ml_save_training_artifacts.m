function [report, artifacts] = ml_save_training_artifacts(model, report, baseName, opts)
%ML_SAVE_TRAINING_ARTIFACTS  保存训练得到的最佳模型与报告。
arguments
    model (1,1) struct
    report (1,1) struct
    baseName (1,1) string
    opts.saveDir (1,1) string = "models"
    opts.saveTag (1,1) string = ""
    opts.savedBy (1,1) string = ""
end

baseName = strip(baseName);
if strlength(baseName) == 0
    error("baseName 不能为空。");
end

saveDir = strip(opts.saveDir);
if strlength(saveDir) == 0
    saveDir = "models";
end
if ~exist(char(saveDir), 'dir')
    mkdir(char(saveDir));
end

if strlength(opts.saveTag) == 0
    batchTag = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
else
    batchTag = strip(opts.saveTag);
end

savedBy = strip(opts.savedBy);
if strlength(savedBy) == 0
    savedBy = "ml_save_training_artifacts";
end
savedAt = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));

latestPath = fullfile(char(saveDir), sprintf('%s.mat', char(baseName)));
batchPath = fullfile(char(saveDir), sprintf('%s_%s.mat', char(baseName), char(batchTag)));

artifacts = struct( ...
    "saved", true, ...
    "saveDir", string(saveDir), ...
    "latestPath", string(latestPath), ...
    "batchPath", string(batchPath), ...
    "batchTag", batchTag, ...
    "savedAt", savedAt, ...
    "savedBy", savedBy);

report.artifacts = artifacts;
meta = struct( ...
    "batchTag", char(batchTag), ...
    "savedBy", char(savedBy), ...
    "savedAt", char(savedAt), ...
    "baseName", char(baseName), ...
    "saveDir", char(saveDir));

save(latestPath, 'model', 'report', 'meta');
save(batchPath, 'model', 'report', 'meta');
end
