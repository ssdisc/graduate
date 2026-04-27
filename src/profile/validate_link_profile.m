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
if ~(isfield(frameCfg, "phyHeaderMode") && lower(string(frameCfg.phyHeaderMode)) == "compact_fec")
    error("Core refactored links require frame.phyHeaderMode='compact_fec'.");
end

switch mode
    case "session_frame_repeat"
        session_frame_repeat_count(frameCfg);
    case "session_frame_strong"
        session_frame_strong_repeat(frameCfg);
end

preambleCopies = preamble_diversity_copies(frameCfg);
sessionCopies = session_header_body_diversity_copies(frameCfg);
phyCopies = phy_header_diversity_copies(frameCfg);
if phyCopies > 1 && ~(isfield(frameCfg, "phyHeaderFhEnable") && logical(frameCfg.phyHeaderFhEnable))
    error("frame.phyHeaderDiversity requires frame.phyHeaderFhEnable=true.");
end
if preambleCopies > 1 && ~(isfield(frameCfg, "preambleDiversity") && isstruct(frameCfg.preambleDiversity))
    error("frame.preambleDiversity config is required.");
end
if sessionCopies > 1 && ~(isfield(frameCfg, "sessionHeaderBodyDiversity") && isstruct(frameCfg.sessionHeaderBodyDiversity))
    error("frame.sessionHeaderBodyDiversity config is required.");
end
end

function local_validate_profile_specific_local(profile, linkSpec)
profileTx = linkSpec.profileTx.cfg;
control = linkSpec.commonTx.control;
preambleCopies = preamble_diversity_copies(control);
sessionCopies = session_header_body_diversity_copies(control);
phyCopies = phy_header_diversity_copies(control);
switch profile
    case "impulse"
        if logical(profileTx.scFde.enable)
            error("impulse profile does not allow SC-FDE.");
        end
        if isfield(control, "phyHeaderFhEnable") && logical(control.phyHeaderFhEnable)
            error("impulse profile does not allow PHY-header FH.");
        end
        if preambleCopies > 1 || sessionCopies > 1 || phyCopies > 1
            error("impulse profile does not allow FH-dependent control diversity.");
        end
        local_validate_chaotic_fh_contract_local(profile, profileTx.fh);
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
        local_validate_chaotic_fh_contract_local(profile, profileTx.fh);
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
        local_validate_chaotic_fh_contract_local(profile, profileTx.fh);
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
    case "impulse"
        local_validate_runtime_chaotic_fh_local(profile, p);
    case "narrowband"
        local_validate_runtime_chaotic_fh_local(profile, p);
        if ~(isfield(p.fh, "enable") && logical(p.fh.enable))
            error("narrowband runtime requires p.fh.enable=true.");
        end
        if numel(double(p.fh.freqSet(:))) < 2
            error("narrowband runtime requires at least two FH frequencies.");
        end
    case "rayleigh_multipath"
        local_validate_runtime_chaotic_fh_local(profile, p);
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
        if isfield(p, "waveform") && isstruct(p.waveform) ...
                && isfield(p.waveform, "enable") && logical(p.waveform.enable) ...
                && isfield(p.waveform, "spanSymbols") && isfinite(double(p.waveform.spanSymbols))
            effectiveMemory = maxDelay + 2 * max(0, round(double(p.waveform.spanSymbols)));
            if double(p.scFde.cpLen) < effectiveMemory
                error("rayleigh_multipath requires SC-FDE CP >= effective channel memory when pulse shaping is enabled. Got cp=%g, need >= %g (maxDelay=%g, span=%g).", ...
                    double(p.scFde.cpLen), effectiveMemory, maxDelay, double(p.waveform.spanSymbols));
            end
        end
end

if ~(isfield(p.linkBudget, "noisePsdLin") && double(p.linkBudget.noisePsdLin) > 0)
    error("linkBudget.noisePsdLin must be positive.");
end
jsrCount = numel(double(p.linkBudget.jsrDbList(:)));
if ~(profile == "impulse" || profile == "narrowband") && jsrCount > 1
    error("Only impulse and narrowband profiles support a JSR sweep in the refactored core.");
end
if profile == "impulse"
    if ~(isfield(p.channel, "impulseToBgRatio") && isfinite(double(p.channel.impulseToBgRatio)))
        error("impulse profile requires channel.impulseToBgRatio to exist for internal runtime use.");
    end
    if abs(double(p.channel.impulseToBgRatio)) > 1e-12
        error("impulse profile derives channel.impulseToBgRatio from linkBudget.jsrDbList and channel.impulseProb. Set channel.impulseToBgRatio=0.");
    end
    if jsrCount > 1
        if ~(isfield(p.channel, "impulseWeight") && double(p.channel.impulseWeight) > 0 ...
                && isfield(p.channel, "impulseProb") && double(p.channel.impulseProb) > 0)
            error("Impulse JSR sweep requires active impulse interference with channel.impulseWeight>0 and channel.impulseProb>0.");
        end
    end
end

preambleCopies = preamble_diversity_copies(p.frame);
sessionCopies = session_header_body_diversity_copies(p.frame);
phyCopies = phy_header_diversity_copies(p.frame);
fhEnable = isfield(p.fh, "enable") && logical(p.fh.enable);
if (preambleCopies > 1 || sessionCopies > 1 || logical(p.frame.phyHeaderFhEnable))
    if ~fhEnable
        error("FH-dependent control protection requires p.fh.enable=true.");
    end
    nFreqs = numel(double(p.fh.freqSet(:)));
    if preambleCopies > nFreqs
        error("frame.preambleDiversity.copies=%d exceeds available FH frequencies=%d.", preambleCopies, nFreqs);
    end
    if sessionCopies > nFreqs
        error("frame.sessionHeaderBodyDiversity.copies=%d exceeds available FH frequencies=%d.", sessionCopies, nFreqs);
    end
    if phyCopies > nFreqs
        error("frame.phyHeaderDiversity.copies=%d exceeds available FH frequencies=%d.", phyCopies, nFreqs);
    end
end
if phyCopies > 1 && ~logical(p.frame.phyHeaderFhEnable)
    error("frame.phyHeaderDiversity requires frame.phyHeaderFhEnable=true.");
end
end

function activeTypes = local_active_channel_types_local(channelCfg)
activeTypes = strings(1, 0);
if isfield(channelCfg, "impulseWeight") && double(channelCfg.impulseWeight) > 0 ...
        && isfield(channelCfg, "impulseProb") && double(channelCfg.impulseProb) > 0
    activeTypes(end + 1) = "impulse";
end
if isfield(channelCfg, "singleTone") && isstruct(channelCfg.singleTone) ...
        && isfield(channelCfg.singleTone, "enable") && logical(channelCfg.singleTone.enable) ...
        && isfield(channelCfg.singleTone, "weight") && double(channelCfg.singleTone.weight) > 0
    activeTypes(end + 1) = "singleTone";
end
if isfield(channelCfg, "narrowband") && isstruct(channelCfg.narrowband) ...
        && isfield(channelCfg.narrowband, "enable") && logical(channelCfg.narrowband.enable) ...
        && isfield(channelCfg.narrowband, "weight") && double(channelCfg.narrowband.weight) > 0
    activeTypes(end + 1) = "narrowband";
end
if isfield(channelCfg, "sweep") && isstruct(channelCfg.sweep) ...
        && isfield(channelCfg.sweep, "enable") && logical(channelCfg.sweep.enable) ...
        && isfield(channelCfg.sweep, "weight") && double(channelCfg.sweep.weight) > 0
    activeTypes(end + 1) = "sweep";
end
if isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "enable") && logical(channelCfg.multipath.enable)
    activeTypes(end + 1) = "multipath";
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
        allowed = ["none" "fh_erasure" "narrowband_notch_soft" ...
            "narrowband_subband_excision_soft" "narrowband_cnn_residual_soft"];
    case "rayleigh_multipath"
        allowed = ["none" "sc_fde_mmse"];
    otherwise
        error("Unexpected profile: %s", char(profile));
end
end

function local_validate_chaotic_fh_contract_local(profile, fhCfg)
if ~(isstruct(fhCfg) && isfield(fhCfg, "enable") && logical(fhCfg.enable))
    error("%s profile requires profileTx.cfg.fh.enable=true.", char(profile));
end
if ~(isfield(fhCfg, "sequenceType") && lower(string(fhCfg.sequenceType)) == "chaos")
    error("%s profile requires profileTx.cfg.fh.sequenceType='chaos'.", char(profile));
end
if ~(isfield(fhCfg, "chaosMethod") && strlength(string(fhCfg.chaosMethod)) > 0)
    error("%s profile requires profileTx.cfg.fh.chaosMethod.", char(profile));
end
if ~(isfield(fhCfg, "chaosParams") && isstruct(fhCfg.chaosParams))
    error("%s profile requires profileTx.cfg.fh.chaosParams.", char(profile));
end
if isfield(fhCfg, "nFreqs") && ~isempty(fhCfg.nFreqs) && double(fhCfg.nFreqs) < 2 ...
        && ~(isfield(fhCfg, "freqSet") && numel(double(fhCfg.freqSet(:))) >= 2)
    error("%s profile requires at least two FH payload frequencies.", char(profile));
end
end

function local_validate_runtime_chaotic_fh_local(profile, p)
if ~(isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "enable") && logical(p.fh.enable))
    error("%s runtime requires p.fh.enable=true.", char(profile));
end
if ~(isfield(p.fh, "sequenceType") && lower(string(p.fh.sequenceType)) == "chaos")
    error("%s runtime requires p.fh.sequenceType='chaos'.", char(profile));
end
if ~(isfield(p.fh, "chaosMethod") && strlength(string(p.fh.chaosMethod)) > 0)
    error("%s runtime requires p.fh.chaosMethod.", char(profile));
end
if ~(isfield(p.fh, "chaosParams") && isstruct(p.fh.chaosParams))
    error("%s runtime requires p.fh.chaosParams.", char(profile));
end
if numel(double(p.fh.freqSet(:))) < 2
    error("%s runtime requires at least two resolved FH frequencies.", char(profile));
end
if ~(isfield(p, "waveform") && isstruct(p.waveform) && isfield(p.waveform, "enable") && logical(p.waveform.enable) ...
        && isfield(p.waveform, "sps") && double(p.waveform.sps) > 1)
    error("%s runtime requires waveform.enable=true and waveform.sps>1 for multi-frequency chaotic FH.", char(profile));
end
end

function local_require_field_local(s, fieldName, ownerName)
fieldChar = char(string(fieldName));
if ~(isstruct(s) && isfield(s, fieldChar))
    error("%s.%s is required.", ownerName, fieldName);
end
end
