function cfg = ml_require_selector_training_domain(p)
%ML_REQUIRE_SELECTOR_TRAINING_DOMAIN  Validate and return the offline selector training domain.

arguments
    p (1,1) struct
end

if ~(isfield(p, "mitigation") && isstruct(p.mitigation) ...
        && isfield(p.mitigation, "adaptiveFrontend") && isstruct(p.mitigation.adaptiveFrontend) ...
        && isfield(p.mitigation.adaptiveFrontend, "trainingDomain") && isstruct(p.mitigation.adaptiveFrontend.trainingDomain))
    error("Selector training requires p.mitigation.adaptiveFrontend.trainingDomain.");
end

cfgIn = p.mitigation.adaptiveFrontend.trainingDomain;
cfg = struct();
cfg.classNames = local_required_row_string(cfgIn, "classNames");
cfg.auxiliaryClassNames = local_required_row_string(cfgIn, "auxiliaryClassNames");
cfg.mixingProbability = local_required_unit_scalar(cfgIn, "mixingProbability");
cfg.auxiliaryClassProbability = local_required_unit_scalar(cfgIn, "auxiliaryClassProbability");

if any(cfg.auxiliaryClassNames == "clean")
    error("Selector trainingDomain.auxiliaryClassNames must not include clean.");
end
if any(~ismember(cfg.auxiliaryClassNames, cfg.classNames))
    error("Selector trainingDomain.auxiliaryClassNames must be contained in trainingDomain.classNames.");
end

cfg.impulse = local_impulse_cfg(local_required_substruct(cfgIn, "impulse"));
cfg.tone = local_tone_cfg(local_required_substruct(cfgIn, "tone"));
cfg.narrowband = local_narrowband_cfg(local_required_substruct(cfgIn, "narrowband"));
cfg.sweep = local_sweep_cfg(local_required_substruct(cfgIn, "sweep"));
cfg.multipath = local_multipath_cfg(local_required_substruct(cfgIn, "multipath"));

for className = cfg.classNames
    if className == "clean"
        continue;
    end
    if ~local_selector_class_enable_local(cfg, className)
        error("Selector trainingDomain class %s is listed in classNames but not enabled.", char(className));
    end
end
end

function sub = local_required_substruct(s, fieldName)
if ~(isfield(s, fieldName) && isstruct(s.(fieldName)) && isscalar(s.(fieldName)))
    error("Selector trainingDomain.%s must be a scalar struct.", fieldName);
end
sub = s.(fieldName);
end

function value = local_required_row_string(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("Selector trainingDomain.%s is required.", fieldName);
end
value = string(s.(fieldName)(:).');
if isempty(value) || any(strlength(value) == 0)
    error("Selector trainingDomain.%s must contain non-empty strings.", fieldName);
end
end

function value = local_required_unit_scalar(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("Selector trainingDomain.%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= 0 && value <= 1)
    error("Selector trainingDomain.%s must be a finite scalar within [0, 1].", fieldName);
end
end

function value = local_required_logical(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("Selector trainingDomain.%s is required.", fieldName);
end
value = logical(s.(fieldName));
if ~isscalar(value)
    error("Selector trainingDomain.%s must be a logical scalar.", fieldName);
end
end

function value = local_required_nonnegative_scalar(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("Selector trainingDomain.%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("Selector trainingDomain.%s must be a finite nonnegative scalar.", fieldName);
end
end

function value = local_required_range(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("Selector trainingDomain.%s is required.", fieldName);
end
value = double(s.(fieldName)(:).');
if ~(numel(value) == 2 && all(isfinite(value)) && value(1) <= value(2))
    error("Selector trainingDomain.%s must be a finite ascending [min max] range.", fieldName);
end
end

function value = local_required_nonnegative_range(s, fieldName)
value = local_required_range(s, fieldName);
if any(value < 0)
    error("Selector trainingDomain.%s must be nonnegative.", fieldName);
end
end

function value = local_required_positive_integer_range(s, fieldName)
value = local_required_range(s, fieldName);
if any(value < 1)
    error("Selector trainingDomain.%s must be positive.", fieldName);
end
value = round(value);
if value(1) > value(2)
    error("Selector trainingDomain.%s must remain ascending after rounding.", fieldName);
end
end

function cfg = local_impulse_cfg(s)
cfg = struct( ...
    "enable", local_required_logical(s, "enable"), ...
    "probRange", local_required_nonnegative_range(s, "probRange"), ...
    "toBgRatioRange", local_required_nonnegative_range(s, "toBgRatioRange"));
end

function cfg = local_tone_cfg(s)
cfg = struct( ...
    "enable", local_required_logical(s, "enable"), ...
    "powerRange", local_required_nonnegative_range(s, "powerRange"), ...
    "freqHzRange", local_required_range(s, "freqHzRange"));
end

function cfg = local_narrowband_cfg(s)
cfg = struct( ...
    "enable", local_required_logical(s, "enable"), ...
    "powerRange", local_required_nonnegative_range(s, "powerRange"), ...
    "bandwidthFreqPointsRange", local_required_nonnegative_range(s, "bandwidthFreqPointsRange"));
end

function cfg = local_sweep_cfg(s)
cfg = struct( ...
    "enable", local_required_logical(s, "enable"), ...
    "powerRange", local_required_nonnegative_range(s, "powerRange"), ...
    "startHzRange", local_required_range(s, "startHzRange"), ...
    "stopHzRange", local_required_range(s, "stopHzRange"), ...
    "periodSymbolsRange", local_required_positive_integer_range(s, "periodSymbolsRange"));
end

function cfg = local_multipath_cfg(s)
cfg = struct();
cfg.enable = local_required_logical(s, "enable");
cfg.pathDelaysSymbols = local_required_row_nonnegative(s, "pathDelaysSymbols");
cfg.pathGainsDb = local_required_row_finite(s, "pathGainsDb");
cfg.pathGainJitterDb = local_required_nonnegative_scalar(s, "pathGainJitterDb");
cfg.rayleighProbability = local_required_unit_scalar(s, "rayleighProbability");
if numel(cfg.pathDelaysSymbols) ~= numel(cfg.pathGainsDb)
    error("Selector trainingDomain.multipath.pathDelaysSymbols and pathGainsDb must have the same length.");
end
if cfg.pathDelaysSymbols(1) ~= 0
    error("Selector trainingDomain.multipath.pathDelaysSymbols must start at 0.");
end
end

function value = local_required_row_nonnegative(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("Selector trainingDomain.%s is required.", fieldName);
end
value = double(s.(fieldName)(:).');
if isempty(value) || any(~isfinite(value)) || any(value < 0)
    error("Selector trainingDomain.%s must contain finite nonnegative values.", fieldName);
end
end

function value = local_required_row_finite(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("Selector trainingDomain.%s is required.", fieldName);
end
value = double(s.(fieldName)(:).');
if isempty(value) || any(~isfinite(value))
    error("Selector trainingDomain.%s must contain finite values.", fieldName);
end
end

function tf = local_selector_class_enable_local(cfg, className)
switch lower(string(className))
    case "impulse"
        tf = cfg.impulse.enable;
    case "tone"
        tf = cfg.tone.enable;
    case "narrowband"
        tf = cfg.narrowband.enable;
    case "sweep"
        tf = cfg.sweep.enable;
    case "multipath"
        tf = cfg.multipath.enable;
    otherwise
        error("Unsupported selector trainingDomain class: %s", char(string(className)));
end
end
