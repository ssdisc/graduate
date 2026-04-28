function img = tile_jp2_decode_bytes(bytes, meta, cfg)
%TILE_JP2_DECODE_BYTES Decode independently encoded JP2 tiles from payload bytes.

bytes = uint8(bytes(:));
manifest = local_resolve_manifest_local(meta);

rows = double(meta.rows);
cols = double(meta.cols);
ch = double(meta.channels);
img = local_fill_image_local(rows, cols, ch, string(cfg.decodeFailureFill));

tileRows = double(manifest.tileRows);
tileCols = double(manifest.tileCols);
nTileRows = double(manifest.nTileRows);
nTileCols = double(manifest.nTileCols);
tileLengths = double(manifest.tileLengths(:));

cursor = 1;
tileIdx = 1;
for tr = 1:nTileRows
    r0 = (tr - 1) * tileRows + 1;
    r1 = min(tr * tileRows, rows);
    for tc = 1:nTileCols
        c0 = (tc - 1) * tileCols + 1;
        c1 = min(tc * tileCols, cols);
        tileLen = tileLengths(tileIdx);
        nextCursor = cursor + tileLen - 1;
        if tileLen > 0 && nextCursor <= numel(bytes)
            tileBytes = bytes(cursor:nextCursor);
            try
                tileImg = local_decode_single_tile_local(tileBytes, r1 - r0 + 1, c1 - c0 + 1, ch);
                if ch == 1
                    img(r0:r1, c0:c1, 1) = tileImg;
                else
                    img(r0:r1, c0:c1, :) = tileImg;
                end
            catch
            end
        end
        cursor = nextCursor + 1;
        tileIdx = tileIdx + 1;
    end
end

if ch == 1
    img = img(:, :, 1);
end
end

function manifest = local_resolve_manifest_local(meta)
if ~(isfield(meta, "codecMeta") && isstruct(meta.codecMeta))
    error("tile_jp2_decode_bytes:MissingCodecMeta", "Tile JP2 decode requires meta.codecMeta.");
end
codecMeta = meta.codecMeta;

if isfield(codecMeta, "manifestBytes") && ~isempty(codecMeta.manifestBytes)
    manifest = tile_jp2_parse_manifest_bytes(codecMeta.manifestBytes, meta);
    return;
end

requiredFields = ["tileRows" "tileCols" "nTileRows" "nTileCols" "tileLengths"];
for fieldName = requiredFields
    if ~isfield(codecMeta, fieldName)
        error("tile_jp2_decode_bytes:MissingManifest", ...
            "Tile JP2 decode requires codecMeta.manifestBytes or explicit tile fields.");
    end
end

manifest = struct( ...
    "rows", uint16(meta.rows), ...
    "cols", uint16(meta.cols), ...
    "channels", uint8(meta.channels), ...
    "tileRows", uint16(codecMeta.tileRows), ...
    "tileCols", uint16(codecMeta.tileCols), ...
    "nTileRows", uint16(codecMeta.nTileRows), ...
    "nTileCols", uint16(codecMeta.nTileCols), ...
    "tileLengths", uint32(codecMeta.tileLengths));
end

function tileImg = local_decode_single_tile_local(tileBytes, outRows, outCols, ch)
tmpPath = [tempname, '.jp2'];
cleanupObj = onCleanup(@() local_delete_if_exists_local(tmpPath));

fid = fopen(tmpPath, "wb");
if fid < 0
    error("tile_jp2_decode_bytes:WriteFailed", ...
        "Failed to create temporary tile file: %s", tmpPath);
end
closeObj = onCleanup(@() fclose(fid));
fwrite(fid, uint8(tileBytes), "uint8");
clear closeObj;

decoded = imread(tmpPath);
decoded = im2uint8(decoded);
tileImg = local_match_tile_shape_local(decoded, outRows, outCols, ch);
clear cleanupObj;
end

function tileImg = local_match_tile_shape_local(decoded, outRows, outCols, ch)
if ch == 1 && ndims(decoded) == 3
    decoded = rgb2gray(decoded);
elseif ch == 3 && ndims(decoded) == 2
    decoded = repmat(decoded, 1, 1, 3);
end

if size(decoded, 1) ~= outRows || size(decoded, 2) ~= outCols
    decoded = imresize(decoded, [outRows, outCols]);
end

if ch == 1
    tileImg = uint8(decoded(:, :, 1));
else
    if size(decoded, 3) < ch
        decoded = repmat(decoded(:, :, 1), 1, 1, ch);
    end
    tileImg = uint8(decoded(:, :, 1:ch));
end
end

function img = local_fill_image_local(rows, cols, ch, fillMode)
if fillMode == "gray"
    img = uint8(128 * ones(rows, cols, max(ch, 1), "double"));
else
    img = zeros(rows, cols, max(ch, 1), "uint8");
end
end

function local_delete_if_exists_local(pathName)
pathName = char(pathName);
if exist(pathName, "file") == 2
    delete(pathName);
end
end
