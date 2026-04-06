function [payloadBitsOut, dataPacketOkOut, info] = outer_rs_recover_payload( ...
    rxPayloadByTxPacket, txPacketOk, txPackets, totalPayloadBits, pktBitsPerPacket, rsCfg)
%OUTER_RS_RECOVER_PAYLOAD  Recover missing source packets using packet-level RS erasures.

rxPayloadByTxPacket = rxPayloadByTxPacket(:);
txPacketOk = logical(txPacketOk(:));
txPackets = txPackets(:);
totalPayloadBits = round(double(totalPayloadBits));
pktBitsPerPacket = round(double(pktBitsPerPacket));
rsCfg = resolve_outer_rs_cfg(rsCfg);

if numel(rxPayloadByTxPacket) ~= numel(txPackets) || numel(txPacketOk) ~= numel(txPackets)
    error("outer_rs_recover_payload 输入长度不一致。");
end
if pktBitsPerPacket <= 0 || mod(pktBitsPerPacket, 8) ~= 0
    error("pktBitsPerPacket 必须是正的8整数倍。");
end

pktBytesPerPacket = pktBitsPerPacket / 8;
dataMask = arrayfun(@(pkt) logical(pkt.isDataPacket), txPackets);
nDataPackets = sum(dataMask);

payloadBitsOut = zeros(totalPayloadBits, 1, "uint8");
dataPacketOkOut = false(1, nDataPackets);
rawDataPacketOk = false(1, nDataPackets);
recoveredByRs = false(1, nDataPackets);

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
end

if rsCfg.enable
    blockIndexList = unique(double([txPackets.blockIndex]));
    for blockIndex = blockIndexList(:).'
        blockMask = double([txPackets.blockIndex]) == blockIndex;
        blockPackets = txPackets(blockMask);
        blockOk = txPacketOk(blockMask);
        blockPayload = rxPayloadByTxPacket(blockMask);
        kBlock = double(blockPackets(1).blockDataCount);
        pBlock = double(blockPackets(1).blockParityCount);
        if pBlock <= 0
            continue;
        end
        if sum(blockOk) < kBlock
            continue;
        end

        try
            dataBytes = local_rs_decode_block_bytes_local(blockPayload, blockOk, blockPackets, pktBytesPerPacket, kBlock, pBlock);
        catch
            continue;
        end

        for localDataIdx = 1:kBlock
            pkt = blockPackets(localDataIdx);
            srcIdx = double(pkt.sourcePacketIndex);
            if dataPacketOkOut(srcIdx)
                continue;
            end
            bitsFull = uint_to_bits(uint8(dataBytes(localDataIdx, :).'), "uint8vec");
            needBits = max(0, pkt.endBit - pkt.startBit + 1);
            payloadBitsNow = fit_bits_length(bitsFull, needBits);
            if needBits > 0
                payloadBitsOut(pkt.startBit:pkt.endBit) = payloadBitsNow;
            end
            dataPacketOkOut(srcIdx) = true;
            recoveredByRs(srcIdx) = true;
        end
    end
end

info = struct();
info.rawDataPacketOk = rawDataPacketOk;
info.recoveredByRs = recoveredByRs;
info.rawDataPacketSuccessRate = mean(double(rawDataPacketOk));
info.effectiveDataPacketSuccessRate = mean(double(dataPacketOkOut));
info.recoveredPacketCount = sum(double(recoveredByRs));
end

function dataBytes = local_rs_decode_block_bytes_local(blockPayload, blockOk, blockPackets, pktBytesPerPacket, kBlock, pBlock)
if exist("comm.RSDecoder", "class") ~= 8
    error("需要 Communications Toolbox 的 comm.RSDecoder 才能启用跨包RS外码。");
end

nBlock = kBlock + pBlock;
if numel(blockPackets) ~= nBlock || numel(blockPayload) ~= nBlock || numel(blockOk) ~= nBlock
    error("RS block 输入长度与块参数不一致。");
end
if sum(double(~blockOk)) > pBlock
    error("RS块擦除数超过可纠正上限。");
end

dataBytes = zeros(kBlock, pktBytesPerPacket, "uint8");
primitivePoly = local_primitive_poly_local();
dec = comm.RSDecoder(nBlock, kBlock, "BitInput", false, ...
    "PrimitivePolynomialSource", "Property", ...
    "PrimitivePolynomial", primitivePoly, ...
    "ErasuresInputPort", true, "NumCorrectedErrorsOutputPort", false);
erasures = ~logical(blockOk(:));

for col = 1:pktBytesPerPacket
    codeCol = zeros(nBlock, 1);
    for pktIdx = 1:nBlock
        if ~blockOk(pktIdx)
            continue;
        end
        bitsNow = fit_bits_length(blockPayload{pktIdx}, pktBytesPerPacket * 8);
        bytesNow = bits_to_uint(bitsNow, "uint8vec");
        codeCol(pktIdx) = double(bytesNow(col));
    end
    decodedCol = dec(codeCol, erasures);
    dataBytes(:, col) = uint8(decodedCol);
end
end

function primitivePoly = local_primitive_poly_local()
primitiveDecimal = uint16(primpoly(8, "nodisplay"));
primitivePoly = double(bitget(primitiveDecimal, 9:-1:1));
end
