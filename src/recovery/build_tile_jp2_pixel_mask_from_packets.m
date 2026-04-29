function mask = build_tile_jp2_pixel_mask_from_packets(packetOk, txPackets, meta, ~)
rows = double(meta.rows);
cols = double(meta.cols);
ch = double(meta.channels);
if ~(rows >= 1 && cols >= 1 && (ch == 1 || ch == 3))
    error("build_tile_jp2_pixel_mask_from_packets:InvalidMetaSize", ...
        "meta.rows/meta.cols/meta.channels are invalid.");
end

manifest = local_resolve_tile_manifest_local(meta);
nTileRows = double(manifest.nTileRows);
nTileCols = double(manifest.nTileCols);
tileCount = nTileRows * nTileCols;
if numel(packetOk) ~= numel(txPackets)
    error("build_tile_jp2_pixel_mask_from_packets:PacketLengthMismatch", ...
        "packetOk length (%d) must equal txPackets length (%d).", ...
        numel(packetOk), numel(txPackets));
end

interleaveMode = lower(string(manifest.interleaveMode));
if ~any(interleaveMode == ["none" "polyphase"])
    error("build_tile_jp2_pixel_mask_from_packets:InvalidInterleaveMode", ...
        "interleaveMode must be 'none' or 'polyphase'.");
end

tileLostBytes = zeros(tileCount, 1);
tileTotalBytes = nan(tileCount, 1);
for pktIdx = 1:numel(txPackets)
    pkt = txPackets(pktIdx);
    if ~(isfield(pkt, "tileIndex") && isfinite(double(pkt.tileIndex)))
        error("build_tile_jp2_pixel_mask_from_packets:MissingTileIndex", ...
            "txPackets(%d).tileIndex is required for tile_jp2 concealment.", pktIdx);
    end
    tileIdx = double(pkt.tileIndex);
    if ~(isscalar(tileIdx) && abs(tileIdx - round(tileIdx)) <= 1e-12 ...
            && tileIdx >= 1 && tileIdx <= tileCount)
        error("build_tile_jp2_pixel_mask_from_packets:InvalidTileIndex", ...
            "txPackets(%d).tileIndex=%g is out of range [1, %d].", pktIdx, tileIdx, tileCount);
    end
    tileIdx = round(tileIdx);

    if ~(isfield(pkt, "segmentBytes") && isfinite(double(pkt.segmentBytes)))
        error("build_tile_jp2_pixel_mask_from_packets:MissingSegmentBytes", ...
            "txPackets(%d).segmentBytes is required.", pktIdx);
    end
    segBytes = double(pkt.segmentBytes);
    if ~(isscalar(segBytes) && segBytes >= 0)
        error("build_tile_jp2_pixel_mask_from_packets:InvalidSegmentBytes", ...
            "txPackets(%d).segmentBytes must be nonnegative.", pktIdx);
    end
    if ~(isfield(pkt, "tileBytesTotal") && isfinite(double(pkt.tileBytesTotal)))
        error("build_tile_jp2_pixel_mask_from_packets:MissingTileBytesTotal", ...
            "txPackets(%d).tileBytesTotal is required.", pktIdx);
    end
    totalBytes = double(pkt.tileBytesTotal);
    if ~(isscalar(totalBytes) && totalBytes > 0)
        error("build_tile_jp2_pixel_mask_from_packets:InvalidTileBytesTotal", ...
            "txPackets(%d).tileBytesTotal must be positive.", pktIdx);
    end
    if isnan(tileTotalBytes(tileIdx))
        tileTotalBytes(tileIdx) = totalBytes;
    elseif abs(tileTotalBytes(tileIdx) - totalBytes) > 1e-9
        error("build_tile_jp2_pixel_mask_from_packets:TileBytesTotalMismatch", ...
            "Inconsistent tileBytesTotal for tileIndex=%d.", tileIdx);
    end

    if ~packetOk(pktIdx)
        tileLostBytes(tileIdx) = tileLostBytes(tileIdx) + segBytes;
    end
end

if ch == 1
    mask = false(rows, cols);
else
    mask = false(rows, cols, ch);
end

tileRows = double(manifest.tileRows);
tileCols = double(manifest.tileCols);
for tileIdx = 1:tileCount
    if tileLostBytes(tileIdx) <= 0
        continue;
    end
    if isnan(tileTotalBytes(tileIdx)) || tileTotalBytes(tileIdx) <= 0
        error("build_tile_jp2_pixel_mask_from_packets:MissingTileTotalBytes", ...
            "tileBytesTotal is missing for tileIndex=%d.", tileIdx);
    end
    lossRatio = min(1, max(0, tileLostBytes(tileIdx) / tileTotalBytes(tileIdx)));

    tr = floor((double(tileIdx) - 1) / nTileCols) + 1;
    tc = mod(double(tileIdx) - 1, nTileCols) + 1;
    if interleaveMode == "polyphase"
        rowIdx = tr:nTileRows:rows;
        colIdx = tc:nTileCols:cols;
    else
        r0 = (tr - 1) * tileRows + 1;
        r1 = min(tr * tileRows, rows);
        c0 = (tc - 1) * tileCols + 1;
        c1 = min(tc * tileCols, cols);
        rowIdx = r0:r1;
        colIdx = c0:c1;
    end

    outRows = numel(rowIdx);
    outCols = numel(colIdx);
    if lossRatio >= 1 - 1e-12
        tileMask = true(outRows, outCols, ch);
    else
        tileMask = local_partial_tile_mask_local(outRows, outCols, ch, lossRatio, tileIdx);
    end

    if ch == 1
        mask(rowIdx, colIdx) = logical(tileMask(:, :, 1));
    else
        mask(rowIdx, colIdx, :) = logical(tileMask);
    end
end
end

function tileMask = local_partial_tile_mask_local(outRows, outCols, ch, lossRatio, tileSeed)
nElems = outRows * outCols * ch;
nMissing = max(1, min(nElems, round(double(lossRatio) * nElems)));

idx = 1:nElems;
scores = mod(1103515245 .* idx + 12345 .* double(tileSeed), 2147483647);
scores = scores + 1e-9 .* idx;
[~, order] = sort(scores, "ascend");

linMask = false(nElems, 1);
linMask(order(1:nMissing)) = true;
tileMask = reshape(linMask, outRows, outCols, ch);
end

function manifest = local_resolve_tile_manifest_local(meta)
if ~(isfield(meta, "codecMeta") && isstruct(meta.codecMeta))
    error("build_tile_jp2_pixel_mask_from_packets:MissingCodecMeta", ...
        "meta.codecMeta is required for tile_jp2 concealment.");
end
codecMeta = meta.codecMeta;
if isfield(codecMeta, "manifestBytes") && ~isempty(codecMeta.manifestBytes)
    manifest = tile_jp2_parse_manifest_bytes(codecMeta.manifestBytes, meta);
    return;
end

required = ["tileRows" "tileCols" "nTileRows" "nTileCols" "tileLengths" "interleaveMode"];
for idx = 1:numel(required)
    fieldName = required(idx);
    if ~isfield(codecMeta, fieldName)
        error("build_tile_jp2_pixel_mask_from_packets:MissingCodecField", ...
            "meta.codecMeta.%s is required when manifestBytes is absent.", fieldName);
    end
end
manifest = struct( ...
    "tileRows", codecMeta.tileRows, ...
    "tileCols", codecMeta.tileCols, ...
    "nTileRows", codecMeta.nTileRows, ...
    "nTileCols", codecMeta.nTileCols, ...
    "tileLengths", codecMeta.tileLengths, ...
    "interleaveMode", string(codecMeta.interleaveMode));
end
