function metrics = build_link_power_metrics(linkSpecs, varargin)
%BUILD_LINK_POWER_METRICS Compute thesis-facing power metrics from Tx artifacts.
%
% The net Eb/N0 metric here is referenced to delivered payload bits and
% includes packetization, outer RS, session/control, headers, DSSS, SC-FDE,
% pilots, CP, FH diversity, and pulse shaping burst duration.

opts = local_parse_inputs(varargin{:});
specCells = local_normalize_specs(linkSpecs);
rows = repmat(local_empty_row(), 0, 1);

for specIdx = 1:numel(specCells)
    spec = specCells{specIdx};
    spec.linkBudget.ebN0dBList = double(opts.EbN0dB);
    spec.linkBudget.jsrDbList = double(opts.JsrDb);

    profileName = validate_link_profile(spec);
    runtimeCfg = compile_runtime_config(spec);
    txArtifacts = build_tx_artifacts(spec, runtimeCfg);
    burstReport = txArtifacts.commonMeta.burstReport;
    waveform = txArtifacts.commonMeta.waveform;
    modInfo = txArtifacts.commonMeta.modInfo;
    budget = resolve_link_budget(runtimeCfg.linkBudget, modInfo, ...
        double(burstReport.averagePowerLin), true);

    payloadBits = numel(txArtifacts.payloadAssist.payloadBitsPlain);
    burstSec = double(burstReport.burstDurationSec);
    Rs = double(waveform.symbolRateHz);
    netPayloadBitRateBps = double(payloadBits) / max(burstSec, eps);
    netBitLoad = double(payloadBits) / max(burstSec * Rs, eps);
    fecInfo = fec_get_info(runtimeCfg.fec);
    [bw99Hz, etaBpsHz] = local_spectrum_metrics(txArtifacts, opts.EstimateSpectrum);
    nPackets = numel(txArtifacts.packetAssist.txPackets);
    nDataPackets = double(txArtifacts.payloadAssist.nDataPackets);
    nParityPackets = max(0, nPackets - nDataPackets);
    outerRsRate = local_outer_rs_rate(runtimeCfg.outerRs);
    noisePsdDbmHz = -174 + 10 * log10(double(opts.ReferenceTemperatureK) / 290) ...
        + double(opts.NoiseFigureDb);

    for pointIdx = 1:budget.nPoints
        txPowerLin = double(budget.bob.txPowerLin(pointIdx));
        noisePsdLin = double(budget.bob.noisePsdLin(pointIdx));
        txEbN0NetLin = txPowerLin / max(noisePsdLin * netBitLoad, realmin("double"));
        txEbN0NetDb = 10 * log10(txEbN0NetLin);
        fullOverheadFactor = double(budget.bitLoad) / max(netBitLoad, eps);
        eqRxPowerDbm = txEbN0NetDb + noisePsdDbmHz ...
            + 10 * log10(max(netPayloadBitRateBps, realmin("double")));
        eqTxPowerDbm = eqRxPowerDbm + double(opts.PathLossDb) ...
            - double(opts.TxGainDb) - double(opts.RxGainDb);

        row = local_empty_row();
        row.profile = string(profileName);
        row.pointIndex = double(pointIdx);
        row.bobEbN0dB = double(budget.bob.ebN0dB(pointIdx));
        row.jsrDb = double(budget.bob.jsrDb(pointIdx));
        row.modulation = string(runtimeCfg.mod.type);
        row.innerCode = string(fecInfo.kind);
        row.innerCodeRate = double(fecInfo.codeRate);
        row.ldpcRateName = string(fecInfo.ldpcRateName);
        row.dsssEnable = logical(runtimeCfg.dsss.enable);
        row.dsssSpreadFactor = local_spread_factor(runtimeCfg.dsss);
        row.fhEnable = logical(runtimeCfg.fh.enable);
        row.fhFreqCount = local_fh_freq_count(runtimeCfg.fh);
        row.scFdeEnable = logical(runtimeCfg.scFde.enable);
        row.scFdeCpLenSymbols = local_optional_numeric(runtimeCfg.scFde, "cpLenSymbols");
        row.scFdePilotLength = local_optional_numeric(runtimeCfg.scFde, "pilotLength");
        row.outerRsDataPacketsPerBlock = double(runtimeCfg.outerRs.dataPacketsPerBlock);
        row.outerRsParityPacketsPerBlock = double(runtimeCfg.outerRs.parityPacketsPerBlock);
        row.outerRsRate = outerRsRate;
        row.payloadBits = double(payloadBits);
        row.txPacketCount = double(nPackets);
        row.dataPacketCount = double(nDataPackets);
        row.parityPacketCount = double(nParityPackets);
        row.burstSec = burstSec;
        row.sampleRateHz = double(waveform.sampleRateHz);
        row.symbolRateHz = Rs;
        row.linkBudgetBitLoad = double(budget.bitLoad);
        row.netBitLoad = netBitLoad;
        row.fullOverheadFactor = fullOverheadFactor;
        row.fullOverheadPenaltyDb = 10 * log10(max(fullOverheadFactor, realmin("double")));
        row.netPayloadBitRateBps = netPayloadBitRateBps;
        row.txPowerNormLin = txPowerLin;
        row.txPowerNormDb = double(budget.bob.txPowerDb(pointIdx));
        row.txEbN0NetDb = txEbN0NetDb;
        row.bw99Hz = bw99Hz;
        row.etaBpsHz = etaBpsHz;
        row.noiseFigureDb = double(opts.NoiseFigureDb);
        row.referenceTemperatureK = double(opts.ReferenceTemperatureK);
        row.noisePsdDbmPerHz = noisePsdDbmHz;
        row.eqRxPowerDbm0dBLink = eqRxPowerDbm;
        row.pathLossDb = double(opts.PathLossDb);
        row.txGainDb = double(opts.TxGainDb);
        row.rxGainDb = double(opts.RxGainDb);
        row.eqTxPowerDbm = eqTxPowerDbm;
        rows(end + 1, 1) = row; %#ok<AGROW>
    end
end

metrics = struct2table(rows);
end

function opts = local_parse_inputs(varargin)
p = inputParser();
p.FunctionName = "build_link_power_metrics";
addParameter(p, "EbN0dB", 6, @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "JsrDb", 0, @(x) isnumeric(x) && isvector(x) && ~isempty(x));
addParameter(p, "NoiseFigureDb", 5, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "ReferenceTemperatureK", 290, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
addParameter(p, "PathLossDb", 0, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "TxGainDb", 0, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "RxGainDb", 0, @(x) isnumeric(x) && isscalar(x) && isfinite(x));
addParameter(p, "EstimateSpectrum", true, @(x) islogical(x) || isnumeric(x));
parse(p, varargin{:});
opts = p.Results;
opts.EbN0dB = double(opts.EbN0dB(:).');
opts.JsrDb = double(opts.JsrDb(:).');
opts.EstimateSpectrum = logical(opts.EstimateSpectrum);
end

function specCells = local_normalize_specs(linkSpecs)
if iscell(linkSpecs)
    specCells = linkSpecs(:).';
elseif isstruct(linkSpecs)
    specCells = num2cell(linkSpecs(:).');
else
    error("build_link_power_metrics:InvalidInput", ...
        "linkSpecs must be a struct array or a cell array of linkSpec structs.");
end
if isempty(specCells)
    error("build_link_power_metrics:EmptyInput", "At least one linkSpec is required.");
end
for idx = 1:numel(specCells)
    if ~isstruct(specCells{idx})
        error("build_link_power_metrics:InvalidSpec", ...
            "linkSpecs{%d} must be a struct.", idx);
    end
end
end

function row = local_empty_row()
row = struct( ...
    "profile", "", ...
    "pointIndex", NaN, ...
    "bobEbN0dB", NaN, ...
    "jsrDb", NaN, ...
    "modulation", "", ...
    "innerCode", "", ...
    "innerCodeRate", NaN, ...
    "ldpcRateName", "", ...
    "dsssEnable", false, ...
    "dsssSpreadFactor", NaN, ...
    "fhEnable", false, ...
    "fhFreqCount", NaN, ...
    "scFdeEnable", false, ...
    "scFdeCpLenSymbols", NaN, ...
    "scFdePilotLength", NaN, ...
    "outerRsDataPacketsPerBlock", NaN, ...
    "outerRsParityPacketsPerBlock", NaN, ...
    "outerRsRate", NaN, ...
    "payloadBits", NaN, ...
    "txPacketCount", NaN, ...
    "dataPacketCount", NaN, ...
    "parityPacketCount", NaN, ...
    "burstSec", NaN, ...
    "sampleRateHz", NaN, ...
    "symbolRateHz", NaN, ...
    "linkBudgetBitLoad", NaN, ...
    "netBitLoad", NaN, ...
    "fullOverheadFactor", NaN, ...
    "fullOverheadPenaltyDb", NaN, ...
    "netPayloadBitRateBps", NaN, ...
    "txPowerNormLin", NaN, ...
    "txPowerNormDb", NaN, ...
    "txEbN0NetDb", NaN, ...
    "bw99Hz", NaN, ...
    "etaBpsHz", NaN, ...
    "noiseFigureDb", NaN, ...
    "referenceTemperatureK", NaN, ...
    "noisePsdDbmPerHz", NaN, ...
    "eqRxPowerDbm0dBLink", NaN, ...
    "pathLossDb", NaN, ...
    "txGainDb", NaN, ...
    "rxGainDb", NaN, ...
    "eqTxPowerDbm", NaN);
end

function value = local_spread_factor(dsssCfg)
value = 1;
if isfield(dsssCfg, "enable") && logical(dsssCfg.enable)
    value = dsss_effective_spread_factor(dsssCfg);
end
value = double(value);
end

function value = local_fh_freq_count(fhCfg)
if ~(isfield(fhCfg, "enable") && logical(fhCfg.enable))
    value = 0;
    return;
end
if isfield(fhCfg, "freqSet") && ~isempty(fhCfg.freqSet)
    value = numel(double(fhCfg.freqSet));
elseif isfield(fhCfg, "nFreqs") && ~isempty(fhCfg.nFreqs)
    value = double(fhCfg.nFreqs);
else
    error("build_link_power_metrics:InvalidFhCfg", ...
        "FH is enabled but neither fh.freqSet nor fh.nFreqs is available.");
end
end

function value = local_optional_numeric(s, fieldName)
if isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = double(s.(fieldName));
else
    value = NaN;
end
end

function value = local_outer_rs_rate(outerRsCfg)
if ~(isfield(outerRsCfg, "enable") && logical(outerRsCfg.enable))
    value = 1;
    return;
end
k = double(outerRsCfg.dataPacketsPerBlock);
p = double(outerRsCfg.parityPacketsPerBlock);
value = k / max(k + p, eps);
end

function [bw99Hz, etaBpsHz] = local_spectrum_metrics(txArtifacts, estimateSpectrum)
waveform = txArtifacts.commonMeta.waveform;
payloadBits = numel(txArtifacts.payloadAssist.payloadBitsPlain);
burstSec = double(txArtifacts.commonMeta.burstReport.burstDurationSec);
if estimateSpectrum
    try
        [~, ~, bw99Hz, etaBpsHz] = estimate_spectrum( ...
            txArtifacts.burstForChannel(:), ...
            txArtifacts.commonMeta.modInfo, ...
            waveform, ...
            struct("payloadBits", payloadBits));
        return;
    catch
        % Fall through to the analytic RRC bandwidth estimate.
    end
end
rolloff = double(waveform.rolloff);
bw99Hz = double(waveform.symbolRateHz) * (1 + rolloff);
etaBpsHz = double(payloadBits) / max(burstSec, eps) / max(bw99Hz, eps);
end
