function pOut = apply_link_profile(pIn, profileName)
%APPLY_LINK_PROFILE  Configure one of the three defense-chain profiles.

arguments
    pIn (1,1) struct
    profileName
end

profileName = normalize_link_profile_name(profileName);
pOut = pIn;

local_require_struct_field_local(pOut, "channel", "p");
local_require_struct_field_local(pOut, "scFde", "p");
local_require_struct_field_local(pOut, "rxSync", "p");
local_require_struct_field_local(pOut.rxSync, "multipathEq", "p.rxSync");
local_require_struct_field_local(pOut, "mitigation", "p");
local_require_struct_field_local(pOut, "fh", "p");
local_require_struct_field_local(pOut.fh, "payloadDiversity", "p.fh");
local_require_struct_field_local(pOut, "frame", "p");
local_require_struct_field_local(pOut.frame, "sessionHeaderBodyDiversity", "p.frame");
local_require_struct_field_local(pOut.frame, "preambleDiversity", "p.frame");
local_require_struct_field_local(pOut, "waveform", "p");
local_require_struct_field_local(pOut, "packet", "p");
local_require_struct_field_local(pOut, "outerRs", "p");
local_require_struct_field_local(pOut, "fec", "p");
local_require_struct_field_local(pOut.fec, "ldpc", "p.fec");

pOut = local_clear_interference_chain_local(pOut);
pOut.fh.payloadDiversity.enable = false;
pOut.frame.sessionHeaderBodyDiversity.enable = false;

switch profileName
    case "impulse"
        pOut.channel.impulseProb = local_positive_default_local(pOut.channel.impulseProb, 0.03, "p.channel.impulseProb");
        pOut.channel.impulseWeight = local_positive_default_local(pOut.channel.impulseWeight, 1, "p.channel.impulseWeight");
        pOut.channel.impulseToBgRatio = local_positive_default_local(pOut.channel.impulseToBgRatio, 50, "p.channel.impulseToBgRatio");
        pOut.scFde.enable = false;
        pOut.rxSync.multipathEq.enable = false;
        pOut.mitigation.methods = ["none" "blanking" "clipping"];

    case "narrowband"
        local_require_struct_field_local(pOut.channel, "narrowband", "p.channel");
        pOut.channel.narrowband.enable = true;
        pOut.channel.narrowband.weight = local_positive_default_local(pOut.channel.narrowband.weight, 1, "p.channel.narrowband.weight");
        pOut.waveform.sampleRateHz = 450e3;
        pOut.waveform.symbolRateHz = pOut.waveform.sampleRateHz / double(pOut.waveform.sps);
        pOut.scFde.enable = false;
        pOut.rxSync.multipathEq.enable = false;
        safeControlFreqSet = local_narrowband_control_freq_set_local(pOut.fh.freqSet);
        pOut.frame.preambleDiversity.copies = 4;
        pOut.frame.preambleDiversity.freqSet = safeControlFreqSet;
        pOut.frame.sessionHeaderBodyDiversity.enable = true;
        pOut.frame.sessionHeaderBodyDiversity.copies = 4;
        pOut.frame.sessionHeaderBodyDiversity.freqSet = safeControlFreqSet;
        pOut.fec.ldpc.rate = "1/3";
        pOut.packet.payloadBitsPerPacket = 5400;
        pOut.outerRs.dataPacketsPerBlock = 2;
        pOut.outerRs.parityPacketsPerBlock = 11;
        pOut.mitigation.methods = ["none" "fh_erasure"];

    case "rayleigh_multipath"
        local_require_struct_field_local(pOut.channel, "multipath", "p.channel");
        pOut.channel.multipath.enable = true;
        pOut.channel.multipath.rayleigh = true;
        pOut.scFde.enable = true;
        pOut.rxSync.multipathEq.enable = true;
        if ~(isfield(pOut.rxSync.multipathEq, "compareMethods") && ~isempty(pOut.rxSync.multipathEq.compareMethods))
            pOut.rxSync.multipathEq.compareMethods = "sc_fde_mmse";
        end
        pOut.mitigation.methods = "none";

    otherwise
        error("Unexpected normalized link profile: %s", char(profileName));
end

pOut.linkProfile = struct( ...
    "name", profileName, ...
    "supportedProfiles", ["impulse" "narrowband" "rayleigh_multipath"]);
end

function pOut = local_clear_interference_chain_local(pIn)
pOut = pIn;

local_require_struct_field_local(pOut.channel, "singleTone", "p.channel");
local_require_struct_field_local(pOut.channel, "narrowband", "p.channel");
local_require_struct_field_local(pOut.channel, "sweep", "p.channel");
local_require_struct_field_local(pOut.channel, "multipath", "p.channel");

pOut.channel.impulseProb = 0;
pOut.channel.impulseWeight = 0;
pOut.channel.singleTone.enable = false;
pOut.channel.singleTone.weight = 0;
pOut.channel.narrowband.enable = false;
pOut.channel.narrowband.weight = 0;
pOut.channel.sweep.enable = false;
pOut.channel.sweep.weight = 0;
pOut.channel.multipath.enable = false;
pOut.channel.multipath.rayleigh = false;
end

function value = local_positive_default_local(rawValue, defaultValue, label)
value = double(rawValue);
if ~(isscalar(value) && isfinite(value))
    error("%s must be a finite scalar.", label);
end
if value <= 0
    value = double(defaultValue);
end
if ~(isscalar(value) && isfinite(value) && value > 0)
    error("%s must resolve to a positive finite scalar.", label);
end
end

function local_require_struct_field_local(s, fieldName, ownerName)
if ~(isstruct(s) && isfield(s, fieldName))
    error("%s.%s is required.", ownerName, fieldName);
end
end

function freqSet = local_narrowband_control_freq_set_local(freqSetIn)
freqSetBase = double(freqSetIn(:).');
if numel(freqSetBase) < 8
    error("narrowband profile requires at least 8 FH frequencies for guarded control-channel diversity.");
end

midLeft = floor(numel(freqSetBase) / 2);
midRight = midLeft + 1;
leftPool = 1:max(1, midLeft - 1);
rightPool = min(numel(freqSetBase), midRight + 1):numel(freqSetBase);
if numel(leftPool) < 2 || numel(rightPool) < 2
    error("narrowband profile could not reserve guarded control-channel frequencies from %d FH tones.", numel(freqSetBase));
end

leftIdx = round(linspace(1, numel(leftPool), 2));
rightIdx = round(linspace(1, numel(rightPool), 2));
freqSet = [freqSetBase(leftPool(leftIdx)) freqSetBase(rightPool(rightIdx))];
end
