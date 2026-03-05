function model = load_pretrained_model(modelPath, defaultFactory)
%LOAD_PRETRAINED_MODEL  加载预训练模型，若缺失则返回默认模型。

if ~exist(modelPath, 'file')
    [modelDir, baseName, ~] = fileparts(modelPath);
    candidates = dir(fullfile(modelDir, strcat(baseName, "_*.mat")));
    if ~isempty(candidates)
        [~, idx] = max([candidates.datenum]);
        modelPath = fullfile(modelDir, candidates(idx).name);
    end
end
if exist(modelPath, 'file')
    s = load(modelPath, 'model');
    if isfield(s, 'model') && ~isempty(s.model)
        model = s.model;
        return;
    end
end
model = defaultFactory();
end

