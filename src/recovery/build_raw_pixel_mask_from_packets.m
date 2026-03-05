function mask = build_raw_pixel_mask_from_packets(packetOk, txPackets, meta)
rows = double(meta.rows);
cols = double(meta.cols);
ch = double(meta.channels);
nElems = rows * cols * ch;

maskLinear = false(nElems, 1);
for pktIdx = 1:numel(txPackets)
    if packetOk(pktIdx)
        continue;
    end
    startByte = floor((double(txPackets(pktIdx).startBit) - 1) / 8) + 1;
    endByte = ceil(double(txPackets(pktIdx).endBit) / 8);
    startByte = max(1, min(nElems, startByte));
    endByte = max(1, min(nElems, endByte));
    if endByte >= startByte
        maskLinear(startByte:endByte) = true;
    end
end

if ch == 1
    mask = reshape(maskLinear, rows, cols);
else
    mask = reshape(maskLinear, rows, cols, ch);
end
end

