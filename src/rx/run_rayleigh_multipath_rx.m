function rxResult = run_rayleigh_multipath_rx(rxSamples, txArtifacts, rxCfg)
%RUN_RAYLEIGH_MULTIPATH_RX Dedicated Rayleigh multipath receiver entry contract.

arguments
    rxSamples
    txArtifacts (1,1) struct
    rxCfg (1,1) struct
end

ctxProfileName = "rayleigh_multipath";
if isfield(rxCfg, "runtimeCfg") && isstruct(rxCfg.runtimeCfg) ...
        && isfield(rxCfg.runtimeCfg, "linkProfile") && isstruct(rxCfg.runtimeCfg.linkProfile) ...
        && isfield(rxCfg.runtimeCfg.linkProfile, "name") ...
        && string(rxCfg.runtimeCfg.linkProfile.name) == "robust_unified"
    ctxProfileName = "robust_unified";
end
ctx = rx_prepare_packet_context(ctxProfileName, rxSamples, txArtifacts, rxCfg);
captureStage = rx_run_capture_stage(ctx);

if captureStage.frontEndOk
    [headerSym, dataSym, symbolReliability, frontEndDiag] = local_rayleigh_channel_stage_local(ctx, captureStage);
else
    [headerSym, dataSym, symbolReliability, frontEndDiag] = local_failed_frontend_placeholder_local(ctx.pkt);
end

headerResult = rx_decode_common_phy_header(ctx, headerSym);
packetDataBitsRx = uint8([]);
symbolReliabilityData = zeros(0, 1);
profileDiag = struct();
if frontEndDiag.ok && headerResult.ok
    [packetDataBitsRx, symbolReliabilityData, profileDiag] = local_decode_rayleigh_payload_local(ctx, dataSym, symbolReliability, frontEndDiag);
end

rxResult = rx_finalize_packet_result( ...
    ctx, captureStage, frontEndDiag, headerResult, packetDataBitsRx, symbolReliabilityData, profileDiag);
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_rayleigh_channel_stage_local(ctx, captureStage)
if local_rayleigh_branch_diversity_active_local(captureStage.front)
    [headerSym, dataSym, symbolReliability, diagOut] = local_rayleigh_branch_diversity_stage_local(ctx, captureStage.front);
    return;
end
[headerSym, dataSym, symbolReliability, diagOut] = local_rayleigh_single_branch_stage_local( ...
    ctx, captureStage.ySymRaw, captureStage.symbolReliabilityFront);
end

function [packetDataBitsRx, symbolReliabilityData, profileDiag] = local_decode_rayleigh_payload_local(ctx, dataSym, symbolReliability, frontEndDiag)
if isfield(frontEndDiag, "payloadBranchState") && isstruct(frontEndDiag.payloadBranchState) ...
        && isfield(frontEndDiag.payloadBranchState, "enable") && logical(frontEndDiag.payloadBranchState.enable)
    [dataSymUse, symbolReliabilityData, scFdeDiag] = local_decode_rayleigh_payload_diversity_local( ...
        ctx, frontEndDiag.payloadBranchState);
else
    [dataSymUse, reliabilityNow, scFdeDiag] = local_sc_fde_payload_decode_local(dataSym(:), ctx, frontEndDiag);
    symbolReliabilityData = min(rx_expand_reliability(symbolReliability, numel(dataSymUse)), ...
        rx_expand_reliability(reliabilityNow, numel(dataSymUse)));
end
packetDataBitsRx = rx_decode_packet_bits_common(dataSymUse, symbolReliabilityData, ctx.pkt, ctx.runtimeCfg);
profileDiag = struct("scFde", scFdeDiag);
end

function [dataOut, reliabilityOut, diagOut] = local_sc_fde_payload_decode_local(dataSymIn, ctx, frontEndDiag)
plan = ctx.pkt.scFdeInfo;
if ~(isstruct(plan) && isfield(plan, "enable") && logical(plan.enable))
    dataOut = dataSymIn(:);
    reliabilityOut = ones(numel(dataOut), 1);
    diagOut = struct("enabled", false);
    return;
end

hopLen = round(double(plan.hopLen));
coreLen = round(double(plan.coreLen));
cpLen = round(double(plan.cpLen));
pilotLength = round(double(plan.pilotLength));
dataPerHop = round(double(plan.dataSymbolsPerHop));
nHops = round(double(plan.nHops));
if numel(dataSymIn) < nHops * hopLen
    dataSymIn = rx_fit_complex_length(dataSymIn, nHops * hopLen);
end

[hopFreqs, hBank, bankMode] = local_sc_fde_payload_channel_bank_local(ctx, frontEndDiag, nHops);

lambda = double(ctx.runtimeCfg.scFde.lambdaFactor) * double(ctx.rxCfg.noisePsdLin);
if ~local_sc_fde_mmse_active_local(ctx.method)
    lambda = inf;
end

blocks = reshape(dataSymIn(1:nHops * hopLen), hopLen, nHops);
dataMat = complex(zeros(dataPerHop, nHops));
reliabilityHop = ones(nHops, 1);
pilotMse = nan(nHops, 1);
robustNbiApplied = false(nHops, 1);
robustNbiMaskFraction = zeros(nHops, 1);
robustNbiReliability = ones(nHops, 1);

for hopIdx = 1:nHops
    block = blocks(:, hopIdx);
    core = block(cpLen + 1:end);
    if numel(core) ~= coreLen
        error("SC-FDE core length mismatch while decoding packet %d.", ctx.pkt.packetIndex);
    end
    h = hBank{hopIdx};
    if numel(h) > double(plan.cpLen) + 1
        error("SC-FDE decode requires channel length <= cpLen+1. Channel length=%d, cpLen=%d.", ...
            numel(h), double(plan.cpLen));
    end
    if numel(h) > coreLen
        error("SC-FDE core length %d is shorter than channel length %d.", coreLen, numel(h));
    end
    [core, nbiReliability, nbiInfo] = local_robust_scfde_nbi_cancel_local(core, ctx);
    robustNbiReliability(hopIdx) = nbiReliability;
    if isstruct(nbiInfo) && isfield(nbiInfo, "applied") && logical(nbiInfo.applied)
        robustNbiApplied(hopIdx) = true;
        if isfield(nbiInfo, "maskFraction") && isfinite(double(nbiInfo.maskFraction))
            robustNbiMaskFraction(hopIdx) = double(nbiInfo.maskFraction);
        end
    end
    xCore = local_apply_sc_fde_mmse_core_local(core, h, lambda, coreLen);

    pilotTx = sc_fde_payload_pilot_symbols(ctx.runtimeCfg.scFde, double(ctx.pkt.packetIndex), hopIdx);
    pilotRx = xCore(1:pilotLength);
    alpha = sum(pilotRx .* conj(pilotTx)) / max(sum(abs(pilotTx).^2), eps);
    if abs(alpha) < max(double(ctx.runtimeCfg.scFde.pilotMinAbsGain), eps)
        alpha = 1;
    end
    xCore = xCore / alpha;
    pilotMse(hopIdx) = mean(abs(xCore(1:pilotLength) - pilotTx).^2);
    reliabilityHop(hopIdx) = 1 / (1 + pilotMse(hopIdx) / max(double(ctx.runtimeCfg.scFde.pilotMseReference), eps));
    reliabilityHop(hopIdx) = max(double(ctx.runtimeCfg.scFde.minReliability), min(1, reliabilityHop(hopIdx)));
    reliabilityHop(hopIdx) = min(reliabilityHop(hopIdx), nbiReliability);
    dataMat(:, hopIdx) = xCore(pilotLength + 1:end);
end

dataOut = dataMat(:);
dataOut = dataOut(1:double(ctx.pkt.nDataSymBase));
reliabilityOut = repelem(reliabilityHop, dataPerHop, 1);
reliabilityOut = reliabilityOut(1:double(ctx.pkt.nDataSymBase));
diagOut = struct( ...
    "enabled", true, ...
    "method", string(ctx.method), ...
    "channelBankMode", string(bankMode), ...
    "hopFrequencies", hopFreqs, ...
    "pilotMse", pilotMse, ...
    "hopReliability", reliabilityHop, ...
    "robustNbiCancelApplied", robustNbiApplied, ...
    "robustNbiCancelMaskFraction", robustNbiMaskFraction, ...
    "robustNbiCancelReliability", robustNbiReliability);
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_rayleigh_single_branch_stage_local(ctx, ySymRawFull, symbolReliabilityFull)
headerStart = numel(ctx.pkt.syncSym) + 1;
headerStop = headerStart + double(ctx.pkt.nPhyHeaderSymTx) - 1;
dataStart = headerStop + 1;

ySymRawFull = rx_fit_complex_length(ySymRawFull, ctx.expectedLen);
symbolReliabilityFull = rx_expand_reliability(symbolReliabilityFull, ctx.expectedLen);

ySymUse = ySymRawFull;
diagOut = struct("ok", true, "headerEqualizer", "none");
if local_sc_fde_mmse_active_local(ctx.method)
    freqBySymbol = local_packet_frequency_offsets_local(ctx.pkt, numel(ySymRawFull));
    eq = multipath_equalizer_from_preamble( ...
        ctx.pkt.syncSym(:), ySymRawFull(1:numel(ctx.pkt.syncSym)), ...
        local_header_equalizer_cfg_local(ctx.runtimeCfg, ctx.pkt), ...
        double(ctx.rxCfg.noisePsdLin), ...
        rx_effective_multipath_channel_len_symbols(ctx.runtimeCfg, ctx.rxCfg));
    ySymUse = local_apply_frequency_aware_equalizer_block_local(ySymRawFull, eq, freqBySymbol);
    diagOut.headerEqualizer = eq.method;
    diagOut.payloadEqualizer = eq;
end

headerSym = ySymUse(headerStart:headerStop);
dataSym = ySymRawFull(dataStart:end);
symbolReliability = rx_expand_reliability(symbolReliabilityFull(dataStart:end), numel(dataSym));
if local_robust_unified_active_local(ctx)
    nbMethod = local_robust_fh_frontend_method_local(ctx);
    [dataSym, nbReliability, nbDiag] = narrowband_profile_frontend(dataSym(:), ctx.pkt, ctx.runtimeCfg, nbMethod);
    nbReliability = local_robust_adjust_fh_reliability_local(nbReliability, ctx);
    symbolReliability = min(symbolReliability, rx_expand_reliability(nbReliability, numel(dataSym)));
    diagOut.narrowbandFrontEnd = nbDiag;
end
if ~(isfield(ctx, "fhCaptureCfg") && isstruct(ctx.fhCaptureCfg) ...
        && isfield(ctx.fhCaptureCfg, "enable") && logical(ctx.fhCaptureCfg.enable))
    dataSym = rx_dehop_payload_symbols(dataSym, ctx.pkt);
end
symbolReliability = rx_expand_reliability(symbolReliability, numel(dataSym));
diagOut.headerReliability = rx_expand_reliability(symbolReliabilityFull(headerStart:headerStop), numel(headerSym));
diagOut.payloadInputLength = numel(dataSym);
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_rayleigh_branch_diversity_stage_local(ctx, front)
[branchFronts, branchPowerWeights] = local_valid_rayleigh_branch_fronts_local(front);
nBranches = numel(branchFronts);
headerBranches = cell(nBranches, 1);
headerReliabilityBranches = cell(nBranches, 1);
dataBranches = cell(nBranches, 1);
dataReliabilityBranches = cell(nBranches, 1);
branchDiagList = cell(nBranches, 1);
branchScores = local_normalize_branch_weights_local(branchPowerWeights);

for branchIdx = 1:nBranches
    branchFront = branchFronts{branchIdx};
    [headerBranches{branchIdx}, dataBranches{branchIdx}, dataReliabilityBranches{branchIdx}, branchDiagList{branchIdx}] = ...
        local_rayleigh_single_branch_stage_local( ...
            ctx, branchFront.rFull, branchFront.reliabilityFull);
    headerReliabilityBranches{branchIdx} = branchDiagList{branchIdx}.headerReliability;
    branchScores(branchIdx) = branchScores(branchIdx) * max(mean(headerReliabilityBranches{branchIdx}), eps);
end

branchScores = local_sc_fde_gate_branch_scores_local(branchScores, "Rayleigh header branch gating");
[headerSym, headerReliability] = local_weighted_symbol_branch_combine_local( ...
    headerBranches, headerReliabilityBranches, branchScores, "Rayleigh header branch combine");
[~, bestBranchIdx] = max(branchScores);
dataSym = dataBranches{bestBranchIdx};
symbolReliability = dataReliabilityBranches{bestBranchIdx};

diagOut = struct( ...
    "ok", true, ...
    "headerEqualizer", "branch_mmse_combine", ...
    "nBranches", double(nBranches), ...
    "branchPowerWeights", branchPowerWeights, ...
    "branchScores", branchScores, ...
    "bestBranchIndex", double(bestBranchIdx), ...
    "headerReliability", headerReliability, ...
    "payloadBranchState", struct( ...
        "enable", true, ...
        "branchDataSymbols", {dataBranches}, ...
        "branchDataReliability", {dataReliabilityBranches}, ...
        "branchFrontEndDiag", {branchDiagList}, ...
        "branchPowerWeights", branchPowerWeights, ...
        "branchScores", branchScores));
end

function [dataSymUse, symbolReliabilityData, diagOut] = local_decode_rayleigh_payload_diversity_local(ctx, payloadBranchState)
requiredFields = ["branchDataSymbols" "branchDataReliability" "branchFrontEndDiag" "branchScores" "branchPowerWeights"];
for idx = 1:numel(requiredFields)
    fieldName = requiredFields(idx);
    if ~isfield(payloadBranchState, fieldName)
        error("Rayleigh payload diversity state requires payloadBranchState.%s.", fieldName);
    end
end

branchDataSymbols = payloadBranchState.branchDataSymbols;
branchDataReliability = payloadBranchState.branchDataReliability;
branchFrontEndDiag = payloadBranchState.branchFrontEndDiag;
nBranches = numel(branchDataSymbols);
if ~(iscell(branchDataSymbols) && iscell(branchDataReliability) && iscell(branchFrontEndDiag) ...
        && numel(branchDataReliability) == nBranches && numel(branchFrontEndDiag) == nBranches ...
        && numel(payloadBranchState.branchPowerWeights) == nBranches)
    error("Rayleigh payload diversity state lists must have matching branch counts.");
end

plan = ctx.pkt.scFdeInfo;
if ~(isstruct(plan) && isfield(plan, "enable") && logical(plan.enable))
    branchScores = local_normalize_branch_weights_local(double(payloadBranchState.branchPowerWeights(:)));
    branchScores = local_sc_fde_gate_branch_scores_local(branchScores, "Rayleigh payload raw branch gating");
    [dataSymUse, symbolReliabilityData] = local_weighted_symbol_branch_combine_local( ...
        branchDataSymbols, branchDataReliability, branchScores, "Rayleigh payload raw branch combine");
    diagOut = struct( ...
        "enabled", false, ...
        "method", string(ctx.method), ...
        "diversityMode", "branch_raw_symbol_combine", ...
        "nBranches", double(nBranches), ...
        "branchScores", branchScores, ...
        "combinedReliabilityMean", mean(symbolReliabilityData));
    return;
end

hopLen = round(double(plan.hopLen));
coreLen = round(double(plan.coreLen));
cpLen = round(double(plan.cpLen));
pilotLength = round(double(plan.pilotLength));
dataPerHop = round(double(plan.dataSymbolsPerHop));
nHops = round(double(plan.nHops));
branchScoreBase = local_normalize_branch_weights_local(double(payloadBranchState.branchPowerWeights(:)));

lambda = double(ctx.runtimeCfg.scFde.lambdaFactor) * double(ctx.rxCfg.noisePsdLin);
if ~local_sc_fde_mmse_active_local(ctx.method)
    lambda = inf;
end

hBankList = cell(nBranches, 1);
bankModes = strings(nBranches, 1);
perBranchPilotMse = nan(nHops, nBranches);
hopBranchScores = zeros(nHops, nBranches);
hopFreqs = zeros(nHops, 1);
robustNbiApplied = false(nHops, nBranches);
robustNbiMaskFraction = zeros(nHops, nBranches);
robustNbiReliability = ones(nHops, nBranches);
for branchIdx = 1:nBranches
    branchDataSymbols{branchIdx} = rx_fit_complex_length(branchDataSymbols{branchIdx}, nHops * hopLen);
    branchDataReliability{branchIdx} = rx_expand_reliability(branchDataReliability{branchIdx}, nHops * hopLen);
    [hopFreqsNow, hBankList{branchIdx}, bankModes(branchIdx)] = local_sc_fde_payload_channel_bank_local( ...
        ctx, branchFrontEndDiag{branchIdx}, nHops);
    if branchIdx == 1
        hopFreqs = hopFreqsNow;
    elseif any(abs(hopFreqsNow - hopFreqs) > 1e-10)
        error("Rayleigh payload diversity requires the same hop frequencies across branches.");
    end
end

dataOutFull = complex(zeros(nHops * dataPerHop, 1));
relOutFull = ones(nHops * dataPerHop, 1);
pilotMseCombined = nan(nHops, 1);
hopReliabilityCombined = ones(nHops, 1);

for hopIdx = 1:nHops
    pilotTx = sc_fde_payload_pilot_symbols(ctx.runtimeCfg.scFde, double(ctx.pkt.packetIndex), hopIdx);
    coreList = cell(nBranches, 1);
    relList = cell(nBranches, 1);
    scoreList = zeros(nBranches, 1);

    for branchIdx = 1:nBranches
        [core, relCore] = local_sc_fde_core_from_physical_hop_local( ...
            branchDataSymbols{branchIdx}, branchDataReliability{branchIdx}, hopIdx, plan);
        [core, nbiReliability, nbiInfo] = local_robust_scfde_nbi_cancel_local(core, ctx);
        robustNbiReliability(hopIdx, branchIdx) = nbiReliability;
        if isstruct(nbiInfo) && isfield(nbiInfo, "applied") && logical(nbiInfo.applied)
            robustNbiApplied(hopIdx, branchIdx) = true;
            if isfield(nbiInfo, "maskFraction") && isfinite(double(nbiInfo.maskFraction))
                robustNbiMaskFraction(hopIdx, branchIdx) = double(nbiInfo.maskFraction);
            end
        end
        relCore = min(relCore, nbiReliability);
        h = hBankList{branchIdx}{hopIdx};
        if numel(h) > cpLen + 1
            error("SC-FDE diversity requires channel length <= cpLen+1. Channel length=%d, cpLen=%d.", ...
                numel(h), cpLen);
        end
        xCore = local_apply_sc_fde_mmse_core_local(core, h, lambda, coreLen);
        [xCore, hopRel, mseNow] = local_sc_fde_pilot_scalar_simple_local(xCore, pilotTx, ctx.runtimeCfg.scFde);
        perBranchPilotMse(hopIdx, branchIdx) = mseNow;
        coreList{branchIdx} = xCore;
        relList{branchIdx} = min(relCore, hopRel);
        scoreList(branchIdx) = branchScoreBase(branchIdx) * max(mean(relList{branchIdx}), eps);
    end

    if ~any(scoreList > 0)
        error("Rayleigh payload SC-FDE hop %d produced no positive branch scores.", hopIdx);
    end
    hopBranchScores(hopIdx, :) = scoreList;
    [xCoreComb, relCoreComb] = local_sc_fde_mrc_combine_branch_cores_local( ...
        coreList, relList, ones(nBranches, 1), scoreList, sprintf("Rayleigh payload SC-FDE hop %d", hopIdx));
    [xCoreComb, hopReliabilityCombined(hopIdx), pilotMseCombined(hopIdx)] = local_sc_fde_pilot_scalar_simple_local( ...
        xCoreComb, pilotTx, ctx.runtimeCfg.scFde);
    relCoreComb = min(relCoreComb, hopReliabilityCombined(hopIdx));

    dataIdx = (hopIdx - 1) * dataPerHop + (1:dataPerHop);
    dataOutFull(dataIdx) = xCoreComb(pilotLength + 1:end);
    relOutFull(dataIdx) = relCoreComb(pilotLength + 1:end);
end

dataSymUse = dataOutFull(1:double(ctx.pkt.nDataSymBase));
symbolReliabilityData = relOutFull(1:double(ctx.pkt.nDataSymBase));
diagOut = struct( ...
    "enabled", true, ...
    "method", string(ctx.method), ...
    "diversityMode", "branch_post_sc_fde_core_mrc", ...
    "nBranches", double(nBranches), ...
    "branchBaseScores", branchScoreBase, ...
    "hopBranchScores", hopBranchScores, ...
    "hopFrequencies", hopFreqs, ...
    "bankModes", bankModes, ...
    "perBranchPilotMse", perBranchPilotMse, ...
    "combinedPilotMse", pilotMseCombined, ...
    "hopReliability", hopReliabilityCombined, ...
    "robustNbiCancelApplied", robustNbiApplied, ...
    "robustNbiCancelMaskFraction", robustNbiMaskFraction, ...
    "robustNbiCancelReliability", robustNbiReliability, ...
    "combinedReliabilityMean", mean(symbolReliabilityData));
end

function tf = local_rayleigh_branch_diversity_active_local(front)
tf = false;
if ~(isstruct(front) && isfield(front, "branchFronts") && iscell(front.branchFronts) ...
        && isfield(front, "branchOkMask") && ~isempty(front.branchOkMask))
    return;
end
branchOkMask = logical(front.branchOkMask(:));
tf = numel(front.branchFronts) > 1 && any(branchOkMask) && nnz(branchOkMask) > 1;
end

function [branchFronts, branchPowerWeights] = local_valid_rayleigh_branch_fronts_local(front)
if ~(isstruct(front) && isfield(front, "branchFronts") && iscell(front.branchFronts) ...
        && isfield(front, "branchOkMask") && ~isempty(front.branchOkMask))
    error("Rayleigh branch diversity requires front.branchFronts and front.branchOkMask.");
end
branchOkMask = logical(front.branchOkMask(:));
if numel(branchOkMask) ~= numel(front.branchFronts)
    error("Rayleigh branch diversity branchOkMask size must match branchFronts.");
end
usedIdx = find(branchOkMask);
if numel(usedIdx) <= 1
    error("Rayleigh branch diversity requires at least two valid branches.");
end
branchFronts = front.branchFronts(usedIdx);
if ~(isfield(front, "branchPowerWeights") && numel(front.branchPowerWeights) == numel(front.branchFronts))
    error("Rayleigh branch diversity requires front.branchPowerWeights for all branches.");
end
branchPowerWeights = double(front.branchPowerWeights(usedIdx));
if any(~isfinite(branchPowerWeights) | branchPowerWeights <= 0)
    error("Rayleigh branch diversity requires positive finite branchPowerWeights.");
end
end

function weightsOut = local_normalize_branch_weights_local(weightsIn)
weightsIn = double(weightsIn(:));
if isempty(weightsIn)
    error("Rayleigh branch diversity requires non-empty branch weights.");
end
if any(~isfinite(weightsIn) | weightsIn <= 0)
    error("Rayleigh branch diversity branch weights must be positive and finite.");
end
weightsOut = weightsIn / max(weightsIn);
end

function [symOut, relOut] = local_weighted_symbol_branch_combine_local(symList, relList, scoreWeights, ownerName)
if nargin < 4 || strlength(string(ownerName)) == 0
    ownerName = "Rayleigh branch combine";
end
if ~(iscell(symList) && iscell(relList) && numel(symList) == numel(relList) && numel(symList) == numel(scoreWeights))
    error("%s requires matched symbol/reliability/weight lists.", char(ownerName));
end

scoreWeights = double(scoreWeights(:));
validMask = isfinite(scoreWeights) & scoreWeights > 0;
if ~any(validMask)
    error("%s requires at least one positive branch weight.", char(ownerName));
end

usedIdx = find(validMask);
targetLen = [];
for idx = 1:numel(usedIdx)
    branchIdx = usedIdx(idx);
    symList{branchIdx} = symList{branchIdx}(:);
    relList{branchIdx} = rx_expand_reliability(relList{branchIdx}, numel(symList{branchIdx}));
    if isempty(targetLen)
        targetLen = numel(symList{branchIdx});
    elseif numel(symList{branchIdx}) ~= targetLen
        error("%s branch lengths are inconsistent.", char(ownerName));
    end
end

[~, refLocalIdx] = max(scoreWeights(usedIdx));
refIdx = usedIdx(refLocalIdx);
refSym = symList{refIdx};
scoreNorm = scoreWeights / max(scoreWeights(usedIdx));

symAccum = complex(zeros(targetLen, 1));
weightAccum = zeros(targetLen, 1);
qualityMat = zeros(targetLen, numel(usedIdx));
for idx = 1:numel(usedIdx)
    branchIdx = usedIdx(idx);
    symNow = symList{branchIdx};
    relNow = rx_expand_reliability(relList{branchIdx}, targetLen);
    phaseRef = sum(symNow .* conj(refSym) .* relNow);
    if abs(phaseRef) > eps
        symNow = symNow * exp(-1j * angle(phaseRef));
    end
    weightNow = scoreNorm(branchIdx) * relNow;
    symAccum = symAccum + weightNow .* symNow;
    weightAccum = weightAccum + weightNow;
    qualityMat(:, idx) = max(0, min(1, weightNow));
end

symOut = refSym;
use = weightAccum > eps;
symOut(use) = symAccum(use) ./ weightAccum(use);
relOut = 1 - prod(1 - qualityMat, 2);
relOut = max(0, min(1, relOut));
end

function scoreOut = local_sc_fde_gate_branch_scores_local(scoreIn, ownerName)
if nargin < 2 || strlength(string(ownerName)) == 0
    ownerName = "SC-FDE diversity branch gating";
end
scoreIn = double(scoreIn(:));
if isempty(scoreIn)
    error("%s requires a non-empty score vector.", char(ownerName));
end
if any(~isfinite(scoreIn) | scoreIn < 0)
    error("%s scores must be finite and nonnegative.", char(ownerName));
end

[bestScore, bestIdx] = max(scoreIn);
if ~(isfinite(bestScore) && bestScore > 0)
    error("%s requires at least one positive branch score.", char(ownerName));
end

if bestScore < 0.20
    keepMask = false(size(scoreIn));
    keepMask(bestIdx) = true;
else
    keepMask = scoreIn >= 0.85 * bestScore;
    if ~any(keepMask)
        keepMask(bestIdx) = true;
    end
end

scoreOut = zeros(size(scoreIn));
scoreOut(keepMask) = scoreIn(keepMask);
end

function method = local_robust_fh_frontend_method_local(ctx)
cfg = local_required_robust_mixed_cfg_local(ctx);
if ~local_channel_narrowband_active_local(ctx)
    method = "none";
    return;
end
switch string(cfg.narrowbandFrontend)
    case "dsss_only"
        method = "none";
    case "fh_erasure"
        method = "fh_erasure";
    case "subband_excision"
        method = "narrowband_subband_excision_soft";
    otherwise
        error("Unsupported robustMixed.narrowbandFrontend: %s.", char(string(cfg.narrowbandFrontend)));
end
end

function reliabilityOut = local_robust_adjust_fh_reliability_local(reliabilityIn, ctx)
reliabilityOut = reliabilityIn(:);
if ~local_robust_unified_active_local(ctx)
    return;
end
cfg = local_required_robust_mixed_cfg_local(ctx);
if ~(logical(cfg.enableFhReliabilityFloorWithMultipath) && local_channel_multipath_active_local(ctx))
    return;
end
reliabilityOut = max(reliabilityOut, double(cfg.fhReliabilityFloorWithMultipath));
end

function [coreOut, reliability, infoOut] = local_robust_scfde_nbi_cancel_local(core, ctx)
coreOut = core(:);
reliability = 1;
infoOut = struct( ...
    "enabled", false, ...
    "applied", false, ...
    "maskFraction", 0, ...
    "selectedFreqBounds", zeros(0, 2));
if ~local_robust_unified_active_local(ctx)
    return;
end

cfg = local_required_robust_mixed_cfg_local(ctx);
infoOut.enabled = true;
if ~logical(cfg.enableScFdeNbiCancel)
    return;
end
if local_channel_narrowband_active_local(ctx) && logical(cfg.enableFhSubbandExcision)
    infoOut.disabledByFhSubbandExcision = true;
    return;
end

bandstopCfg = cfg.scFdeNbiCancel;
[candidate, filterInfo] = fft_bandstop_filter(coreOut, bandstopCfg);
if ~(isstruct(filterInfo) && isfield(filterInfo, "applied") && logical(filterInfo.applied))
    return;
end

maskFraction = 0;
if isfield(filterInfo, "maskFraction") && isfinite(double(filterInfo.maskFraction))
    maskFraction = double(filterInfo.maskFraction);
end
if maskFraction <= 0 || maskFraction > double(bandstopCfg.maxMaskFraction)
    return;
end

coreOut = candidate(:);
reliability = 1 - double(bandstopCfg.reliabilityPenaltySlope) * maskFraction;
reliability = max(double(cfg.minReliability), min(1, reliability));
infoOut.applied = true;
infoOut.maskFraction = maskFraction;
if isfield(filterInfo, "selectedFreqBounds")
    infoOut.selectedFreqBounds = filterInfo.selectedFreqBounds;
end
end

function cfg = local_required_robust_mixed_cfg_local(ctx)
if ~local_robust_unified_active_local(ctx)
    cfg = struct();
    return;
end
if ~(isstruct(ctx) && isfield(ctx, "runtimeCfg") && isstruct(ctx.runtimeCfg) ...
        && isfield(ctx.runtimeCfg, "mitigation") && isstruct(ctx.runtimeCfg.mitigation) ...
        && isfield(ctx.runtimeCfg.mitigation, "robustMixed") ...
        && isstruct(ctx.runtimeCfg.mitigation.robustMixed))
    error("robust_unified requires runtimeCfg.mitigation.robustMixed.");
end
cfg = ctx.runtimeCfg.mitigation.robustMixed;
requiredFields = ["narrowbandFrontend" "enableFhSubbandExcision" "enableScFdeNbiCancel" ...
    "enableFhReliabilityFloorWithMultipath" "fhReliabilityFloorWithMultipath" ...
    "minReliability" "scFdeNbiCancel"];
for idx = 1:numel(requiredFields)
    fieldName = requiredFields(idx);
    if ~isfield(cfg, fieldName)
        error("mitigation.robustMixed.%s is required.", char(fieldName));
    end
end
if ~isstruct(cfg.scFdeNbiCancel)
    error("mitigation.robustMixed.scFdeNbiCancel must be a struct.");
end
requiredBandstopFields = ["peakRatio" "edgeRatio" "maxBands" "mergeGapBins" "padBins" ...
    "minBandBins" "smoothSpanBins" "fftOversample" "maxBandwidthFrac" "minFreqAbs" ...
    "suppressToFloor" "maxMaskFraction" "reliabilityPenaltySlope"];
for idx = 1:numel(requiredBandstopFields)
    fieldName = requiredBandstopFields(idx);
    if ~isfield(cfg.scFdeNbiCancel, fieldName)
        error("mitigation.robustMixed.scFdeNbiCancel.%s is required.", char(fieldName));
    end
end
cfg.enableFhSubbandExcision = logical(cfg.enableFhSubbandExcision);
cfg.enableScFdeNbiCancel = logical(cfg.enableScFdeNbiCancel);
cfg.enableFhReliabilityFloorWithMultipath = logical(cfg.enableFhReliabilityFloorWithMultipath);
cfg.narrowbandFrontend = string(cfg.narrowbandFrontend);
if ~isscalar(cfg.narrowbandFrontend) || ~any(cfg.narrowbandFrontend == ["dsss_only" "fh_erasure" "subband_excision"])
    error("mitigation.robustMixed.narrowbandFrontend must be dsss_only, fh_erasure, or subband_excision.");
end
cfg.fhReliabilityFloorWithMultipath = local_probability_scalar_local( ...
    cfg.fhReliabilityFloorWithMultipath, "mitigation.robustMixed.fhReliabilityFloorWithMultipath");
cfg.minReliability = local_probability_scalar_local(cfg.minReliability, "mitigation.robustMixed.minReliability");
cfg.scFdeNbiCancel.maxMaskFraction = local_probability_scalar_local( ...
    cfg.scFdeNbiCancel.maxMaskFraction, "mitigation.robustMixed.scFdeNbiCancel.maxMaskFraction");
cfg.scFdeNbiCancel.reliabilityPenaltySlope = local_nonnegative_scalar_local( ...
    cfg.scFdeNbiCancel.reliabilityPenaltySlope, "mitigation.robustMixed.scFdeNbiCancel.reliabilityPenaltySlope");
end

function tf = local_channel_multipath_active_local(ctx)
tf = isstruct(ctx) && isfield(ctx, "runtimeCfg") && isstruct(ctx.runtimeCfg) ...
    && isfield(ctx.runtimeCfg, "channel") && isstruct(ctx.runtimeCfg.channel) ...
    && isfield(ctx.runtimeCfg.channel, "multipath") && isstruct(ctx.runtimeCfg.channel.multipath) ...
    && isfield(ctx.runtimeCfg.channel.multipath, "enable") ...
    && logical(ctx.runtimeCfg.channel.multipath.enable);
end

function tf = local_channel_narrowband_active_local(ctx)
tf = isstruct(ctx) && isfield(ctx, "runtimeCfg") && isstruct(ctx.runtimeCfg) ...
    && isfield(ctx.runtimeCfg, "channel") && isstruct(ctx.runtimeCfg.channel) ...
    && isfield(ctx.runtimeCfg.channel, "narrowband") && isstruct(ctx.runtimeCfg.channel.narrowband) ...
    && isfield(ctx.runtimeCfg.channel.narrowband, "enable") ...
    && logical(ctx.runtimeCfg.channel.narrowband.enable) ...
    && isfield(ctx.runtimeCfg.channel.narrowband, "weight") ...
    && double(ctx.runtimeCfg.channel.narrowband.weight) > 0;
end

function value = local_probability_scalar_local(rawValue, ownerName)
value = double(rawValue);
if ~(isscalar(value) && isfinite(value) && value >= 0 && value <= 1)
    error("%s must be a scalar in [0, 1], got %g.", ownerName, value);
end
end

function value = local_nonnegative_scalar_local(rawValue, ownerName)
value = double(rawValue);
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("%s must be a nonnegative finite scalar, got %g.", ownerName, value);
end
end

function xCore = local_apply_sc_fde_mmse_core_local(core, h, lambda, coreLen)
core = core(:);
h = h(:);
if numel(h) > coreLen
    error("SC-FDE core length %d is shorter than channel length %d.", coreLen, numel(h));
end
if ~isfinite(lambda)
    xCore = core;
    return;
end
H = fft([h; complex(zeros(coreLen - numel(h), 1))]);
denom = abs(H).^2 + lambda;
if any(~isfinite(denom)) || any(denom <= 0)
    error("SC-FDE MMSE denominator is invalid.");
end
xCore = ifft(conj(H) ./ denom .* fft(core));
end

function [xCoreOut, reliability, mse] = local_sc_fde_pilot_scalar_simple_local(xCore, pilot, cfg)
xCore = xCore(:);
pilot = pilot(:);
if numel(xCore) < numel(pilot)
    error("SC-FDE pilot length exceeds equalized core length.");
end
pilotRx = xCore(1:numel(pilot));
alpha = sum(pilotRx .* conj(pilot)) / max(sum(abs(pilot).^2), eps);
if abs(alpha) < max(double(cfg.pilotMinAbsGain), eps)
    alpha = 1;
end
xCoreOut = xCore / alpha;
mse = mean(abs(xCoreOut(1:numel(pilot)) - pilot).^2);
if ~(isscalar(mse) && isfinite(mse) && mse >= 0)
    error("SC-FDE pilot residual MSE is invalid.");
end
reliability = 1 / (1 + mse / max(double(cfg.pilotMseReference), eps));
reliability = max(double(cfg.minReliability), min(1, reliability));
end

function [coreOut, relOut] = local_sc_fde_mrc_combine_branch_cores_local(coreList, relList, gains, scoreWeights, ownerName)
if nargin < 4 || isempty(scoreWeights)
    scoreWeights = ones(numel(coreList), 1);
end
if nargin < 5 || strlength(string(ownerName)) == 0
    ownerName = "SC-FDE diversity combining";
end
if ~(iscell(coreList) && iscell(relList) && numel(coreList) == numel(relList) ...
        && numel(gains) == numel(coreList) && numel(scoreWeights) == numel(coreList))
    error("%s requires matched core/reliability/gain lists.", char(ownerName));
end

scoreWeights = double(scoreWeights(:));
validMask = false(numel(coreList), 1);
coreLen = [];
for branchIdx = 1:numel(coreList)
    coreNow = coreList{branchIdx};
    relNow = relList{branchIdx};
    if isempty(coreNow) || isempty(relNow)
        error("%s branch %d is empty.", char(ownerName), branchIdx);
    end
    coreNow = coreNow(:);
    relNow = rx_expand_reliability(relNow, numel(coreNow));
    coreList{branchIdx} = coreNow;
    relList{branchIdx} = relNow;
    gainNow = gains(branchIdx);
    scoreNow = scoreWeights(branchIdx);
    if ~(isfinite(gainNow) && abs(gainNow) > 0 && isfinite(scoreNow) && scoreNow > 0)
        continue;
    end
    validMask(branchIdx) = true;
    if isempty(coreLen)
        coreLen = numel(coreNow);
    elseif numel(coreNow) ~= coreLen
        error("%s branch lengths are inconsistent.", char(ownerName));
    end
end
if ~any(validMask)
    error("%s produced no valid branch gains.", char(ownerName));
end

usedIdx = find(validMask);
coreMat = complex(zeros(coreLen, numel(usedIdx)));
relMat = zeros(coreLen, numel(usedIdx));
gainUse = complex(zeros(numel(usedIdx), 1));
scoreUse = zeros(numel(usedIdx), 1);
for k = 1:numel(usedIdx)
    branchIdx = usedIdx(k);
    coreMat(:, k) = coreList{branchIdx};
    relMat(:, k) = relList{branchIdx};
    gainUse(k) = gains(branchIdx);
    scoreUse(k) = scoreWeights(branchIdx);
end
powerWeights = abs(gainUse).^2 .* scoreUse;
denom = sum(powerWeights);
if ~(isfinite(denom) && denom > 0)
    error("%s denominator is invalid.", char(ownerName));
end
combineWeights = conj(gainUse) .* scoreUse;
coreOut = (coreMat * combineWeights) / denom;
relOut = (relMat * powerWeights) / denom;
end

function [core, relCore] = local_sc_fde_core_from_physical_hop_local(r, rel, hopIdx, plan)
blockIdx = (hopIdx - 1) * plan.hopLen + (1:plan.hopLen);
if blockIdx(end) > numel(r)
    error("SC-FDE hop %d exceeds received payload length.", hopIdx);
end
block = r(blockIdx);
relBlock = rel(blockIdx);
core = block(plan.cpLen + 1:end);
relCore = relBlock(plan.cpLen + 1:end);
if numel(core) ~= plan.coreLen || numel(relCore) ~= plan.coreLen
    error("SC-FDE core extraction length mismatch.");
end
end

function [hopFreqs, hBank, bankMode] = local_sc_fde_payload_channel_bank_local(ctx, frontEndDiag, nHops)
nHops = max(0, round(double(nHops)));
hopFreqs = local_sc_fde_hop_frequencies_local(ctx.pkt, nHops);
hBank = cell(nHops, 1);
if nHops == 0
    bankMode = "shared";
    return;
end

eq = struct();
if isfield(frontEndDiag, "payloadEqualizer") && isstruct(frontEndDiag.payloadEqualizer)
    eq = frontEndDiag.payloadEqualizer;
end

if isfield(eq, "hBank") && ~isempty(eq.hBank) && isfield(eq, "frequencyOffsets") && ~isempty(eq.frequencyOffsets)
    bankIdx = local_equalizer_bank_indices_for_freqs_local(eq.frequencyOffsets, hopFreqs);
    for hopIdx = 1:nHops
        hBank{hopIdx} = eq.hBank(:, bankIdx(hopIdx));
    end
    bankMode = "frequency_bank";
    return;
elseif isfield(eq, "hEst") && ~isempty(eq.hEst)
    hBase = eq.hEst(:);
    if isfield(eq, "symbolDelays") && ~isempty(eq.symbolDelays)
        delayAxis = double(eq.symbolDelays(:));
    else
        delayAxis = (0:numel(hBase)-1).';
    end
    for hopIdx = 1:nHops
        hBank{hopIdx} = hBase .* exp(-1j * 2 * pi * double(hopFreqs(hopIdx)) * delayAxis);
    end
    bankMode = "preamble_phase_shift";
    return;
elseif isfield(ctx.rxCfg, "channelState") && isstruct(ctx.rxCfg.channelState) ...
        && isfield(ctx.rxCfg.channelState, "multipathTaps") && ~isempty(ctx.rxCfg.channelState.multipathTaps)
    hBaseSample = ctx.rxCfg.channelState.multipathTaps(:);
    if ~(isfield(ctx.waveform, "sps") && isfinite(double(ctx.waveform.sps)) && double(ctx.waveform.sps) >= 1)
        error("SC-FDE payload decode requires waveform.sps when using channelState.multipathTaps.");
    end
    sps = max(1, round(double(ctx.waveform.sps)));
    hBase = hBaseSample(1:sps:end);
    sampleDelays = (0:numel(hBase)-1).';
    for hopIdx = 1:nHops
        hBank{hopIdx} = hBase .* exp(-1j * 2 * pi * double(hopFreqs(hopIdx)) * sampleDelays);
    end
    bankMode = "channel_state_phase_shift";
    return;
else
    error("Rayleigh multipath receiver requires a preamble-estimated or channelState multipath channel.");
end
end

function hopFreqs = local_sc_fde_hop_frequencies_local(pkt, nHops)
nHops = max(0, round(double(nHops)));
hopFreqs = zeros(nHops, 1);
if nHops == 0
    return;
end
if ~(isfield(pkt, "hopInfo") && isstruct(pkt.hopInfo) && isfield(pkt.hopInfo, "enable") && logical(pkt.hopInfo.enable))
    return;
end
if ~(isfield(pkt.hopInfo, "freqOffsets") && ~isempty(pkt.hopInfo.freqOffsets))
    error("SC-FDE MMSE requires hopInfo.freqOffsets when FH is enabled.");
end
freqOffsets = double(pkt.hopInfo.freqOffsets(:));
if numel(freqOffsets) < nHops
    error("SC-FDE MMSE needs %d hop frequencies, got %d.", nHops, numel(freqOffsets));
end
hopFreqs = freqOffsets(1:nHops);
end

function eqCfg = local_header_equalizer_cfg_local(runtimeCfg, pkt)
eqCfg = runtimeCfg.rxSync.multipathEq;
eqCfg.method = "mmse";
if isfield(pkt, "hopInfo") && isstruct(pkt.hopInfo) && isfield(pkt.hopInfo, "freqOffsets") && ~isempty(pkt.hopInfo.freqOffsets)
    eqCfg.frequencyOffsets = unique([0, double(pkt.hopInfo.freqOffsets(:).')], "stable");
else
    eqCfg.frequencyOffsets = 0;
end
end

function freqBySymbol = local_packet_frequency_offsets_local(pkt, nSym)
nSym = round(double(nSym));
freqBySymbol = zeros(nSym, 1);
if nSym <= 0
    return;
end

nSync = numel(pkt.syncSym);
nHeader = round(double(pkt.nPhyHeaderSymTx));
headerStart = nSync + 1;
dataStart = nSync + nHeader + 1;

if isfield(pkt, "preambleHopInfo") && isstruct(pkt.preambleHopInfo) ...
        && isfield(pkt.preambleHopInfo, "enable") && logical(pkt.preambleHopInfo.enable)
    preLen = min(nSym, nSync);
    if preLen > 0
        freqBySymbol(1:preLen) = local_expand_hop_frequency_offsets_local(pkt.preambleHopInfo, preLen);
    end
end
if isfield(pkt, "phyHeaderHopInfo") && isstruct(pkt.phyHeaderHopInfo) ...
        && isfield(pkt.phyHeaderHopInfo, "enable") && logical(pkt.phyHeaderHopInfo.enable) ...
        && headerStart <= nSym
    hdrLen = min(nHeader, nSym - headerStart + 1);
    if hdrLen > 0
        freqBySymbol(headerStart:headerStart + hdrLen - 1) = ...
            local_expand_hop_frequency_offsets_local(pkt.phyHeaderHopInfo, hdrLen);
    end
end
if isfield(pkt, "hopInfo") && isstruct(pkt.hopInfo) ...
        && isfield(pkt.hopInfo, "enable") && logical(pkt.hopInfo.enable) ...
        && dataStart <= nSym
    dataLen = nSym - dataStart + 1;
    if dataLen > 0
        freqBySymbol(dataStart:end) = local_expand_hop_frequency_offsets_local(pkt.hopInfo, dataLen);
    end
end
end

function freqBySymbol = local_expand_hop_frequency_offsets_local(hopInfo, nSym)
nSym = round(double(nSym));
if ~(isstruct(hopInfo) && isfield(hopInfo, "enable") && logical(hopInfo.enable))
    freqBySymbol = zeros(nSym, 1);
    return;
end
hopLen = round(double(hopInfo.hopLen));
if ~(isscalar(hopLen) && isfinite(hopLen) && hopLen >= 1)
    error("Slow FH equalizer expansion requires a positive finite hopLen.");
end
if ~(isfield(hopInfo, "freqOffsets") && ~isempty(hopInfo.freqOffsets))
    error("FH equalizer expansion requires hopInfo.freqOffsets.");
end
freqOffsets = double(hopInfo.freqOffsets(:));
nHops = ceil(double(nSym) / double(hopLen));
if numel(freqOffsets) < nHops
    error("FH equalizer expansion needs %d hop frequencies, got %d.", nHops, numel(freqOffsets));
end
freqBySymbol = repelem(freqOffsets(1:nHops), hopLen, 1);
freqBySymbol = freqBySymbol(1:nSym);
end

function yEq = local_apply_frequency_aware_equalizer_block_local(y, eq, freqBySymbol)
y = y(:);
N = numel(y);
freqBySymbol = double(freqBySymbol(:));
if numel(freqBySymbol) ~= N
    error("Equalizer frequency vector length %d does not match block length %d.", numel(freqBySymbol), N);
end
if N == 0
    yEq = y;
    return;
end
if ~(isstruct(eq) && isfield(eq, "enabled") && logical(eq.enabled))
    error("Frequency-aware multipath equalizer requires eq.enabled=true.");
end
if ~(isfield(eq, "gBank") && ~isempty(eq.gBank) && isfield(eq, "frequencyOffsets") && ~isempty(eq.frequencyOffsets))
    error("Frequency-aware multipath equalizer requires eq.gBank and eq.frequencyOffsets.");
end
if ~(isfield(eq, "delay") && isfield(eq, "eqLen"))
    error("Frequency-aware multipath equalizer requires eq.delay and eq.eqLen.");
end

d = max(0, round(double(eq.delay)));
Leq = round(double(eq.eqLen));
gBank = eq.gBank;
if size(gBank, 1) ~= Leq
    error("Equalizer bank row count %d does not match eq.eqLen=%d.", size(gBank, 1), Leq);
end

bankIdx = local_equalizer_bank_indices_for_freqs_local(eq.frequencyOffsets, freqBySymbol);
yEq = complex(zeros(N, 1));
for n = 1:N
    g = gBank(:, bankIdx(n));
    acc = complex(0, 0);
    for tap = 1:Leq
        srcIdx = n + d - tap + 1;
        if srcIdx >= 1 && srcIdx <= N
            acc = acc + g(tap) * y(srcIdx);
        end
    end
    yEq(n) = acc;
end
end

function bankIdx = local_equalizer_bank_indices_for_freqs_local(frequencyOffsets, freqBySymbol)
frequencyOffsets = double(frequencyOffsets(:));
freqBySymbol = double(freqBySymbol(:));
bankIdx = zeros(numel(freqBySymbol), 1);
for idx = 1:numel(freqBySymbol)
    [errNow, bankIdx(idx)] = min(abs(frequencyOffsets - freqBySymbol(idx)));
    if isempty(bankIdx(idx)) || errNow > 1e-10
        error("Equalizer bank does not contain normalized frequency %.12g.", freqBySymbol(idx));
    end
end
end

function tf = local_sc_fde_mmse_active_local(method)
method = lower(string(method));
tf = any(method == ["sc_fde_mmse" "robust_combo"]);
end

function tf = local_robust_unified_active_local(ctx)
tf = isstruct(ctx) && isfield(ctx, "profileName") && string(ctx.profileName) == "robust_unified";
end

function [headerSym, dataSym, symbolReliability, diagOut] = local_failed_frontend_placeholder_local(pkt)
headerSym = complex(zeros(double(pkt.nPhyHeaderSymTx), 1));
dataSym = complex(zeros(double(pkt.nDataSymTx), 1));
symbolReliability = zeros(double(pkt.nDataSymTx), 1);
diagOut = struct("ok", false, "reason", "capture_failed");
end
