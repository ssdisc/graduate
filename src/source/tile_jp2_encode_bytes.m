function [bytes, codecMeta] = tile_jp2_encode_bytes(img, cfg)
%TILE_JP2_ENCODE_BYTES Encode an image as independently decodable JP2 tiles.

img = uint8(img);
rows = size(img, 1);
cols = size(img, 2);
ch = size(img, 3);

tileRows = round(double(cfg.tileRows));
tileCols = round(double(cfg.tileCols));
nTileRows = ceil(rows / tileRows);
nTileCols = ceil(cols / tileCols);
nTiles = nTileRows * nTileCols;
interleaveMode = local_resolve_interleave_mode_local(cfg);

tileBytes = cell(nTiles, 1);
tileLengths = zeros(nTiles, 1, "uint32");
tileIdx = 1;
for tr = 1:nTileRows
    for tc = 1:nTileCols
        tileImg = local_extract_tile_image_local( ...
            img, tr, tc, rows, cols, tileRows, tileCols, nTileRows, nTileCols, interleaveMode);
        tilePayload = local_encode_single_tile_local(tileImg, cfg);
        tileBytes{tileIdx} = tilePayload;
        tileLengths(tileIdx) = uint32(numel(tilePayload));
        tileIdx = tileIdx + 1;
    end
end

manifestBytes = tile_jp2_build_manifest_bytes(rows, cols, ch, cfg, tileLengths);
bytes = zeros(0, 1, "uint8");
for tileIdx = 1:nTiles
    bytes = [bytes; tileBytes{tileIdx}]; %#ok<AGROW>
end

codecMeta = struct( ...
    "codec", "tile_jp2", ...
    "containerVersion", uint8(1), ...
    "rows", uint16(rows), ...
    "cols", uint16(cols), ...
    "channels", uint8(ch), ...
    "tileRows", uint16(tileRows), ...
    "tileCols", uint16(tileCols), ...
    "nTileRows", uint16(nTileRows), ...
    "nTileCols", uint16(nTileCols), ...
    "tileLengths", tileLengths, ...
    "interleaveMode", interleaveMode, ...
    "manifestBytes", manifestBytes, ...
    "payloadBytes", uint32(numel(bytes)));
end

function interleaveMode = local_resolve_interleave_mode_local(cfg)
if ~isfield(cfg, "interleaveMode")
    error("tile_jp2_encode_bytes:MissingInterleaveMode", ...
        "cfg.interleaveMode is required.");
end
interleaveMode = lower(string(cfg.interleaveMode));
if ~any(interleaveMode == ["none" "polyphase"])
    error("tile_jp2_encode_bytes:InvalidInterleaveMode", ...
        "cfg.interleaveMode must be 'none' or 'polyphase'.");
end
end

function tileImg = local_extract_tile_image_local( ...
        img, tr, tc, rows, cols, tileRows, tileCols, nTileRows, nTileCols, interleaveMode)
if interleaveMode == "polyphase"
    rowIdx = tr:nTileRows:rows;
    colIdx = tc:nTileCols:cols;
    tileImg = img(rowIdx, colIdx, :);
else
    r0 = (tr - 1) * tileRows + 1;
    r1 = min(tr * tileRows, rows);
    c0 = (tc - 1) * tileCols + 1;
    c1 = min(tc * tileCols, cols);
    tileImg = img(r0:r1, c0:c1, :);
end
if isempty(tileImg)
    error("tile_jp2_encode_bytes:EmptyTile", ...
        "Tile (%d, %d) is empty under interleave mode '%s'.", ...
        tr, tc, char(interleaveMode));
end
end

function bytes = local_encode_single_tile_local(tileImg, cfg)
tmpPath = [tempname, '.jp2'];
cleanupObj = onCleanup(@() local_delete_if_exists_local(tmpPath));

if string(cfg.mode) == "lossless"
    imwrite(tileImg, tmpPath, 'jp2', 'Mode', 'lossless');
else
    imwrite(tileImg, tmpPath, 'jp2', 'Mode', 'lossy', ...
        'CompressionRatio', double(cfg.compressionRatio));
end

fid = fopen(tmpPath, "rb");
if fid < 0
    error("tile_jp2_encode_bytes:ReadFailed", ...
        "Failed to read encoded tile: %s", tmpPath);
end
closeObj = onCleanup(@() fclose(fid));
bytes = fread(fid, Inf, "*uint8");
clear closeObj cleanupObj;
end

function local_delete_if_exists_local(pathName)
pathName = char(pathName);
if exist(pathName, "file") == 2
    delete(pathName);
end
end
