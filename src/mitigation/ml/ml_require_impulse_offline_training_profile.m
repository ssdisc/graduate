function profile = ml_require_impulse_offline_training_profile(p)
%ML_REQUIRE_IMPULSE_OFFLINE_TRAINING_PROFILE  Resolve and validate the offline impulse-training profile.

arguments
    p (1,1) struct
end

if ~(isfield(p, "mitigation") && isstruct(p.mitigation) ...
        && isfield(p.mitigation, "offlineTraining") && isstruct(p.mitigation.offlineTraining) ...
        && isfield(p.mitigation.offlineTraining, "impulse") && isstruct(p.mitigation.offlineTraining.impulse))
    error("ml_require_impulse_offline_training_profile:MissingProfile", ...
        "Impulse offline training requires p.mitigation.offlineTraining.impulse.");
end

profileSet = p.mitigation.offlineTraining.impulse;
activeProfileName = local_required_string(profileSet, "activeProfileName");
if ~(isfield(profileSet, "profiles") && isstruct(profileSet.profiles))
    error("ml_require_impulse_offline_training_profile:MissingProfiles", ...
        "p.mitigation.offlineTraining.impulse.profiles is required.");
end

availableProfileKeys = string(fieldnames(profileSet.profiles)).';
if isempty(availableProfileKeys)
    error("ml_require_impulse_offline_training_profile:EmptyProfiles", ...
        "p.mitigation.offlineTraining.impulse.profiles must not be empty.");
end

resolvedProfileKey = local_resolve_profile_key(p, activeProfileName, availableProfileKeys);
if ~isfield(profileSet.profiles, resolvedProfileKey)
    error("ml_require_impulse_offline_training_profile:UnknownResolvedProfile", ...
        "Resolved profile key %s is not defined in p.mitigation.offlineTraining.impulse.profiles.", ...
        char(resolvedProfileKey));
end

profileIn = profileSet.profiles.(resolvedProfileKey);
profile = struct();
profile.activeProfileName = activeProfileName;
profile.profileKey = local_required_string(profileIn, "profileKey");
if profile.profileKey ~= resolvedProfileKey
    error("ml_require_impulse_offline_training_profile:ProfileKeyMismatch", ...
        "Resolved profile key %s does not match profile.profileKey %s.", ...
        char(resolvedProfileKey), char(profile.profileKey));
end
profile.profileName = local_required_string(profileIn, "profileName");
profile.scenario = local_required_scenario(profileIn);
profile.logisticRegression = local_required_trainer(profileIn, "logisticRegression", true);
profile.deepLearning = local_required_trainer(profileIn, "deepLearning", false);
end

function resolvedProfileKey = local_resolve_profile_key(p, activeProfileName, availableProfileKeys)
activeProfileName = strip(string(activeProfileName));
availableProfileKeys = string(availableProfileKeys(:).');
if activeProfileName == "auto"
    [~, activeTypes] = resolve_mitigation_methods(p.mitigation, p.channel);
    activeTypes = lower(string(activeTypes(:).'));
    nonImpulseTypes = setdiff(activeTypes, "impulse", "stable");
    if isempty(nonImpulseTypes)
        resolvedProfileKey = "pure_impulse";
    else
        resolvedProfileKey = "mixed";
    end
else
    resolvedProfileKey = activeProfileName;
end

if ~any(availableProfileKeys == resolvedProfileKey)
    error("ml_require_impulse_offline_training_profile:UnknownProfileKey", ...
        "Impulse offline profile %s is not one of the configured profiles: %s.", ...
        char(resolvedProfileKey), strjoin(cellstr(availableProfileKeys), ", "));
end
end

function scenario = local_required_scenario(profileIn)
if ~(isfield(profileIn, "scenario") && isstruct(profileIn.scenario))
    error("ml_require_impulse_offline_training_profile:MissingScenario", ...
        "Impulse offline profile scenario is required.");
end

cfg = profileIn.scenario;
scenario = struct( ...
    "ebN0dBRange", local_required_range(cfg, "ebN0dBRange", -inf, inf, false), ...
    "labelScoreThreshold", local_required_positive(cfg, "labelScoreThreshold"), ...
    "thresholdPolicy", local_required_string(cfg, "thresholdPolicy"), ...
    "thresholdMaxCandidates", local_required_positive_integer(cfg, "thresholdMaxCandidates"), ...
    "thresholdEvalFramesPerPoint", local_required_positive_integer(cfg, "thresholdEvalFramesPerPoint"), ...
    "thresholdEvalEbN0dBList", local_required_numeric_vector(cfg, "thresholdEvalEbN0dBList"), ...
    "thresholdEvalJsrDbList", local_required_numeric_vector(cfg, "thresholdEvalJsrDbList"), ...
    "minPositiveRate", local_required_range(cfg, "minPositiveRate", 0, 1, true), ...
    "maxPositiveRate", local_required_range(cfg, "maxPositiveRate", 0, 1, true), ...
    "impulseEnableProbability", local_required_range(cfg, "impulseEnableProbability", 0, 1, true), ...
    "impulseProbRange", local_required_range(cfg, "impulseProbRange", 0, 1, true), ...
    "impulseToBgRatioRange", local_required_range(cfg, "impulseToBgRatioRange", 0, inf, true), ...
    "singleToneProbability", local_required_range(cfg, "singleToneProbability", 0, 1, true), ...
    "singleTonePowerRange", local_required_range(cfg, "singleTonePowerRange", 0, inf, true), ...
    "singleToneFreqHzRange", local_required_range(cfg, "singleToneFreqHzRange", -inf, inf, false), ...
    "narrowbandProbability", local_required_range(cfg, "narrowbandProbability", 0, 1, true), ...
    "narrowbandPowerRange", local_required_range(cfg, "narrowbandPowerRange", 0, inf, true), ...
    "narrowbandCenterFreqPointsRange", local_required_range(cfg, "narrowbandCenterFreqPointsRange", -inf, inf, false), ...
    "narrowbandBandwidthFreqPointsRange", local_required_range(cfg, "narrowbandBandwidthFreqPointsRange", 0, inf, true), ...
    "sweepProbability", local_required_range(cfg, "sweepProbability", 0, 1, true), ...
    "sweepPowerRange", local_required_range(cfg, "sweepPowerRange", 0, inf, true), ...
    "sweepStartHzRange", local_required_range(cfg, "sweepStartHzRange", -inf, inf, false), ...
    "sweepStopHzRange", local_required_range(cfg, "sweepStopHzRange", -inf, inf, false), ...
    "sweepPeriodSymbolsRange", local_required_range(cfg, "sweepPeriodSymbolsRange", 0, inf, true), ...
    "syncImpairmentProbability", local_required_range(cfg, "syncImpairmentProbability", 0, 1, true), ...
    "timingOffsetSymbolsRange", local_required_range(cfg, "timingOffsetSymbolsRange", -inf, inf, false), ...
    "phaseOffsetRadRange", local_required_range(cfg, "phaseOffsetRadRange", -inf, inf, false), ...
    "multipathProbability", local_required_range(cfg, "multipathProbability", 0, 1, true), ...
    "multipathRayleighProbability", local_required_range(cfg, "multipathRayleighProbability", 0, 1, true), ...
    "maxAdditionalImpairments", local_required_integer(cfg, "maxAdditionalImpairments"));

if scenario.minPositiveRate >= scenario.maxPositiveRate
    error("ml_require_impulse_offline_training_profile:InvalidPositiveRateBounds", ...
        "scenario.minPositiveRate must be smaller than scenario.maxPositiveRate.");
end
if scenario.sweepStartHzRange(2) >= scenario.sweepStopHzRange(1)
    error("ml_require_impulse_offline_training_profile:InvalidSweepRanges", ...
        "scenario.sweepStartHzRange must stay below scenario.sweepStopHzRange.");
end
end

function trainer = local_required_trainer(profileIn, fieldName, requireL2)
if ~(isfield(profileIn, fieldName) && isstruct(profileIn.(fieldName)))
    error("ml_require_impulse_offline_training_profile:MissingTrainer", ...
        "Impulse offline profile %s config is required.", fieldName);
end

cfg = profileIn.(fieldName);
trainer = struct( ...
    "nBlocks", local_required_positive_integer(cfg, "nBlocks"), ...
    "blockLen", local_required_positive_integer(cfg, "blockLen"), ...
    "epochs", local_required_positive_integer(cfg, "epochs"), ...
    "batchSize", local_required_positive_integer(cfg, "batchSize"), ...
    "lr", local_required_positive(cfg, "lr"));
if requireL2
    trainer.l2 = local_required_nonnegative(cfg, "l2");
end
end

function value = local_required_string(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("ml_require_impulse_offline_training_profile:MissingStringField", ...
        "%s is required.", fieldName);
end
value = strip(string(s.(fieldName)));
if strlength(value) == 0
    error("ml_require_impulse_offline_training_profile:EmptyStringField", ...
        "%s cannot be empty.", fieldName);
end
end

function value = local_required_range(s, fieldName, lowerBound, upperBound, nonnegativeOnly)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("ml_require_impulse_offline_training_profile:MissingRangeField", ...
        "%s is required.", fieldName);
end

value = double(s.(fieldName)(:)).';
if numel(value) == 1
    if ~(isfinite(value) && value >= lowerBound && value <= upperBound)
        error("ml_require_impulse_offline_training_profile:InvalidScalarField", ...
            "%s must be finite and within [%.6g, %.6g].", fieldName, lowerBound, upperBound);
    end
    return;
end

if numel(value) ~= 2 || any(~isfinite(value)) || value(1) > value(2)
    error("ml_require_impulse_offline_training_profile:InvalidRangeField", ...
        "%s must be an ascending finite 1x2 range.", fieldName);
end
if value(1) < lowerBound || value(2) > upperBound
    error("ml_require_impulse_offline_training_profile:OutOfBoundsRangeField", ...
        "%s must stay within [%.6g, %.6g].", fieldName, lowerBound, upperBound);
end
if nonnegativeOnly && value(1) < 0
    error("ml_require_impulse_offline_training_profile:NegativeRangeField", ...
        "%s must be non-negative.", fieldName);
end
end

function value = local_required_numeric_vector(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("ml_require_impulse_offline_training_profile:MissingVectorField", ...
        "%s is required.", fieldName);
end
value = double(s.(fieldName)(:)).';
if isempty(value) || any(~isfinite(value))
    error("ml_require_impulse_offline_training_profile:InvalidVectorField", ...
        "%s must be a non-empty finite numeric vector.", fieldName);
end
end

function value = local_required_integer(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("ml_require_impulse_offline_training_profile:MissingIntegerField", ...
        "%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= 0 && round(value) == value)
    error("ml_require_impulse_offline_training_profile:InvalidIntegerField", ...
        "%s must be a non-negative integer scalar.", fieldName);
end
end

function value = local_required_positive_integer(s, fieldName)
value = local_required_integer(s, fieldName);
if value < 1
    error("ml_require_impulse_offline_training_profile:InvalidPositiveIntegerField", ...
        "%s must be a positive integer scalar.", fieldName);
end
end

function value = local_required_positive(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("ml_require_impulse_offline_training_profile:MissingPositiveField", ...
        "%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && value > 0)
    error("ml_require_impulse_offline_training_profile:InvalidPositiveField", ...
        "%s must be a positive finite scalar.", fieldName);
end
end

function value = local_required_nonnegative(s, fieldName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("ml_require_impulse_offline_training_profile:MissingNonnegativeField", ...
        "%s is required.", fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("ml_require_impulse_offline_training_profile:InvalidNonnegativeField", ...
        "%s must be a non-negative finite scalar.", fieldName);
end
end
