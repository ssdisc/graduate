function mask = build_dct_pixel_mask_from_packets(packetOk, txPackets, meta, payload)
rows = double(meta.rows);
cols = double(meta.cols);
ch = double(meta.channels);

dctCfg = struct();
if isfield(payload, "dct") && isstruct(payload.dct)
    dctCfg = payload.dct;
end
if ~isfield(dctCfg, "blockSize"); dctCfg.blockSize = 8; end
if ~isfield(dctCfg, "keepRows"); dctCfg.keepRows = 4; end
if ~isfield(dctCfg, "keepCols"); dctCfg.keepCols = 4; end
dctCfg.blockSize = max(2, round(double(dctCfg.blockSize)));
dctCfg.keepRows = max(1, round(double(dctCfg.keepRows)));
dctCfg.keepCols = max(1, round(double(dctCfg.keepCols)));
dctCfg.keepRows = min(dctCfg.keepRows, dctCfg.blockSize);
dctCfg.keepCols = min(dctCfg.keepCols, dctCfg.blockSize);

B = dctCfg.blockSize;
nBr = ceil(rows / B);
nBc = ceil(cols / B);
nBlocksPerCh = nBr * nBc;
totalBlocks = nBlocksPerCh * ch;
bytesPerBlock = dctCfg.keepRows * dctCfg.keepCols * 2;

maskBlocks = false(nBr, nBc, ch);
for pktIdx = 1:numel(txPackets)
    if packetOk(pktIdx)
        continue;
    end
    startByte = floor((double(txPackets(pktIdx).startBit) - 1) / 8) + 1;
    endByte = ceil(double(txPackets(pktIdx).endBit) / 8);
    startBlk = floor((startByte - 1) / bytesPerBlock) + 1;
    endBlk = floor((endByte - 1) / bytesPerBlock) + 1;
    startBlk = max(1, min(totalBlocks, startBlk));
    endBlk = max(1, min(totalBlocks, endBlk));

    for blk = startBlk:endBlk
        cc = floor((blk - 1) / nBlocksPerCh) + 1;
        local = mod(blk - 1, nBlocksPerCh) + 1;
        br = floor((local - 1) / nBc) + 1;
        bc = mod(local - 1, nBc) + 1;
        maskBlocks(br, bc, cc) = true;
    end
end

if ch == 1
    mask = false(rows, cols);
else
    mask = false(rows, cols, ch);
end

for cc = 1:ch
    for br = 1:nBr
        rIdx = (br-1)*B + (1:B);
        rIdx = rIdx(rIdx <= rows);
        for bc = 1:nBc
            if ~maskBlocks(br, bc, cc)
                continue;
            end
            cIdx = (bc-1)*B + (1:B);
            cIdx = cIdx(cIdx <= cols);
            if ch == 1
                mask(rIdx, cIdx) = true;
            else
                mask(rIdx, cIdx, cc) = true;
            end
        end
    end
end
end

