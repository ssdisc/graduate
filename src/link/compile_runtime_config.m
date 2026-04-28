function p = compile_runtime_config(linkSpec)
%COMPILE_RUNTIME_CONFIG Flatten linkSpec into the runtime struct used by shared Tx/Rx helpers.

arguments
    linkSpec (1,1) struct
end

local_require_field_local(linkSpec, "linkProfile", "linkSpec");
local_require_field_local(linkSpec.linkProfile, "name", "linkSpec.linkProfile");
profileName = normalize_link_profile_name(linkSpec.linkProfile.name);
local_validate_profile_sections_local(linkSpec, profileName);

p = struct();
p.rngSeed = double(linkSpec.runtime.rngSeed);
p.sim = linkSpec.sim;
p.linkBudget = linkSpec.linkBudget;
p.channel = linkSpec.channel;
p.tx = linkSpec.commonTx.tx;
p.source = linkSpec.commonTx.source;
p.payload = linkSpec.commonTx.payload;
p.chaosEncrypt = linkSpec.commonTx.security.chaosEncrypt;
p.scramble = linkSpec.commonTx.security.scramble;
p.packet = linkSpec.commonTx.packet;
p.outerRs = linkSpec.commonTx.outerRs;
p.frame = linkSpec.commonTx.control;
p.fec = linkSpec.commonTx.innerCode;
p.interleaver = linkSpec.commonTx.interleaver;
p.mod = linkSpec.commonTx.modulation;
p.waveform = linkSpec.commonTx.waveform;
p.dsss = linkSpec.profileTx.cfg.dsss;
p.fh = linkSpec.profileTx.cfg.fh;
p.scFde = linkSpec.profileTx.cfg.scFde;
p.mitigation = linkSpec.profileRx.cfg.mitigation;
p.mitigation.methods = string(linkSpec.profileRx.cfg.methods(:).');
p.rxSync = linkSpec.profileRx.cfg.sync;
p.rxDiversity = linkSpec.profileRx.cfg.rxDiversity;
p.softMetric = linkSpec.profileRx.cfg.softMetric;
p.eve = linkSpec.extensions.eve;
p.covert = linkSpec.extensions.warden;
p.linkProfile = struct( ...
    "name", profileName, ...
    "supportedProfiles", ["impulse" "narrowband" "rayleigh_multipath" "robust_unified"]);

if isfield(linkSpec.extensions, "ml") && isstruct(linkSpec.extensions.ml)
    if isfield(linkSpec.extensions.ml, "strictModelLoad")
        p.mitigation.strictModelLoad = logical(linkSpec.extensions.ml.strictModelLoad);
    end
    if isfield(linkSpec.extensions.ml, "requireTrainedModels")
        p.mitigation.requireTrainedModels = logical(linkSpec.extensions.ml.requireTrainedModels);
    end
    if isfield(linkSpec.extensions.ml, "preloaded") && isstruct(linkSpec.extensions.ml.preloaded)
        p = local_apply_preloaded_models_local(p, linkSpec.extensions.ml.preloaded);
    end
end

p = local_finalize_runtime_config_local(p);
p = local_attach_training_profiles_local(p);
end

function local_validate_profile_sections_local(linkSpec, profileName)
requiredTop = ["runtime" "sim" "linkBudget" "channel" "commonTx" "profileTx" "profileRx" "extensions"];
for idx = 1:numel(requiredTop)
    local_require_field_local(linkSpec, requiredTop(idx), "linkSpec");
end
if string(linkSpec.profileTx.name) ~= profileName
    error("linkSpec.profileTx.name must match linkSpec.linkProfile.name.");
end
if string(linkSpec.profileRx.name) ~= profileName
    error("linkSpec.profileRx.name must match linkSpec.linkProfile.name.");
end
local_require_field_local(linkSpec.commonTx, "security", "linkSpec.commonTx");
local_require_field_local(linkSpec.commonTx.security, "chaosEncrypt", "linkSpec.commonTx.security");
local_require_field_local(linkSpec.commonTx.security, "scramble", "linkSpec.commonTx.security");
local_require_field_local(linkSpec.profileTx, "capabilities", "linkSpec.profileTx");
local_require_field_local(linkSpec.profileTx, "cfg", "linkSpec.profileTx");
local_require_field_local(linkSpec.profileTx.cfg, "dsss", "linkSpec.profileTx.cfg");
local_require_field_local(linkSpec.profileTx.cfg, "fh", "linkSpec.profileTx.cfg");
local_require_field_local(linkSpec.profileTx.cfg, "scFde", "linkSpec.profileTx.cfg");
local_require_field_local(linkSpec.profileRx, "cfg", "linkSpec.profileRx");
local_require_field_local(linkSpec.profileRx.cfg, "mitigation", "linkSpec.profileRx.cfg");
local_require_field_local(linkSpec.profileRx.cfg, "methods", "linkSpec.profileRx.cfg");
local_require_field_local(linkSpec.profileRx.cfg, "softMetric", "linkSpec.profileRx.cfg");
local_require_field_local(linkSpec.profileRx.cfg, "sync", "linkSpec.profileRx.cfg");
local_require_field_local(linkSpec.profileRx.cfg, "rxDiversity", "linkSpec.profileRx.cfg");

cap = linkSpec.profileTx.capabilities;
if logical(linkSpec.profileTx.cfg.dsss.enable) && ~logical(cap.dsss)
    error("The active profile does not support DSSS.");
end
if logical(linkSpec.profileTx.cfg.fh.enable) && ~logical(cap.fh)
    error("The active profile does not support FH.");
end
if logical(linkSpec.profileTx.cfg.scFde.enable) && ~logical(cap.scFde)
    error("The active profile does not support SC-FDE.");
end
end

function p = local_finalize_runtime_config_local(p)
if ~(isfield(p, "waveform") && isstruct(p.waveform) && isfield(p.waveform, "sps") ...
        && isfield(p.waveform, "sampleRateHz"))
    error("p.waveform.sps and p.waveform.sampleRateHz are required.");
end
waveform = resolve_waveform_cfg(p);
p.waveform.enable = waveform.enable;
p.waveform.sps = waveform.sps;
p.waveform.sampleRateHz = waveform.sampleRateHz;
p.waveform.symbolRateHz = waveform.symbolRateHz;
p.waveform.rolloff = waveform.rolloff;
p.waveform.spanSymbols = waveform.spanSymbols;
p.waveform.rxMatchedFilter = waveform.rxMatchedFilter;
if isfield(waveform, "rrcTaps")
    p.waveform.rrcTaps = waveform.rrcTaps;
    p.waveform.groupDelaySamples = waveform.groupDelaySamples;
end

if ~(isfield(p, "softMetric") && isstruct(p.softMetric) && isfield(p.softMetric, "clipA"))
    error("p.softMetric.clipA is required.");
end

if ~(isfield(p, "scFde") && isstruct(p.scFde) && isfield(p.scFde, "enable"))
    error("p.scFde.enable is required.");
end

if ~(isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "enable") && logical(p.fh.enable))
    p.scFde = local_merge_struct_fields_local(p.scFde, sc_fde_payload_config(p));
    return;
end

if isfield(p.fh, "freqSet") && ~isempty(p.fh.freqSet)
    p.fh.freqSet = double(p.fh.freqSet(:).');
    p.fh.nFreqs = numel(p.fh.freqSet);
else
    if ~(isfield(p.fh, "nFreqs") && isfinite(double(p.fh.nFreqs)) && double(p.fh.nFreqs) >= 1)
        error("p.fh.nFreqs must be a positive scalar when FH is enabled.");
    end
    p.fh.nFreqs = round(double(p.fh.nFreqs));
    if p.fh.nFreqs == 1
        p.fh.freqSet = 0;
    else
        p.fh.freqSet = fh_nonoverlap_freq_set(waveform, p.fh.nFreqs);
    end
end

if ~(isfield(p, "frame") && isstruct(p.frame))
    error("p.frame is required.");
end
if ~(isfield(p.frame, "phyHeaderFhFreqSet") && ~isempty(p.frame.phyHeaderFhFreqSet))
    p.frame.phyHeaderFhFreqSet = p.fh.freqSet;
end
p.frame.phyHeaderFhSymbolsPerHop = phy_header_nondiverse_min_symbols_per_hop(p.frame, p.fh, p.fec);

if isfield(p, "rxSync") && isstruct(p.rxSync) && isfield(p.rxSync, "multipathEq") && isstruct(p.rxSync.multipathEq)
    if ~isfield(p.rxSync.multipathEq, "frequencyOffsets") || isempty(p.rxSync.multipathEq.frequencyOffsets)
        p.rxSync.multipathEq.frequencyOffsets = double(p.fh.freqSet(:).');
    end
end

p.scFde = local_merge_struct_fields_local(p.scFde, sc_fde_payload_config(p));
end

function out = local_merge_struct_fields_local(base, overlay)
if ~(isstruct(base) && isstruct(overlay))
    error("local_merge_struct_fields_local requires struct inputs.");
end
out = base;
fieldNames = string(fieldnames(overlay));
for idx = 1:numel(fieldNames)
    fieldName = fieldNames(idx);
    out.(fieldName) = overlay.(fieldName);
end
end

function p = local_apply_preloaded_models_local(p, preloaded)
if isfield(preloaded, "impulseLr")
    p.mitigation.ml = preloaded.impulseLr;
end
if isfield(preloaded, "impulseCnn")
    p.mitigation.mlCnn = preloaded.impulseCnn;
end
if isfield(preloaded, "impulseGru")
    p.mitigation.mlGru = preloaded.impulseGru;
end
if isfield(preloaded, "selector")
    p.mitigation.selector = preloaded.selector;
end
if isfield(preloaded, "narrowbandAction")
    p.mitigation.mlNarrowband = preloaded.narrowbandAction;
end
if isfield(preloaded, "narrowbandResidual")
    p.mitigation.mlNarrowbandResidual = preloaded.narrowbandResidual;
end
if isfield(preloaded, "fhErasure")
    p.mitigation.mlFhErasure = preloaded.fhErasure;
end
if isfield(preloaded, "multipathEq")
    p.rxSync.multipathEq.mlMlp = preloaded.multipathEq;
end
end

function p = local_attach_training_profiles_local(p)
if ~isfield(p.mitigation, "offlineTraining") || ~isstruct(p.mitigation.offlineTraining)
    p.mitigation.offlineTraining = struct();
end
p.mitigation.offlineTraining.impulse = ml_default_impulse_offline_training_profile(p);
end

function local_require_field_local(s, fieldName, ownerName)
fieldChar = char(string(fieldName));
if ~(isstruct(s) && isfield(s, fieldChar))
    error("%s.%s is required.", ownerName, fieldName);
end
end
