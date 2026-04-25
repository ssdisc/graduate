function linkSpecOut = apply_link_profile(linkSpecIn, profileName)
%APPLY_LINK_PROFILE Rebuild linkSpec around a dedicated profile.

arguments
    linkSpecIn (1,1) struct
    profileName
end

local_require_link_spec_local(linkSpecIn);
compileOpts = local_compile_options_local(linkSpecIn);
profileName = normalize_link_profile_name(profileName);

linkSpecOut = default_link_spec( ...
    "strictModelLoad", compileOpts.strictModelLoad, ...
    "requireTrainedMlModels", compileOpts.requireTrainedMlModels, ...
    "allowBatchModelFallback", compileOpts.allowBatchModelFallback, ...
    "linkProfileName", profileName, ...
    "loadMlModels", compileOpts.loadMlModels);

for fieldName = ["commonTx" "sim" "linkBudget" "extensions"]
    fieldChar = char(fieldName);
    if isfield(linkSpecIn, fieldChar)
        linkSpecOut.(fieldChar) = linkSpecIn.(fieldChar);
    end
end

if isfield(linkSpecIn, "runtime") && isstruct(linkSpecIn.runtime)
    if isfield(linkSpecIn.runtime, "rngSeed")
        linkSpecOut.runtime.rngSeed = double(linkSpecIn.runtime.rngSeed);
    end
    if isfield(linkSpecIn.runtime, "captureTxArtifacts")
        linkSpecOut.runtime.captureTxArtifacts = logical(linkSpecIn.runtime.captureTxArtifacts);
    end
    if isfield(linkSpecIn.runtime, "performance")
        linkSpecOut.runtime.performance = linkSpecIn.runtime.performance;
    end
    if isfield(linkSpecIn.runtime, "compileOptions")
        linkSpecOut.runtime.compileOptions = linkSpecIn.runtime.compileOptions;
    end
end

if isfield(linkSpecIn, "channel") && isstruct(linkSpecIn.channel)
    linkSpecOut.channel = local_rebuild_channel_local(linkSpecIn.channel, linkSpecOut.channel, profileName);
end
end

function local_require_link_spec_local(linkSpec)
if ~(isstruct(linkSpec) && isfield(linkSpec, "apiVersion"))
    error("apply_link_profile expects a linkSpec created by default_params.");
end
end

function compileOpts = local_compile_options_local(linkSpec)
if ~(isfield(linkSpec, "runtime") && isstruct(linkSpec.runtime) ...
        && isfield(linkSpec.runtime, "compileOptions") && isstruct(linkSpec.runtime.compileOptions))
    error("linkSpec.runtime.compileOptions is required.");
end
compileOpts = linkSpec.runtime.compileOptions;
requiredFields = ["strictModelLoad" "requireTrainedMlModels" "allowBatchModelFallback" "loadMlModels"];
for idx = 1:numel(requiredFields)
    fieldName = requiredFields(idx);
    if ~isfield(compileOpts, char(fieldName))
        error("linkSpec.runtime.compileOptions.%s is required.", fieldName);
    end
end
compileOpts.loadMlModels = string(compileOpts.loadMlModels(:).');
end

function channelOut = local_rebuild_channel_local(currentChannel, defaultChannel, profileName)
channelOut = currentChannel;
defaultFields = string(fieldnames(defaultChannel));
for idx = 1:numel(defaultFields)
    fieldName = defaultFields(idx);
    fieldChar = char(fieldName);
    if ~isfield(channelOut, fieldChar)
        channelOut.(fieldChar) = defaultChannel.(fieldChar);
    end
end

switch profileName
    case "impulse"
        channelOut.impulseProb = defaultChannel.impulseProb;
        channelOut.impulseWeight = defaultChannel.impulseWeight;
        channelOut.impulseToBgRatio = defaultChannel.impulseToBgRatio;
        channelOut.singleTone = defaultChannel.singleTone;
        channelOut.narrowband = defaultChannel.narrowband;
        channelOut.sweep = defaultChannel.sweep;
        channelOut.multipath = defaultChannel.multipath;

    case "narrowband"
        channelOut.impulseProb = defaultChannel.impulseProb;
        channelOut.impulseWeight = defaultChannel.impulseWeight;
        channelOut.singleTone = defaultChannel.singleTone;
        channelOut.narrowband = defaultChannel.narrowband;
        channelOut.sweep = defaultChannel.sweep;
        channelOut.multipath = defaultChannel.multipath;

    case "rayleigh_multipath"
        channelOut.impulseProb = defaultChannel.impulseProb;
        channelOut.impulseWeight = defaultChannel.impulseWeight;
        channelOut.singleTone = defaultChannel.singleTone;
        channelOut.narrowband = defaultChannel.narrowband;
        channelOut.sweep = defaultChannel.sweep;
        channelOut.multipath = defaultChannel.multipath;

    otherwise
        error("Unexpected profile name: %s", char(profileName));
end
end
