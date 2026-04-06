function budget = resolve_link_budget(linkBudgetCfg, txCfg, modInfo, txBaseAveragePowerLin)
%RESOLVE_LINK_BUDGET  Build Bob-side pure-simulation Tx-power sweep points.

arguments
    linkBudgetCfg (1,1) struct
    txCfg (1,1) struct
    modInfo (1,1) struct
    txBaseAveragePowerLin (1,1) double
end

requiredFields = ["noisePsdLin"];
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
if ~isfield(txCfg, "powerDbList")
    error("resolve_link_budget:MissingTxPowerList", ...
        "Missing required tx.powerDbList.");
end
noisePsdLin = local_positive_scalar(linkBudgetCfg.noisePsdLin, "linkBudget.noisePsdLin");
codeRate = local_positive_scalar(modInfo.codeRate, "modInfo.codeRate");
bitsPerSymbol = local_positive_scalar(modInfo.bitsPerSymbol, "modInfo.bitsPerSymbol");
bitLoad = codeRate * bitsPerSymbol;

txPowerDbList = double(txCfg.powerDbList(:).');
if isempty(txPowerDbList) || any(~isfinite(txPowerDbList))
    error("resolve_link_budget:InvalidTxPowerList", ...
        "tx.powerDbList must be a non-empty finite vector.");
end

txPowerLinList = 10 .^ (txPowerDbList / 10);
txAmplitudeScaleList = sqrt(txPowerLinList / txBaseAveragePowerLin);
linkGainDbList = zeros(size(txPowerDbList));
linkGainLinList = ones(size(txPowerDbList));
rxAmplitudeScaleList = txAmplitudeScaleList;
rxPowerLinList = txPowerLinList;
ebN0LinList = rxPowerLinList ./ (noisePsdLin * bitLoad);
ebN0dBList = 10 * log10(ebN0LinList);

bob = struct( ...
    "txPowerDb", txPowerDbList, ...
    "txPowerLin", txPowerLinList, ...
    "linkGainDb", linkGainDbList, ...
    "linkGainLin", linkGainLinList, ...
    "rxAmplitudeScale", rxAmplitudeScaleList, ...
    "rxPowerLin", rxPowerLinList, ...
    "noisePsdLin", noisePsdLin * ones(size(linkGainDbList)), ...
    "ebN0Lin", ebN0LinList, ...
    "ebN0dB", ebN0dBList);

budget = struct( ...
    "txPowerLinList", txPowerLinList, ...
    "txPowerDbList", txPowerDbList, ...
    "txAmplitudeScaleList", txAmplitudeScaleList, ...
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
