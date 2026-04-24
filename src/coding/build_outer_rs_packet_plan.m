function plan = build_outer_rs_packet_plan(payloadBits, pktBitsPerPacket, rsCfg)
%BUILD_OUTER_RS_PACKET_PLAN  Build systematic packet-level RS layout.

payloadBits = uint8(payloadBits(:) ~= 0);
pktBitsPerPacket = round(double(pktBitsPerPacket));
if pktBitsPerPacket <= 0 || mod(pktBitsPerPacket, 8) ~= 0
    error("pktBitsPerPacket 必须是正的8整数倍。");
end

rsCfg = resolve_outer_rs_cfg(rsCfg);
pktBytesPerPacket = pktBitsPerPacket / 8;
totalBits = numel(payloadBits);
nDataPackets = max(1, ceil(totalBits / pktBitsPerPacket));

payloadData = cell(nDataPackets, 1);
for dataIdx = 1:nDataPackets
    startBit = (dataIdx - 1) * pktBitsPerPacket + 1;
    endBit = min(dataIdx * pktBitsPerPacket, totalBits);
    payloadData{dataIdx} = payloadBits(startBit:endBit);
end

packetTemplate = struct( ...
    "packetIndex", uint16(0), ...
    "isDataPacket", false, ...
    "isParityPacket", false, ...
    "sourcePacketIndex", uint16(0), ...
    "blockIndex", uint16(0), ...
    "blockDataCount", uint16(0), ...
    "blockParityCount", uint16(0), ...
    "blockLocalDataIndex", uint16(0), ...
    "blockLocalParityIndex", uint16(0), ...
    "startBit", 0, ...
    "endBit", 0, ...
    "payloadBitsPlain", uint8([]));
packetSpecs = repmat(packetTemplate, 0, 1);

nextTxIndex = 1;
nextDataIndex = 1;
nextStartBit = 1;
blockIndex = 0;
totalParityPackets = 0;

while nextDataIndex <= nDataPackets
    blockIndex = blockIndex + 1;
    kBlock = 1;
    if rsCfg.enable
        kBlock = min(rsCfg.dataPacketsPerBlock, nDataPackets - nextDataIndex + 1);
    else
        kBlock = nDataPackets - nextDataIndex + 1;
    end

    dataBytes = zeros(kBlock, pktBytesPerPacket, "uint8");
    for localDataIdx = 1:kBlock
        sourcePacketIndex = nextDataIndex + localDataIdx - 1;
        payloadBitsNow = payloadData{sourcePacketIndex};
        startBit = nextStartBit;
        endBit = nextStartBit + numel(payloadBitsNow) - 1;

        spec = packetTemplate;
        spec.packetIndex = uint16(nextTxIndex);
        spec.isDataPacket = true;
        spec.isParityPacket = false;
        spec.sourcePacketIndex = uint16(sourcePacketIndex);
        spec.blockIndex = uint16(blockIndex);
        spec.blockDataCount = uint16(kBlock);
        spec.blockParityCount = uint16(rsCfg.parityPacketsPerBlock);
        spec.blockLocalDataIndex = uint16(localDataIdx);
        spec.blockLocalParityIndex = uint16(0);
        spec.startBit = startBit;
        spec.endBit = endBit;
        spec.payloadBitsPlain = payloadBitsNow;
        packetSpecs(end+1, 1) = spec; %#ok<AGROW>

        dataBytes(localDataIdx, :) = bits_to_uint( ...
            fit_bits_length(payloadBitsNow, pktBitsPerPacket), "uint8vec").';
        nextTxIndex = nextTxIndex + 1;
        nextStartBit = endBit + 1;
    end

    if rsCfg.enable
        parityBytes = local_rs_encode_parity_bytes_local(dataBytes, rsCfg.parityPacketsPerBlock);
        for localParityIdx = 1:rsCfg.parityPacketsPerBlock
            spec = packetTemplate;
            spec.packetIndex = uint16(nextTxIndex);
            spec.isDataPacket = false;
            spec.isParityPacket = true;
            spec.sourcePacketIndex = uint16(0);
            spec.blockIndex = uint16(blockIndex);
            spec.blockDataCount = uint16(kBlock);
            spec.blockParityCount = uint16(rsCfg.parityPacketsPerBlock);
            spec.blockLocalDataIndex = uint16(0);
            spec.blockLocalParityIndex = uint16(localParityIdx);
            spec.startBit = 0;
            spec.endBit = 0;
            spec.payloadBitsPlain = uint_to_bits(parityBytes(localParityIdx, :).', "uint8vec");
            packetSpecs(end+1, 1) = spec; %#ok<AGROW>
            nextTxIndex = nextTxIndex + 1;
            totalParityPackets = totalParityPackets + 1;
        end
    end

    nextDataIndex = nextDataIndex + kBlock;
end

packetSpecs = local_interleave_packets_across_blocks_local(packetSpecs);

plan = struct();
plan.enable = rsCfg.enable;
plan.packetBitsPerPacket = pktBitsPerPacket;
plan.packetBytesPerPacket = pktBytesPerPacket;
plan.totalPayloadBits = totalBits;
plan.dataPacketCount = nDataPackets;
plan.parityPacketCount = totalParityPackets;
plan.totalTxPacketCount = numel(packetSpecs);
plan.dataPacketsPerBlock = rsCfg.dataPacketsPerBlock;
plan.parityPacketsPerBlock = rsCfg.parityPacketsPerBlock;
plan.packetSpecs = packetSpecs;
end

function packetSpecsOut = local_interleave_packets_across_blocks_local(packetSpecsIn)
packetSpecsIn = packetSpecsIn(:);
nPackets = numel(packetSpecsIn);
if nPackets <= 1
    packetSpecsOut = packetSpecsIn;
    return;
end

blockIds = double([packetSpecsIn.blockIndex]);
if any(~isfinite(blockIds)) || any(blockIds < 1)
    error("RS packet interleaver requires positive finite blockIndex values.");
end
blockOrder = unique(blockIds(:).', "stable");
nBlocks = numel(blockOrder);
if nBlocks <= 1
    packetSpecsOut = packetSpecsIn;
    return;
end

idxByBlock = cell(nBlocks, 1);
for blockPos = 1:nBlocks
    idxNow = find(blockIds == blockOrder(blockPos));
    if isempty(idxNow)
        error("RS packet interleaver failed to collect packet indices for blockIndex=%g.", blockOrder(blockPos));
    end
    idxByBlock{blockPos} = idxNow(:).';
end

blockCounts = cellfun(@numel, idxByBlock);
maxBlockLen = max(blockCounts);
perm = zeros(nPackets, 1);
dst = 1;
for pos = 1:maxBlockLen
    for blockPos = 1:nBlocks
        idxNow = idxByBlock{blockPos};
        if pos > numel(idxNow)
            continue;
        end
        perm(dst) = idxNow(pos);
        dst = dst + 1;
    end
end

if dst ~= nPackets + 1
    error("RS packet interleaver produced %d mapped packets, expected %d.", dst - 1, nPackets);
end
if numel(unique(perm)) ~= nPackets || any(perm < 1 | perm > nPackets)
    error("RS packet interleaver generated an invalid permutation.");
end
packetSpecsOut = packetSpecsIn(perm);
end

function parityBytes = local_rs_encode_parity_bytes_local(dataBytes, parityPackets)
if parityPackets <= 0
    parityBytes = zeros(0, size(dataBytes, 2), "uint8");
    return;
end
if exist("comm.RSEncoder", "class") ~= 8
    error("需要 Communications Toolbox 的 comm.RSEncoder 才能启用跨包RS外码。");
end

[kBlock, pktBytes] = size(dataBytes);
nBlock = kBlock + parityPackets;
primitivePoly = local_primitive_poly_local();
enc = comm.RSEncoder(nBlock, kBlock, "BitInput", false, ...
    "PrimitivePolynomialSource", "Property", ...
    "PrimitivePolynomial", primitivePoly);
parityBytes = zeros(parityPackets, pktBytes, "uint8");
for col = 1:pktBytes
    codeCol = enc(double(dataBytes(:, col)));
    parityBytes(:, col) = uint8(codeCol(kBlock+1:end));
end
end

function primitivePoly = local_primitive_poly_local()
primitiveDecimal = uint16(primpoly(8, "nodisplay"));
primitivePoly = double(bitget(primitiveDecimal, 9:-1:1));
end
