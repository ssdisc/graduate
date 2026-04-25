function profile = validate_link_profile(linkSpec)
%VALIDATE_LINK_PROFILE Validate the new independent linkSpec contract.

arguments
    linkSpec (1,1) struct
end

local_require_field_local(linkSpec, "apiVersion", "linkSpec");
if string(linkSpec.apiVersion) ~= "linkSpec.v1"
    error("Unsupported linkSpec.apiVersion: %s", string(linkSpec.apiVersion));
end

local_require_field_local(linkSpec, "linkProfile", "linkSpec");
local_require_field_local(linkSpec.linkProfile, "name", "linkSpec.linkProfile");
profile = normalize_link_profile_name(linkSpec.linkProfile.name);

requiredTop = ["runtime" "sim" "linkBudget" "channel" "commonTx" "profileTx" "profileRx" "extensions"];
for idx = 1:numel(requiredTop)
    local_require_field_local(linkSpec, requiredTop(idx), "linkSpec");
end

local_require_field_local(linkSpec.profileTx, "name", "linkSpec.profileTx");
local_require_field_local(linkSpec.profileTx, "cfg", "linkSpec.profileTx");
local_require_field_local(linkSpec.profileTx, "capabilities", "linkSpec.profileTx");
local_require_field_local(linkSpec.profileRx, "name", "linkSpec.profileRx");
local_require_field_local(linkSpec.profileRx, "cfg", "linkSpec.profileRx");

if string(linkSpec.profileTx.name) ~= profile
    error("linkSpec.profileTx.name must match linkSpec.linkProfile.name.");
end
if string(linkSpec.profileRx.name) ~= profile
    error("linkSpec.profileRx.name must match linkSpec.linkProfile.name.");
end

local_validate_capabilities_local(linkSpec.profileTx);
local_validate_methods_local(profile, linkSpec.profileRx.cfg);
local_validate_control_plane_local(linkSpec.commonTx.control);
local_validate_profile_specific_local(profile, linkSpec);

runtimeCfg = compile_runtime_config(linkSpec);
local_validate_channel_contract_local(profile, runtimeCfg);
local_validate_runtime_contract_local(profile, runtimeCfg);
end

function local_validate_capabilities_local(profileTx)
cap = profileTx.capabilities;
cfg = profileTx.cfg;
requiredCaps = ["fh" "dsss" "scFde"];
for idx = 1:numel(requiredCaps)
    fieldName = requiredCaps(idx);
    if ~isfield(cap, fieldName)
        error("linkSpec.profileTx.capabilities.%s is required.", fieldName);
    end
end

if ~(isfield(cfg, "dsss") && isstruct(cfg.dsss) && isfield(cfg.dsss, "enable"))
    error("linkSpec.profileTx.cfg.dsss.enable is required.");
end
if ~(isfield(cfg, "fh") && isstruct(cfg.fh) && isfield(cfg.fh, "enable"))
    error("linkSpec.profileTx.cfg.fh.enable is required.");
end
if ~(isfield(cfg, "scFde") && isstruct(cfg.scFde) && isfield(cfg.scFde, "enable"))
    error("linkSpec.profileTx.cfg.scFde.enable is required.");
end

if logical(cfg.dsss.enable) && ~logical(cap.dsss)
    error("The active profile does not support DSSS in profileTx.cfg.dsss.");
end
if logical(cfg.fh.enable) && ~logical(cap.fh)
    error("The active profile does not support FH in profileTx.cfg.fh.");
end
if logical(cfg.scFde.enable) && ~logical(cap.scFde)
    error("The active profile does not support SC-FDE in profileTx.cfg.scFde.");
end
end

function local_validate_methods_local(profile, profileRxCfg)
if ~(isfield(profileRxCfg, "methods") && ~isempty(profileRxCfg.methods))
    error("linkSpec.profileRx.cfg.methods must not be empty.");
end
methods = unique(string(profileRxCfg.methods(:).'), "stable");
allowed = local_allowed_methods_local(profile);
invalid = methods(~ismember(methods, allowed));
if ~isempty(invalid)
    error("Unsupported %s receiver methods: %s.", char(profile), strjoin(cellstr(invalid), ", "));
end
end

function local_validate_control_plane_local(frameCfg)
mode = string(session_transport_mode(frameCfg));
if mode ~= "embedded_each_frame"
    error("Core refactored links only support frame.sessionHeaderMode='embedded_each_frame'. Got %s.", mode);
end
if ~(isfield(frameCfg, "phyHeaderMode") && lower(string(frameCfg.phyHeaderMode)) == "compact_fec")
    error("Core refactored links require frame.phyHeaderMode='compact_fec'.");
end
for fieldName = ["sessionHeaderBodyDiversity" "preambleDiversity" "phyHeaderDiversity"]
    fieldChar = char(fieldName);
    if isfield(frameCfg, fieldChar) && isstruct(frameCfg.(fieldChar)) ...
            && isfield(frameCfg.(fieldChar), "enable") && logical(frameCfg.(fieldChar).enable)
        error("Core refactored links do not allow frame.%s.enable=true.", fieldName);
    end
end
end

function local_validate_profile_specific_local(profile, linkSpec)
profileTx = linkSpec.profileTx.cfg;
control = linkSpec.commonTx.control;
switch profile
    case "impulse"
        if logical(profileTx.fh.enable)
            error("impulse profile does not allow FH.");
        end
        if logical(profileTx.scFde.enable)
            error("impulse profile does not allow SC-FDE.");
        end
        if isfield(control, "phyHeaderFhEnable") && logical(control.phyHeaderFhEnable)
            error("impulse profile does not allow PHY-header FH.");
        end
    case "narrowband"
        if ~logical(profileTx.fh.enable)
            error("narrowband profile requires FH payload mapping.");
        end
        if logical(profileTx.scFde.enable)
            error("narrowband profile does not allow SC-FDE.");
        end
        if ~(isfield(control, "phyHeaderFhEnable") && logical(control.phyHeaderFhEnable))
            error("narrowband profile requires PHY-header FH protection.");
        end
    case "rayleigh_multipath"
        if ~logical(profileTx.scFde.enable)
            error("rayleigh_multipath profile requires SC-FDE payload mapping.");
        end
        if ~logical(profileTx.fh.enable)
            error("rayleigh_multipath profile requires hop-structured payload framing.");
        end
        if isfield(control, "phyHeaderFhEnable") && logical(control.phyHeaderFhEnable)
            error("rayleigh_multipath profile does not allow PHY-header FH.");
        end
    otherwise
        error("Unexpected profile: %s", char(profile));
end
end

function local_validate_channel_contract_local(profile, p)
activeTypes = local_active_channel_types_local(p.channel);
if numel(activeTypes) > 1
    error("Mixed interference is not part of the refactored core links. Active channel types: %s.", ...
        strjoin(cellstr(activeTypes), ", "));
end
if isempty(activeTypes)
    return;
end
expected = local_expected_channel_type_local(profile);
if activeTypes(1) ~= expected
    error("Profile %s only supports the %s channel in the refactored core, got %s.", ...
        char(profile), char(expected), char(activeTypes(1)));
end
end

function local_validate_runtime_contract_local(profile, p)
switch profile
    case "narrowband"
        if ~(isfield(p.fh, "enable") && logical(p.fh.enable))
            error("narrowband runtime requires p.fh.enable=true.");
        end
        if numel(double(p.fh.freqSet(:))) < 2
            error("narrowband runtime requires at least two FH frequencies.");
        end
    case "rayleigh_multipath"
        if ~(isfield(p.scFde, "enable") && logical(p.scFde.enable))
            error("rayleigh_multipath runtime requires p.scFde.enable=true.");
        end
        if ~(isfield(p.channel, "multipath") && isstruct(p.channel.multipath) && logical(p.channel.multipath.enable))
            error("rayleigh_multipath runtime requires channel.multipath.enable=true.");
        end
        delays = double(p.channel.multipath.pathDelaysSymbols(:));
        if isempty(delays)
            delays = 0;
        end
        maxDelay = max(delays);
        if ~(isfield(p.scFde, "cpLen") && isfinite(double(p.scFde.cpLen)))
            error("rayleigh_multipath runtime requires resolved p.scFde.cpLen.");
        end
        if maxDelay > double(p.scFde.cpLen)
            error("rayleigh_multipath requires SC-FDE CP >= max path delay. Got cp=%g, maxDelay=%g.", ...
                double(p.scFde.cpLen), maxDelay);
        end
end

if ~(isfield(p.linkBudget, "noisePsdLin") && double(p.linkBudget.noisePsdLin) > 0)
    error("linkBudget.noisePsdLin must be positive.");
end
if profile ~= "narrowband" && numel(double(p.linkBudget.jsrDbList(:))) > 1
    error("Only narrowband profile supports a JSR sweep in the refactored core.");
end
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
        allowed = ["none" "fh_erasure"];
    case "rayleigh_multipath"
        allowed = ["none" "sc_fde_mmse"];
    otherwise
        error("Unexpected profile: %s", char(profile));
end
end

function local_require_field_local(s, fieldName, ownerName)
fieldChar = char(string(fieldName));
if ~(isstruct(s) && isfield(s, fieldChar))
    error("%s.%s is required.", ownerName, fieldName);
end
end
