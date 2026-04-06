function front = adaptive_ml_frontend_nominal(rxRaw, syncSymRef, totalLen, syncCfgUse, rxSyncCfg, p, waveform, modCfg, N0, mitigation)
%ADAPTIVE_ML_FRONTEND_NOMINAL  Bob-side adaptive front-end orchestration.

arguments
    rxRaw (:,1)
    syncSymRef (:,1) double
    totalLen (1,1) double {mustBePositive}
    syncCfgUse (1,1) struct
    rxSyncCfg (1,1) struct
    p (1,1) struct
    waveform (1,1) struct
    modCfg (1,1) struct
    N0 (1,1) double {mustBeNonnegative}
    mitigation (1,1) struct
end

front = struct( ...
    "ok", false, ...
    "rFull", complex(zeros(0, 1)), ...
    "reliabilityFull", zeros(0, 1), ...
    "selectedClass", "", ...
    "selectedAction", "", ...
    "confidence", NaN, ...
    "classProbabilities", zeros(0, 1), ...
    "bootstrapPath", "", ...
    "bootstrapCapture", struct(), ...
    "featureRow", zeros(1, numel(ml_interference_selector_feature_names())));

capture = adaptive_frontend_bootstrap_capture(rxRaw, syncSymRef, totalLen, syncCfgUse, mitigation, modCfg);
front.bootstrapCapture = capture;
front.bootstrapPath = string(capture.bootstrapPath);
if ~capture.ok
    return;
end

selectorModel = local_require_selector_model(mitigation);
channelLenSymbols = local_channel_len_symbols(p.channel, waveform);
[featureRow, ~] = adaptive_frontend_extract_features(capture, syncSymRef, N0, ...
    "channelLenSymbols", channelLenSymbols);
[className, confidence, classProbabilities] = ml_predict_interference_class(featureRow, selectorModel);
actionName = local_map_class_to_action(mitigation, className);

front.selectedClass = className;
front.selectedAction = actionName;
front.confidence = confidence;
front.classProbabilities = classProbabilities;
front.featureRow = featureRow;

if actionName == "none"
    rxMit = rxRaw(:);
    reliability = ones(numel(rxMit), 1);
else
    [rxMit, reliability] = mitigate_impulses(rxRaw, actionName, mitigation);
end

[startIdx, rxSync] = frame_sync(rxMit, syncSymRef, syncCfgUse);
if isempty(startIdx)
    return;
end

[rFull, okFull] = extract_fractional_block(rxSync, startIdx, totalLen, syncCfgUse, modCfg);
if ~okFull
    return;
end

front.ok = true;
front.rFull = rFull;
front.reliabilityFull = local_extract_reliability_block(reliability, startIdx, totalLen);
end

function model = local_require_selector_model(mitigation)
if ~isfield(mitigation, "selector") || isempty(mitigation.selector)
    error("adaptive_ml_frontend requires mitigation.selector.");
end
model = mitigation.selector;
if ~isfield(model, "trained") || ~logical(model.trained)
    error("adaptive_ml_frontend requires a trained selector model.");
end
end

function actionName = local_map_class_to_action(mitigation, className)
actionName = "none";
if ~(isfield(mitigation, "adaptiveFrontend") && isstruct(mitigation.adaptiveFrontend))
    error("adaptive_ml_frontend requires mitigation.adaptiveFrontend.");
end
cfg = mitigation.adaptiveFrontend;
if ~isfield(cfg, "classToAction") || ~isstruct(cfg.classToAction)
    error("mitigation.adaptiveFrontend.classToAction is required.");
end
fieldName = matlab.lang.makeValidName(char(className));
if ~isfield(cfg.classToAction, fieldName)
    error("Missing classToAction mapping for class %s.", char(className));
end
actionName = string(cfg.classToAction.(fieldName));
end

function Lh = local_channel_len_symbols(channelCfg, waveform)
Lh = 1;
if ~isfield(channelCfg, "multipath") || ~isstruct(channelCfg.multipath) ...
        || ~isfield(channelCfg.multipath, "enable") || ~channelCfg.multipath.enable
    return;
end
if isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)
    dly = double(channelCfg.multipath.pathDelaysSymbols(:));
    if ~isempty(dly)
        Lh = max(1, round(max(dly)) + 1);
    end
    return;
end
if isfield(channelCfg.multipath, "pathDelays") && ~isempty(channelCfg.multipath.pathDelays)
    dly = double(channelCfg.multipath.pathDelays(:));
    if isfield(waveform, "sps") && waveform.sps > 0
        dly = dly / double(waveform.sps);
    end
    if ~isempty(dly)
        Lh = max(1, round(max(dly)) + 1);
    end
end
end

function relBlk = local_extract_reliability_block(reliability, startPos, nSamp)
reliability = double(reliability(:));
if nSamp <= 0 || isempty(reliability)
    relBlk = zeros(0, 1);
    return;
end
idx = (1:numel(reliability)).';
t = startPos + (0:nSamp-1).';
relBlk = interp1(idx, reliability, t, "linear", 0);
relBlk = max(min(relBlk, 1), 0);
end
