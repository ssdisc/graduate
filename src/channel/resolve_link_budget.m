function budget = resolve_link_budget(linkBudgetCfg, modInfo, txBaseAveragePowerLin, jsrEnabled)
%RESOLVE_LINK_BUDGET  Build a flattened Eb/N0 scan with an optional JSR axis.

arguments
    linkBudgetCfg (1,1) struct
    modInfo (1,1) struct
    txBaseAveragePowerLin (1,1) double
    jsrEnabled (1,1) logical = true
end

requiredFields = ["noisePsdLin" "ebN0dBList" "jsrDbList"];
for k = 1:numel(requiredFields)
    fieldName = requiredFields(k);
    if ~isfield(linkBudgetCfg, fieldName)
        error("resolve_link_budget:MissingField", ...
            "Missing required linkBudget.%s.", fieldName);
    end
end

if ~isfield(modInfo, "codeRate") || ~isfield(modInfo, "bitsPerSymbol")
    error("resolve_link_budget:InvalidModInfo", ...
        "modInfo must contain codeRate and bitsPerSymbol.");
end

txBaseAveragePowerLin = local_positive_scalar(txBaseAveragePowerLin, "txBaseAveragePowerLin");
noisePsdLin = local_positive_scalar(linkBudgetCfg.noisePsdLin, "linkBudget.noisePsdLin");
codeRate = local_positive_scalar(modInfo.codeRate, "modInfo.codeRate");
bitsPerSymbol = local_positive_scalar(modInfo.bitsPerSymbol, "modInfo.bitsPerSymbol");
bitLoad = codeRate * bitsPerSymbol;

ebN0dBList = local_finite_vector(linkBudgetCfg.ebN0dBList, "linkBudget.ebN0dBList");
if jsrEnabled
    jsrDbList = local_finite_vector(linkBudgetCfg.jsrDbList, "linkBudget.jsrDbList");
    scanType = "ebn0_jsr_grid";
else
    jsrDbList = 0;
    scanType = "ebn0_only";
end

nSnr = numel(ebN0dBList);
nJsr = numel(jsrDbList);
nPoints = nSnr * nJsr;

pointEbN0dB = repelem(ebN0dBList, nJsr);
pointJsrDb = repmat(jsrDbList, 1, nSnr);
snrIndex = repelem(1:nSnr, nJsr);
jsrIndex = repmat(1:nJsr, 1, nSnr);

ebN0LinPoint = 10 .^ (pointEbN0dB / 10);
txPowerLinPoint = ebN0LinPoint .* (noisePsdLin * bitLoad);
txPowerDbPoint = 10 * log10(txPowerLinPoint);
txAmplitudeScalePoint = sqrt(txPowerLinPoint / txBaseAveragePowerLin);

linkGainDbPoint = zeros(1, nPoints);
linkGainLinPoint = ones(1, nPoints);
rxAmplitudeScalePoint = txAmplitudeScalePoint;
rxPowerLinPoint = txPowerLinPoint;
noisePsdPoint = noisePsdLin * ones(1, nPoints);

bob = struct( ...
    "txPowerDb", txPowerDbPoint, ...
    "txPowerLin", txPowerLinPoint, ...
    "linkGainDb", linkGainDbPoint, ...
    "linkGainLin", linkGainLinPoint, ...
    "rxAmplitudeScale", rxAmplitudeScalePoint, ...
    "rxPowerLin", rxPowerLinPoint, ...
    "noisePsdLin", noisePsdPoint, ...
    "ebN0Lin", ebN0LinPoint, ...
    "ebN0dB", pointEbN0dB, ...
    "jsrDb", pointJsrDb, ...
    "snrIndex", snrIndex, ...
    "jsrIndex", jsrIndex);

budget = struct( ...
    "scanType", scanType, ...
    "nSnr", nSnr, ...
    "nJsr", nJsr, ...
    "nPoints", nPoints, ...
    "snrDbList", ebN0dBList, ...
    "jsrDbList", jsrDbList, ...
    "txPowerLinList", txPowerLinPoint, ...
    "txPowerDbList", txPowerDbPoint, ...
    "txAmplitudeScaleList", txAmplitudeScalePoint, ...
    "noisePsdLin", noisePsdLin, ...
    "baseTxAveragePowerLin", txBaseAveragePowerLin, ...
    "bitsPerSymbol", bitsPerSymbol, ...
    "codeRate", codeRate, ...
    "bitLoad", bitLoad, ...
    "bob", bob);
end

function value = local_positive_scalar(raw, fieldName)
value = double(raw);
if ~isscalar(value) || ~isfinite(value) || value <= 0
    error("resolve_link_budget:InvalidPositiveScalar", ...
        "%s must be a positive finite scalar.", fieldName);
end
end

function values = local_finite_vector(raw, fieldName)
values = double(raw(:).');
if isempty(values) || any(~isfinite(values))
    error("resolve_link_budget:InvalidVector", ...
        "%s must be a non-empty finite vector.", fieldName);
end
end
