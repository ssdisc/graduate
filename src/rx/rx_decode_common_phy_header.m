function headerResult = rx_decode_common_phy_header(ctx, headerSym)
%RX_DECODE_COMMON_PHY_HEADER Decode the PHY header with optional diversity/action trials.

headerSym = headerSym(:);
copyLen = phy_header_single_symbol_length(ctx.runtimeCfg.frame, ctx.runtimeCfg.fec);
copies = phy_header_diversity_copies(ctx.runtimeCfg.frame);
if numel(headerSym) ~= copies * copyLen
    error("PHY-header diversity length mismatch: len=%d, copies=%d, copyLen=%d.", ...
        numel(headerSym), copies, copyLen);
end

actions = local_header_action_candidates_local(rx_primary_header_action(ctx.method), ctx.runtimeCfg.mitigation);
triedAction = "";
triedCopy = NaN;
headerOk = false;
phy = struct();
hdrBits = uint8([]);

for actionName = actions
    triedAction = actionName;
    copyCache = cell(copies, 1);
    for copyIdx = 1:copies
        triedCopy = copyIdx;
        copyRange = (copyIdx - 1) * copyLen + (1:copyLen);
        hdrUse = local_prepare_header_symbols_local(headerSym(copyRange), actionName, ctx.runtimeCfg.mitigation);
        copyCache{copyIdx} = hdrUse;
        hdrBitsNow = decode_phy_header_symbols(hdrUse, ctx.runtimeCfg.frame, ctx.runtimeCfg.fec, ctx.runtimeCfg.softMetric);
        [phyNow, okNow] = parse_phy_header_bits(hdrBitsNow, ctx.runtimeCfg.frame);
        okNow = okNow && isfield(phyNow, "packetIndex") && double(phyNow.packetIndex) == double(ctx.pkt.packetIndex);
        if okNow
            headerOk = true;
            phy = phyNow;
            hdrBits = hdrBitsNow;
            break;
        end
    end
    if headerOk
        break;
    end
    if copies > 1
        hdrCombined = local_average_header_copies_local(copyCache, copyLen);
        hdrBitsNow = decode_phy_header_symbols(hdrCombined, ctx.runtimeCfg.frame, ctx.runtimeCfg.fec, ctx.runtimeCfg.softMetric);
        [phyNow, okNow] = parse_phy_header_bits(hdrBitsNow, ctx.runtimeCfg.frame);
        okNow = okNow && isfield(phyNow, "packetIndex") && double(phyNow.packetIndex) == double(ctx.pkt.packetIndex);
        if okNow
            headerOk = true;
            phy = phyNow;
            hdrBits = hdrBitsNow;
            triedCopy = 0;
            break;
        end
    end
end

headerResult = struct( ...
    "ok", logical(headerOk), ...
    "phy", phy, ...
    "bits", uint8(hdrBits(:)), ...
    "action", triedAction, ...
    "copyIndex", double(triedCopy), ...
    "copies", double(copies), ...
    "copyLen", double(copyLen));
end

function actions = local_header_action_candidates_local(primaryAction, mitigation)
primaryAction = string(primaryAction);
if strlength(primaryAction) == 0
    primaryAction = "none";
end
actions = primaryAction;
if ~(isfield(mitigation, "headerDecodeDiversity") && isstruct(mitigation.headerDecodeDiversity))
    return;
end
cfg = mitigation.headerDecodeDiversity;
if ~(isfield(cfg, "enable") && logical(cfg.enable))
    return;
end
if ~(isfield(cfg, "actions") && ~isempty(cfg.actions))
    error("mitigation.headerDecodeDiversity.actions must not be empty when enabled.");
end
actions = unique([actions string(cfg.actions(:).')], "stable");
end

function hdrSymPrep = local_prepare_header_symbols_local(hdrSym, actionName, mitigation)
hdrSym = hdrSym(:);
actionName = string(actionName);
if any(actionName == ["none" "fh_erasure" "sc_fde_mmse"])
    hdrSymPrep = hdrSym;
    return;
end

if actionName == "fft_bandstop" && isfield(mitigation, "headerBandstop") ...
        && isstruct(mitigation.headerBandstop) ...
        && isfield(mitigation.headerBandstop, "enable") && logical(mitigation.headerBandstop.enable)
    cfg = local_header_bandstop_cfg_local(mitigation);
    [hdrSymPrep, ~] = fft_bandstop_filter(hdrSym, cfg);
    return;
end

[hdrSymPrep, ~] = mitigate_impulses(hdrSym, actionName, mitigation);
end

function cfgOut = local_header_bandstop_cfg_local(mitigation)
if ~(isfield(mitigation, "fftBandstop") && isstruct(mitigation.fftBandstop))
    error("mitigation.fftBandstop is required for header bandstop.");
end
cfgOut = mitigation.fftBandstop;
cfgOut.forcedFreqBounds = zeros(0, 2);
if ~(isfield(mitigation, "headerBandstop") && isstruct(mitigation.headerBandstop))
    return;
end

headerCfg = mitigation.headerBandstop;
overrideFields = ["peakRatio" "edgeRatio" "maxBands" "mergeGapBins" "padBins" ...
    "minBandBins" "smoothSpanBins" "fftOversample" "maxBandwidthFrac" ...
    "minFreqAbs" "suppressToFloor"];
for idx = 1:numel(overrideFields)
    fieldName = overrideFields(idx);
    if isfield(headerCfg, fieldName) && ~isempty(headerCfg.(fieldName))
        cfgOut.(fieldName) = headerCfg.(fieldName);
    end
end
end

function hdrCombined = local_average_header_copies_local(copyCache, copyLen)
hdrMat = complex(zeros(copyLen, numel(copyCache)));
for idx = 1:numel(copyCache)
    hdrMat(:, idx) = rx_fit_complex_length(copyCache{idx}, copyLen);
end
hdrCombined = mean(hdrMat, 2);
end
