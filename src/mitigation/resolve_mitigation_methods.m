function [methodsOut, activeTypes, allowedMethods] = resolve_mitigation_methods(mitigationCfg, channelCfg)
%RESOLVE_MITIGATION_METHODS  Filter mitigation methods by active interference types.

arguments
    mitigationCfg (1,1) struct
    channelCfg (1,1) struct
end

if ~isfield(mitigationCfg, "methods")
    error("mitigation.methods is required.");
end
if ~isfield(mitigationCfg, "binding") || ~isstruct(mitigationCfg.binding)
    error("mitigation.binding is required.");
end

binding = mitigationCfg.binding;
requiredBindingFields = ["enable" "impulseMethods" "singleToneMethods" "narrowbandMethods" "sweepMethods" "mixedMethods"];
for k = 1:numel(requiredBindingFields)
    fieldName = requiredBindingFields(k);
    if ~isfield(binding, fieldName)
        error("mitigation.binding.%s is required.", fieldName);
    end
end

methodsRaw = string(mitigationCfg.methods(:).');
if isempty(methodsRaw)
    error("mitigation.methods must not be empty.");
end

activeTypes = local_active_interference_types(channelCfg);
if ~logical(binding.enable)
    methodsOut = methodsRaw;
    allowedMethods = methodsRaw;
    return;
end

allowedMethods = strings(1, 0);
if isempty(activeTypes)
    allowedMethods = "none";
else
    for k = 1:numel(activeTypes)
        typeNow = activeTypes(k);
        switch typeNow
            case "impulse"
                allowedMethods = [allowedMethods, local_method_vector(binding.impulseMethods, "mitigation.binding.impulseMethods")]; %#ok<AGROW>
            case "singleTone"
                allowedMethods = [allowedMethods, local_method_vector(binding.singleToneMethods, "mitigation.binding.singleToneMethods")]; %#ok<AGROW>
            case "narrowband"
                allowedMethods = [allowedMethods, local_method_vector(binding.narrowbandMethods, "mitigation.binding.narrowbandMethods")]; %#ok<AGROW>
            case "sweep"
                allowedMethods = [allowedMethods, local_method_vector(binding.sweepMethods, "mitigation.binding.sweepMethods")]; %#ok<AGROW>
            otherwise
                error("Unsupported active interference type: %s", typeNow);
        end
    end
    if numel(activeTypes) > 1
        allowedMethods = [allowedMethods, local_method_vector(binding.mixedMethods, "mitigation.binding.mixedMethods")]; %#ok<AGROW>
    end
end
allowedMethods = unique(allowedMethods, "stable");

methodsOut = methodsRaw(ismember(methodsRaw, allowedMethods));
if isempty(methodsOut)
    error("No mitigation methods remain after binding filter. Active interference types: %s.", ...
        strjoin(cellstr(activeTypes), ", "));
end
end

function activeTypes = local_active_interference_types(channelCfg)
activeTypes = strings(1, 0);

impulseProb = local_numeric_field(channelCfg, "impulseProb");
impulseWeight = local_numeric_field(channelCfg, "impulseWeight");
if impulseProb > 0 && impulseWeight > 0
    activeTypes(end + 1) = "impulse"; %#ok<AGROW>
end

if local_nested_enable_with_weight(channelCfg, "singleTone")
    activeTypes(end + 1) = "singleTone"; %#ok<AGROW>
end
if local_nested_enable_with_weight(channelCfg, "narrowband")
    activeTypes(end + 1) = "narrowband"; %#ok<AGROW>
end
if local_nested_enable_with_weight(channelCfg, "sweep")
    activeTypes(end + 1) = "sweep"; %#ok<AGROW>
end
end

function value = local_numeric_field(s, fieldName)
if ~isfield(s, fieldName)
    error("channel.%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~isscalar(value) || ~isfinite(value)
    error("channel.%s must be a finite scalar.", fieldName);
end
value = max(value, 0);
end

function tf = local_nested_enable_with_weight(channelCfg, fieldName)
if ~isfield(channelCfg, fieldName) || ~isstruct(channelCfg.(fieldName))
    error("channel.%s is required.", fieldName);
end
cfg = channelCfg.(fieldName);
if ~isfield(cfg, "enable")
    error("channel.%s.enable is required.", fieldName);
end
if ~isfield(cfg, "weight")
    error("channel.%s.weight is required.", fieldName);
end
enable = cfg.enable;
if ~(islogical(enable) || isnumeric(enable))
    error("channel.%s.enable must be a logical scalar.", fieldName);
end
enable = logical(enable);
if ~isscalar(enable)
    error("channel.%s.enable must be a logical scalar.", fieldName);
end
weight = double(cfg.weight);
if ~isscalar(weight) || ~isfinite(weight)
    error("channel.%s.weight must be a finite scalar.", fieldName);
end
tf = enable && weight > 0;
end

function methods = local_method_vector(raw, label)
methods = string(raw(:).');
if isempty(methods) || any(strlength(methods) == 0)
    error("%s must be a non-empty string vector.", label);
end
end
