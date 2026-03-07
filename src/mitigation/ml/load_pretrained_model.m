function [model, loaded, resolvedPath] = load_pretrained_model(modelPath, defaultFactory)
%LOAD_PRETRAINED_MODEL  加载预训练模型，若缺失则返回默认模型。

referenceModel = defaultFactory();
loaded = false;
resolvedPath = "";

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
    if isfield(s, 'model') && ~isempty(s.model) && model_schema_compatible(s.model, referenceModel)
        model = s.model;
        loaded = true;
        resolvedPath = string(modelPath);
        return;
    end
end
model = referenceModel;
end

function ok = model_schema_compatible(candidate, reference)
ok = true;

if isfield(reference, "type")
    ok = ok && isfield(candidate, "type") ...
        && string(candidate.type) == string(reference.type);
end
if isfield(reference, "inputChannels")
    ok = ok && isfield(candidate, "inputChannels") ...
        && isequal(candidate.inputChannels, reference.inputChannels);
end
if isfield(reference, "featureVersion")
    ok = ok && isfield(candidate, "featureVersion") ...
        && isequal(candidate.featureVersion, reference.featureVersion);
end
if isfield(reference, "featureNames")
    ok = ok && isfield(candidate, "featureNames") ...
        && isequal(string(candidate.featureNames(:)).', string(reference.featureNames(:)).');
end
if isfield(reference, "features")
    ok = ok && isfield(candidate, "features") ...
        && isequal(string(candidate.features(:)).', string(reference.features(:)).');
end
end
