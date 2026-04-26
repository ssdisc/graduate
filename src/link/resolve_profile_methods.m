function [activeMethods, activeTypes, allowedMethods] = resolve_profile_methods(linkSpec)
%RESOLVE_PROFILE_METHODS Resolve methods against the active independent profile.

arguments
    linkSpec (1,1) struct
end

profileName = normalize_link_profile_name(linkSpec.linkProfile.name);
allowedMethods = local_allowed_methods_local(profileName);
requestedMethods = unique(string(linkSpec.profileRx.cfg.methods(:).'), "stable");
if isempty(requestedMethods)
    error("linkSpec.profileRx.cfg.methods must not be empty.");
end
invalid = requestedMethods(~ismember(requestedMethods, allowedMethods));
if ~isempty(invalid)
    error("Requested %s methods are unsupported: %s.", char(profileName), strjoin(cellstr(invalid), ", "));
end

activeTypes = local_active_channel_types_local(linkSpec.channel);
if numel(activeTypes) > 1
    error("Mixed interference is not supported by the refactored core. Active types: %s.", ...
        strjoin(cellstr(activeTypes), ", "));
end
expectedType = local_expected_channel_type_local(profileName);
if ~isempty(activeTypes) && activeTypes(1) ~= expectedType
    error("Profile %s expects channel type %s, got %s.", ...
        char(profileName), char(expectedType), char(activeTypes(1)));
end

activeMethods = requestedMethods;
end

function activeTypes = local_active_channel_types_local(channelCfg)
activeTypes = strings(1, 0);
if isfield(channelCfg, "impulseWeight") && double(channelCfg.impulseWeight) > 0 ...
        && isfield(channelCfg, "impulseProb") && double(channelCfg.impulseProb) > 0
    activeTypes(end + 1) = "impulse"; %#ok<AGROW>
end
if isfield(channelCfg, "singleTone") && isstruct(channelCfg.singleTone) ...
        && isfield(channelCfg.singleTone, "enable") && logical(channelCfg.singleTone.enable) ...
        && isfield(channelCfg.singleTone, "weight") && double(channelCfg.singleTone.weight) > 0
    activeTypes(end + 1) = "singleTone"; %#ok<AGROW>
end
if isfield(channelCfg, "narrowband") && isstruct(channelCfg.narrowband) ...
        && isfield(channelCfg.narrowband, "enable") && logical(channelCfg.narrowband.enable) ...
        && isfield(channelCfg.narrowband, "weight") && double(channelCfg.narrowband.weight) > 0
    activeTypes(end + 1) = "narrowband"; %#ok<AGROW>
end
if isfield(channelCfg, "sweep") && isstruct(channelCfg.sweep) ...
        && isfield(channelCfg.sweep, "enable") && logical(channelCfg.sweep.enable) ...
        && isfield(channelCfg.sweep, "weight") && double(channelCfg.sweep.weight) > 0
    activeTypes(end + 1) = "sweep"; %#ok<AGROW>
end
if isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "enable") && logical(channelCfg.multipath.enable)
    activeTypes(end + 1) = "multipath"; %#ok<AGROW>
end
end

function expected = local_expected_channel_type_local(profile)
switch profile
    case "impulse"
        expected = "impulse";
    case "narrowband"
        expected = "narrowband";
    case "rayleigh_multipath"
        expected = "multipath";
    otherwise
        error("Unexpected profile: %s", char(profile));
end
end

function allowed = local_allowed_methods_local(profile)
switch profile
    case "impulse"
        allowed = ["none" "clipping" "blanking" "adaptive_notch" "fft_notch" "stft_notch" ...
            "ml_blanking" "ml_cnn" "ml_cnn_hard" "ml_gru" "ml_gru_hard"];
    case "narrowband"
        allowed = ["none" "fh_erasure" "narrowband_notch_soft"];
    case "rayleigh_multipath"
        allowed = ["none" "sc_fde_mmse"];
    otherwise
        error("Unexpected profile: %s", char(profile));
end
end
