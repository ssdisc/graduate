function [model, loaded, resolvedPath] = load_pretrained_model(modelPath, defaultFactory, opts)
%LOAD_PRETRAINED_MODEL Load a pretrained model with optional strict checks.
arguments
    modelPath
    defaultFactory
    opts.strict (1,1) logical = false
    opts.requireTrained (1,1) logical = false
    opts.allowBatchFallback (1,1) logical = true
end

referenceModel = defaultFactory();
loaded = false;
resolvedPath = "";

resolvedModelPath = local_resolve_model_path(modelPath, opts.allowBatchFallback);
if ~exist(resolvedModelPath, 'file')
    if opts.strict
        error("load_pretrained_model:ModelMissing", "Model file not found: %s", char(resolvedModelPath));
    end
    model = referenceModel;
    return;
end

s = load(resolvedModelPath, 'model');
if ~(isfield(s, 'model') && ~isempty(s.model))
    if opts.strict
        error("load_pretrained_model:MissingModelVariable", ...
            "File does not contain a valid model variable: %s", char(resolvedModelPath));
    end
    model = referenceModel;
    return;
end

candidate = s.model;
if ~model_schema_compatible(candidate, referenceModel)
    if opts.strict
        error("load_pretrained_model:SchemaMismatch", ...
            "Model schema mismatch for file: %s", char(resolvedModelPath));
    end
    model = referenceModel;
    return;
end

if opts.requireTrained && ~local_model_is_trained(candidate, referenceModel)
    error("load_pretrained_model:UntrainedModel", ...
        "Loaded model is not marked as trained: %s", char(resolvedModelPath));
end

model = candidate;
loaded = true;
resolvedPath = string(resolvedModelPath);
end

function resolvedModelPath = local_resolve_model_path(modelPath, allowBatchFallback)
resolvedModelPath = char(modelPath);
if exist(resolvedModelPath, 'file') || ~allowBatchFallback
    return;
end

[modelDir, baseName, ~] = fileparts(resolvedModelPath);
candidates = dir(fullfile(modelDir, strcat(baseName, "_*.mat")));
if isempty(candidates)
    return;
end

[~, idx] = max([candidates.datenum]);
resolvedModelPath = fullfile(modelDir, candidates(idx).name);
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
if isfield(reference, "classNames")
    ok = ok && isfield(candidate, "classNames") ...
        && isequal(string(candidate.classNames(:)).', string(reference.classNames(:)).');
end
if isfield(reference, "features")
    ok = ok && isfield(candidate, "features") ...
        && isequal(string(candidate.features(:)).', string(reference.features(:)).');
end
if isfield(reference, "trainingLogicVersion")
    ok = ok && isfield(candidate, "trainingLogicVersion") ...
        && isequal(candidate.trainingLogicVersion, reference.trainingLogicVersion);
end
end

function ok = local_model_is_trained(candidate, reference)
if isfield(reference, "trained")
    ok = isfield(candidate, "trained") && logical(candidate.trained);
else
    ok = true;
end
end
