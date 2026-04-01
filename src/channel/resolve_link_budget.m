function budget = resolve_link_budget(linkBudgetCfg, modInfo, txBaseAveragePowerLin)
%RESOLVE_LINK_BUDGET  Build Bob-side pure-simulation link-budget sweep points.

arguments
    linkBudgetCfg (1,1) struct
    modInfo (1,1) struct
    txBaseAveragePowerLin (1,1) double
end

requiredFields = ["txPowerLin" "linkGainDbList" "noisePsdLin"];
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
txPowerLin = local_positive_scalar(linkBudgetCfg.txPowerLin, "linkBudget.txPowerLin");
noisePsdLin = local_positive_scalar(linkBudgetCfg.noisePsdLin, "linkBudget.noisePsdLin");
codeRate = local_positive_scalar(modInfo.codeRate, "modInfo.codeRate");
bitsPerSymbol = local_positive_scalar(modInfo.bitsPerSymbol, "modInfo.bitsPerSymbol");
bitLoad = codeRate * bitsPerSymbol;

linkGainDbList = double(linkBudgetCfg.linkGainDbList(:).');
if isempty(linkGainDbList) || any(~isfinite(linkGainDbList))
    error("resolve_link_budget:InvalidLinkGainList", ...
        "linkBudget.linkGainDbList must be a non-empty finite vector.");
end

txPowerDb = 10 * log10(txPowerLin);
txAmplitudeScale = sqrt(txPowerLin / txBaseAveragePowerLin);
linkGainLinList = 10 .^ (linkGainDbList / 10);
rxAmplitudeScaleList = txAmplitudeScale .* sqrt(linkGainLinList);
rxPowerLinList = txPowerLin .* linkGainLinList;
ebN0LinList = rxPowerLinList ./ (noisePsdLin * bitLoad);
ebN0dBList = 10 * log10(ebN0LinList);

bob = struct( ...
    "linkGainDb", linkGainDbList, ...
    "linkGainLin", linkGainLinList, ...
    "rxAmplitudeScale", rxAmplitudeScaleList, ...
    "rxPowerLin", rxPowerLinList, ...
    "noisePsdLin", noisePsdLin * ones(size(linkGainDbList)), ...
    "ebN0Lin", ebN0LinList, ...
    "ebN0dB", ebN0dBList);

budget = struct( ...
    "txPowerLin", txPowerLin, ...
    "txPowerDb", txPowerDb, ...
    "txAmplitudeScale", txAmplitudeScale, ...
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
