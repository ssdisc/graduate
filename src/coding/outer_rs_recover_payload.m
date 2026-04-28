function [payloadBitsOut, dataPacketOkOut, info] = outer_rs_recover_payload( ...
    rxPayloadByTxPacket, txPacketOk, txPackets, totalPayloadBits, pktBitsPerPacket, rsCfg, packetReliability)
%OUTER_RS_RECOVER_PAYLOAD  Recover packet payloads with RS erasures and block rewrite.

rxPayloadByTxPacket = rxPayloadByTxPacket(:);
txPacketOk = logical(txPacketOk(:));
txPackets = txPackets(:);
totalPayloadBits = round(double(totalPayloadBits));
pktBitsPerPacket = round(double(pktBitsPerPacket));
rsCfg = resolve_outer_rs_cfg(rsCfg);
if nargin < 7
    packetReliability = [];
end

if numel(rxPayloadByTxPacket) ~= numel(txPackets) || numel(txPacketOk) ~= numel(txPackets)
    error("outer_rs_recover_payload 输入长度不一致。");
end
if pktBitsPerPacket <= 0 || mod(pktBitsPerPacket, 8) ~= 0
    error("pktBitsPerPacket 必须是正的8整数倍。");
end

pktBytesPerPacket = pktBitsPerPacket / 8;
dataMask = arrayfun(@(pkt) logical(pkt.isDataPacket), txPackets);
nDataPackets = sum(dataMask);
packetReliability = local_normalize_packet_reliability_local(packetReliability, txPacketOk, numel(txPackets));

payloadBitsOut = zeros(totalPayloadBits, 1, "uint8");
dataPacketOkOut = false(1, nDataPackets);
rawDataPacketOk = false(1, nDataPackets);
recoveredByRs = false(1, nDataPackets);
rewrittenByRs = false(1, nDataPackets);
rawPacketReliability = zeros(1, nDataPackets);
jointDecodeApplied = false;
blockDiagTemplate = struct( ...
    "blockIndex", NaN, ...
    "selectedAttemptIndex", NaN, ...
    "baseErasureCount", NaN, ...
    "extraErasureCount", NaN, ...
    "attemptCount", 0, ...
    "selectedScore", NaN, ...
    "rewriteApplied", false);
blockDiagnostics = repmat(blockDiagTemplate, 0, 1);

for txIdx = 1:numel(txPackets)
    pkt = txPackets(txIdx);
    if ~pkt.isDataPacket || ~txPacketOk(txIdx)
        continue;
    end
    srcIdx = double(pkt.sourcePacketIndex);
    if srcIdx < 1 || srcIdx > nDataPackets
        error("txPackets(%d).sourcePacketIndex 无效。", txIdx);
    end
    needBits = max(0, pkt.endBit - pkt.startBit + 1);
    payloadBitsNow = fit_bits_length(rxPayloadByTxPacket{txIdx}, needBits);
    if needBits > 0
        payloadBitsOut(pkt.startBit:pkt.endBit) = payloadBitsNow;
    end
    dataPacketOkOut(srcIdx) = true;
    rawDataPacketOk(srcIdx) = true;
    rawPacketReliability(srcIdx) = packetReliability(txIdx);
end

if rsCfg.enable
    blockIndexList = unique(double([txPackets.blockIndex]));
    for blockIndex = blockIndexList(:).'
        blockMask = double([txPackets.blockIndex]) == blockIndex;
        blockPackets = txPackets(blockMask);
        blockOk = txPacketOk(blockMask);
        blockPayload = rxPayloadByTxPacket(blockMask);
        blockReliability = packetReliability(blockMask);
        kBlock = double(blockPackets(1).blockDataCount);
        pBlock = double(blockPackets(1).blockParityCount);
        if pBlock <= 0
            continue;
        end
        if numel(blockOk) < kBlock || all(blockOk(1:kBlock))
            continue;
        end
        if sum(blockOk) < kBlock
            continue;
        end

        [candidateDataBytes, candidateInfo] = local_select_block_candidate_local( ...
            blockPayload, blockOk, blockReliability, blockPackets, pktBytesPerPacket, kBlock, pBlock, rsCfg);
        if isempty(candidateDataBytes)
            continue;
        end
        jointDecodeApplied = jointDecodeApplied || logical(candidateInfo.extraErasureCount > 0);
        blockDiagnostics(end+1, 1) = struct( ...
            "blockIndex", double(blockIndex), ...
            "selectedAttemptIndex", double(candidateInfo.selectedAttemptIndex), ...
            "baseErasureCount", double(candidateInfo.baseErasureCount), ...
            "extraErasureCount", double(candidateInfo.extraErasureCount), ...
            "attemptCount", double(candidateInfo.attemptCount), ...
            "selectedScore", double(candidateInfo.selectedScore), ...
            "rewriteApplied", logical(rsCfg.rewriteDecodedDataPackets));

        for localDataIdx = 1:kBlock
            pkt = blockPackets(localDataIdx);
            srcIdx = double(pkt.sourcePacketIndex);
            bitsFull = uint_to_bits(uint8(candidateDataBytes(localDataIdx, :).'), "uint8vec");
            needBits = max(0, pkt.endBit - pkt.startBit + 1);
            payloadBitsNow = fit_bits_length(bitsFull, needBits);
            oldPayloadBits = uint8([]);
            shouldRewrite = ~rawDataPacketOk(srcIdx) || logical(rsCfg.rewriteDecodedDataPackets);
            if needBits > 0
                oldPayloadBits = payloadBitsOut(pkt.startBit:pkt.endBit);
            end
            if needBits > 0 && shouldRewrite
                payloadBitsOut(pkt.startBit:pkt.endBit) = payloadBitsNow;
            end
            if rawDataPacketOk(srcIdx) && rsCfg.rewriteDecodedDataPackets ...
                    && (~isequal(oldPayloadBits, payloadBitsNow))
                rewrittenByRs(srcIdx) = true;
            end
            dataPacketOkOut(srcIdx) = true;
            if ~rawDataPacketOk(srcIdx)
                recoveredByRs(srcIdx) = true;
            end
        end
    end
end

info = struct();
info.rawDataPacketOk = rawDataPacketOk;
info.recoveredByRs = recoveredByRs;
info.rewrittenByRs = rewrittenByRs;
info.rawPacketReliability = rawPacketReliability;
info.rawDataPacketSuccessRate = mean(double(rawDataPacketOk));
info.effectiveDataPacketSuccessRate = mean(double(dataPacketOkOut));
info.recoveredPacketCount = sum(double(recoveredByRs));
info.rewrittenPacketCount = sum(double(rewrittenByRs));
info.jointDecodeApplied = logical(jointDecodeApplied);
info.blockDiagnostics = blockDiagnostics;
end

function [dataBytesBest, info] = local_select_block_candidate_local( ...
    blockPayload, blockOk, blockReliability, blockPackets, pktBytesPerPacket, kBlock, pBlock, rsCfg)
baseErasures = ~logical(blockOk(:));
baseErasureCount = sum(double(baseErasures));
goodIdx = find(~baseErasures);
reliabilityGood = blockReliability(goodIdx);
[~, orderLocal] = sort(reliabilityGood, "ascend");
sortedGoodIdx = goodIdx(orderLocal);
extraBudget = pBlock - baseErasureCount;

extraCandidateMask = false(size(sortedGoodIdx));
if rsCfg.reliabilityDrivenErasure && numel(sortedGoodIdx) >= 2
    relSorted = reliabilityGood(orderLocal);
    extraCandidateMask = abs(relSorted - max(relSorted)) > 1e-6;
end
sortedExtraIdx = sortedGoodIdx(extraCandidateMask);
maxExtraTrials = min(extraBudget, numel(sortedExtraIdx));

bestScore = inf;
bestExtraErasureCount = NaN;
bestAttemptIndex = NaN;
bestDataBytes = zeros(0, pktBytesPerPacket, "uint8");
attemptCount = 0;

for extraCount = 0:maxExtraTrials
    erasures = baseErasures;
    if extraCount > 0
        erasures(sortedExtraIdx(1:extraCount)) = true;
    end
    if sum(double(~erasures)) < kBlock
        continue;
    end
    attemptCount = attemptCount + 1;
    try
        [candidateDataBytes, fullCodeBytes] = local_rs_decode_block_bytes_local( ...
            blockPayload, erasures, blockPackets, pktBytesPerPacket, kBlock, pBlock);
    catch
        continue;
    end
    score = local_candidate_score_local(fullCodeBytes, blockPayload, blockOk, erasures, blockReliability, pktBytesPerPacket, extraCount);
    if score + 1e-12 < bestScore
        bestScore = score;
        bestExtraErasureCount = extraCount;
        bestAttemptIndex = attemptCount;
        bestDataBytes = candidateDataBytes;
    end
end

dataBytesBest = bestDataBytes;
info = struct( ...
    "attemptCount", double(attemptCount), ...
    "baseErasureCount", double(baseErasureCount), ...
    "extraErasureCount", double(bestExtraErasureCount), ...
    "selectedScore", double(bestScore), ...
    "selectedAttemptIndex", double(bestAttemptIndex));
end

function score = local_candidate_score_local(fullCodeBytes, blockPayload, blockOk, erasures, blockReliability, pktBytesPerPacket, extraCount)
weightSum = 0;
scoreSum = 0;
for pktIdx = 1:numel(blockOk)
    if ~blockOk(pktIdx) || erasures(pktIdx)
        continue;
    end
    bitsNow = fit_bits_length(blockPayload{pktIdx}, pktBytesPerPacket * 8);
    bytesNow = bits_to_uint(bitsNow, "uint8vec");
    bytesNow = uint8(bytesNow(:).');
    mismatchFraction = mean(double(fullCodeBytes(pktIdx, :) ~= bytesNow));
    weight = max(1e-3, double(blockReliability(pktIdx)));
    scoreSum = scoreSum + weight * mismatchFraction;
    weightSum = weightSum + weight;
end

if weightSum <= 0
    score = inf;
    return;
end

score = scoreSum / weightSum + 1e-3 * double(extraCount);
end

function [dataBytes, fullCodeBytes] = local_rs_decode_block_bytes_local(blockPayload, erasures, blockPackets, pktBytesPerPacket, kBlock, pBlock)
if exist("comm.RSDecoder", "class") ~= 8
    error("需要 Communications Toolbox 的 comm.RSDecoder 才能启用跨包RS外码。");
end

nBlock = kBlock + pBlock;
if numel(blockPackets) ~= nBlock || numel(blockPayload) ~= nBlock || numel(erasures) ~= nBlock
    error("RS block 输入长度与块参数不一致。");
end
if sum(double(erasures)) > pBlock
    error("RS块擦除数超过可纠正上限。");
end

dataBytes = zeros(kBlock, pktBytesPerPacket, "uint8");
primitivePoly = local_primitive_poly_local();
dec = comm.RSDecoder(nBlock, kBlock, "BitInput", false, ...
    "PrimitivePolynomialSource", "Property", ...
    "PrimitivePolynomial", primitivePoly, ...
    "ErasuresInputPort", true, "NumCorrectedErrorsOutputPort", false);
erasures = logical(erasures(:));
okMask = ~erasures;

for col = 1:pktBytesPerPacket
    codeCol = zeros(nBlock, 1);
    for pktIdx = 1:nBlock
        if ~okMask(pktIdx)
            continue;
        end
        bitsNow = fit_bits_length(blockPayload{pktIdx}, pktBytesPerPacket * 8);
        bytesNow = bits_to_uint(bitsNow, "uint8vec");
        codeCol(pktIdx) = double(bytesNow(col));
    end
    decodedCol = dec(codeCol, erasures);
    dataBytes(:, col) = uint8(decodedCol);
end
fullCodeBytes = local_rs_encode_full_code_bytes_local(dataBytes, pBlock);
end

function primitivePoly = local_primitive_poly_local()
primitiveDecimal = uint16(primpoly(8, "nodisplay"));
primitivePoly = double(bitget(primitiveDecimal, 9:-1:1));
end

function fullCodeBytes = local_rs_encode_full_code_bytes_local(dataBytes, parityPackets)
if exist("comm.RSEncoder", "class") ~= 8
    error("需要 Communications Toolbox 的 comm.RSEncoder 才能执行RS整块回写。");
end

[kBlock, pktBytes] = size(dataBytes);
nBlock = kBlock + parityPackets;
primitivePoly = local_primitive_poly_local();
enc = comm.RSEncoder(nBlock, kBlock, "BitInput", false, ...
    "PrimitivePolynomialSource", "Property", ...
    "PrimitivePolynomial", primitivePoly);
fullCodeBytes = zeros(nBlock, pktBytes, "uint8");
for col = 1:pktBytes
    codeCol = enc(double(dataBytes(:, col)));
    fullCodeBytes(:, col) = uint8(codeCol(:));
end
end

function packetReliability = local_normalize_packet_reliability_local(packetReliabilityIn, txPacketOk, nPackets)
if isempty(packetReliabilityIn)
    packetReliability = double(txPacketOk(:));
else
    packetReliability = double(packetReliabilityIn(:));
    if numel(packetReliability) ~= nPackets
        error("outer_rs_recover_payload packetReliability length mismatch: got %d, need %d.", ...
            numel(packetReliability), nPackets);
    end
    packetReliability(~isfinite(packetReliability)) = 0;
    packetReliability = max(min(packetReliability, 1), 0);
    packetReliability(~txPacketOk(:)) = 0;
end
end
