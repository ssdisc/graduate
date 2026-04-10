function [model, loaded, resolvedPath] = load_pretrained_model(modelPath, defaultFactory, opts)
%LOAD_PRETRAINED_MODEL Load a pretrained model with optional strict checks.
arguments
    modelPath
    defaultFactory
    opts.strict (1,1) logical = false
    opts.requireTrained (1,1) logical = false
    opts.allowBatchFallback (1,1) logical = true
    opts.expectedContext = []
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

s = load(resolvedModelPath, 'model', 'report');
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

if local_has_expected_context(opts.expectedContext)
    [contextOk, contextReason] = local_model_context_compatible(candidate, s, opts.expectedContext);
    if ~contextOk
        if opts.strict
            error("load_pretrained_model:TrainingContextMismatch", ...
                "Model training context mismatch for file: %s (%s)", char(resolvedModelPath), char(contextReason));
        end
        model = referenceModel;
        return;
    end
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

function tf = local_has_expected_context(expectedContext)
tf = ~isempty(expectedContext);
if tf && isstruct(expectedContext)
    tf = ~isempty(fieldnames(expectedContext));
end
end

function [ok, reason] = local_model_context_compatible(candidate, loadedData, expectedContext)
reason = "";
expectedContext = local_canonicalize_context(expectedContext);
candidateContext = [];

if isfield(candidate, "trainingContext") && ~isempty(candidate.trainingContext)
    candidateContext = candidate.trainingContext;
elseif isfield(loadedData, "report") && isstruct(loadedData.report) ...
        && isfield(loadedData.report, "trainingContext") && ~isempty(loadedData.report.trainingContext)
    candidateContext = loadedData.report.trainingContext;
end

if isempty(candidateContext)
    ok = false;
    reason = "missing trainingContext";
    return;
end

candidateContext = local_canonicalize_context(candidateContext);
[ok, reason] = local_context_contains_expected(candidateContext, expectedContext, "");
end

function value = local_canonicalize_context(value)
if isstruct(value)
    if ~isscalar(value)
        for idx = 1:numel(value)
            value(idx) = local_canonicalize_context(value(idx));
        end
        return;
    end
    fields = sort(fieldnames(value));
    ordered = struct();
    for k = 1:numel(fields)
        fieldName = fields{k};
        ordered.(fieldName) = local_canonicalize_context(value.(fieldName));
    end
    value = ordered;
elseif isstring(value)
    value = reshape(string(value), size(value));
elseif iscell(value)
    for k = 1:numel(value)
        value{k} = local_canonicalize_context(value{k});
    end
end
end

function [ok, reason] = local_context_contains_expected(candidateValue, expectedValue, path)
if nargin < 3
    path = "";
end

if isstruct(expectedValue)
    if ~isstruct(candidateValue)
        ok = false;
        reason = local_reason_text(path, "type mismatch");
        return;
    end
    expectedFields = fieldnames(expectedValue);
    for idx = 1:numel(expectedFields)
        fieldName = expectedFields{idx};
        if ~isfield(candidateValue, fieldName)
            ok = false;
            reason = local_reason_text(local_join_path(path, fieldName), "missing field");
            return;
        end
        [ok, reason] = local_context_contains_expected( ...
            candidateValue.(fieldName), expectedValue.(fieldName), local_join_path(path, fieldName));
        if ~ok
            return;
        end
    end
    ok = true;
    reason = "";
    return;
end

ok = isequaln(candidateValue, expectedValue);
if ok
    reason = "";
else
    reason = local_reason_text(path, "value mismatch");
end
end

function path = local_join_path(prefix, fieldName)
if strlength(string(prefix)) == 0
    path = string(fieldName);
else
    path = string(prefix) + "." + string(fieldName);
end
end

function reason = local_reason_text(path, message)
if strlength(string(path)) == 0
    reason = string(message);
else
    reason = string(path) + " " + string(message);
end
end
