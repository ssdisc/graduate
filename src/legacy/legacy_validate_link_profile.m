function profile = legacy_validate_link_profile(p)
%VALIDATE_LINK_PROFILE  Validate that the configured chain matches the selected profile.

arguments
    p (1,1) struct
end

if ~(isfield(p, "linkProfile") && isstruct(p.linkProfile) && isfield(p.linkProfile, "name"))
    error("p.linkProfile.name is required.");
end
if ~(isfield(p, "channel") && isstruct(p.channel))
    error("p.channel is required.");
end
if ~(isfield(p, "scFde") && isstruct(p.scFde) && isfield(p.scFde, "enable"))
    error("p.scFde.enable is required.");
end
if ~(isfield(p, "rxSync") && isstruct(p.rxSync) ...
        && isfield(p.rxSync, "multipathEq") && isstruct(p.rxSync.multipathEq) ...
        && isfield(p.rxSync.multipathEq, "enable"))
    error("p.rxSync.multipathEq.enable is required.");
end

profile = normalize_link_profile_name(p.linkProfile.name);
activeTypes = local_active_channel_types_local(p.channel);
activeText = strjoin(cellstr(activeTypes), ", ");
if isempty(activeText)
    activeText = "none";
end

scFdeEnable = local_logical_scalar_local(p.scFde.enable, "p.scFde.enable");
multipathEqEnable = local_logical_scalar_local(p.rxSync.multipathEq.enable, "p.rxSync.multipathEq.enable");

switch profile
    case "impulse"
        if ~isequal(activeTypes, "impulse")
            error("link profile impulse requires active channel type impulse only, got: %s.", activeText);
        end
        if scFdeEnable
            error("link profile impulse requires p.scFde.enable=false.");
        end
        if multipathEqEnable
            error("link profile impulse requires p.rxSync.multipathEq.enable=false.");
        end

    case "narrowband"
        if ~isequal(activeTypes, "narrowband")
            error("link profile narrowband requires active channel type narrowband only, got: %s.", activeText);
        end
        if scFdeEnable
            error("link profile narrowband requires p.scFde.enable=false.");
        end
        if multipathEqEnable
            error("link profile narrowband requires p.rxSync.multipathEq.enable=false.");
        end

    case "rayleigh_multipath"
        if ~isequal(activeTypes, "multipath")
            error("link profile rayleigh_multipath requires active channel type multipath only, got: %s.", activeText);
        end
        if ~local_channel_rayleigh_enabled_local(p.channel)
            error("link profile rayleigh_multipath requires p.channel.multipath.rayleigh=true.");
        end
        if ~scFdeEnable
            error("link profile rayleigh_multipath requires p.scFde.enable=true.");
        end
        if ~multipathEqEnable
            error("link profile rayleigh_multipath requires p.rxSync.multipathEq.enable=true.");
        end

    otherwise
        error("Unexpected normalized link profile: %s", char(profile));
end
end

function activeTypes = local_active_channel_types_local(channelCfg)
activeTypes = strings(1, 0);

impulseProb = local_nonnegative_scalar_local(channelCfg, "impulseProb", "p.channel");
impulseWeight = local_nonnegative_scalar_local(channelCfg, "impulseWeight", "p.channel");
if impulseProb > 0 && impulseWeight > 0
    activeTypes(end + 1) = "impulse"; %#ok<AGROW>
end
if local_nested_enable_with_weight_local(channelCfg, "singleTone")
    activeTypes(end + 1) = "singleTone"; %#ok<AGROW>
end
if local_nested_enable_with_weight_local(channelCfg, "narrowband")
    activeTypes(end + 1) = "narrowband"; %#ok<AGROW>
end
if local_nested_enable_with_weight_local(channelCfg, "sweep")
    activeTypes(end + 1) = "sweep"; %#ok<AGROW>
end
if local_channel_multipath_enabled_local(channelCfg)
    activeTypes(end + 1) = "multipath"; %#ok<AGROW>
end
end

function tf = local_nested_enable_with_weight_local(channelCfg, fieldName)
if ~(isfield(channelCfg, fieldName) && isstruct(channelCfg.(fieldName)))
    error("p.channel.%s is required.", fieldName);
end
cfg = channelCfg.(fieldName);
if ~(isfield(cfg, "enable") && isfield(cfg, "weight"))
    error("p.channel.%s.enable and p.channel.%s.weight are required.", fieldName, fieldName);
end
tf = local_logical_scalar_local(cfg.enable, "p.channel." + fieldName + ".enable") ...
    && local_nonnegative_scalar_local(cfg, "weight", "p.channel." + fieldName) > 0;
end

function tf = local_channel_multipath_enabled_local(channelCfg)
if ~(isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "enable"))
    error("p.channel.multipath.enable is required.");
end
tf = local_logical_scalar_local(channelCfg.multipath.enable, "p.channel.multipath.enable");
end

function tf = local_channel_rayleigh_enabled_local(channelCfg)
if ~(isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "rayleigh"))
    error("p.channel.multipath.rayleigh is required.");
end
tf = local_logical_scalar_local(channelCfg.multipath.rayleigh, "p.channel.multipath.rayleigh");
end

function value = local_nonnegative_scalar_local(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s.%s is required.", ownerName, fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("%s.%s must be a nonnegative finite scalar.", ownerName, fieldName);
end
end

function tf = local_logical_scalar_local(raw, label)
if ~(islogical(raw) || isnumeric(raw))
    error("%s must be a logical scalar.", char(string(label)));
end
tf = logical(raw);
if ~isscalar(tf)
    error("%s must be a logical scalar.", char(string(label)));
end
end

