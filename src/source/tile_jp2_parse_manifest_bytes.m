function codecMeta = tile_jp2_parse_manifest_bytes(manifestBytes, metaBase)
%TILE_JP2_PARSE_MANIFEST_BYTES Parse the tile manifest recovered from session control.

if nargin < 2
    metaBase = struct();
end

manifestBytes = uint8(manifestBytes(:));
if numel(manifestBytes) < 28
    error("tile_jp2_parse_manifest_bytes:ShortManifest", ...
        "Tile JP2 manifest is shorter than the fixed header.");
end

magic = char(manifestBytes(1:4).');
if ~strcmp(magic, 'TJP2')
    error("tile_jp2_parse_manifest_bytes:BadMagic", "Tile JP2 manifest magic mismatch.");
end

version = double(manifestBytes(5));
if version ~= 1
    error("tile_jp2_parse_manifest_bytes:UnsupportedVersion", ...
        "Unsupported Tile JP2 manifest version %d.", version);
end

flags = uint8(manifestBytes(6));
channels = uint8(manifestBytes(7));
rows = local_unpack_uint16_local(manifestBytes(9:10));
cols = local_unpack_uint16_local(manifestBytes(11:12));
tileRows = local_unpack_uint16_local(manifestBytes(13:14));
tileCols = local_unpack_uint16_local(manifestBytes(15:16));
nTileRows = local_unpack_uint16_local(manifestBytes(17:18));
nTileCols = local_unpack_uint16_local(manifestBytes(19:20));
tileCount = local_unpack_uint16_local(manifestBytes(21:22));
compressionRatioTimes10 = local_unpack_uint16_local(manifestBytes(23:24));
manifestLen = local_unpack_uint32_local(manifestBytes(25:28));

expectedTiles = double(nTileRows) * double(nTileCols);
if double(tileCount) ~= expectedTiles
    error("tile_jp2_parse_manifest_bytes:TileCountMismatch", ...
        "Manifest tile count does not match tile grid.");
end
if double(manifestLen) ~= 28 + 4 * expectedTiles
    error("tile_jp2_parse_manifest_bytes:ManifestLengthMismatch", ...
        "Manifest length does not match tile count.");
end
if numel(manifestBytes) ~= double(manifestLen)
    error("tile_jp2_parse_manifest_bytes:ManifestSizeMismatch", ...
        "Manifest byte count mismatch.");
end

tileLengths = local_unpack_uint32_local(manifestBytes(29:end));
payloadBytes = uint32(sum(double(tileLengths)));
mode = "lossy";
if bitand(flags, uint8(1)) ~= 0
    mode = "lossless";
end
interleaveMode = "none";
if bitand(flags, uint8(2)) ~= 0
    interleaveMode = "polyphase";
end

if ~isempty(fieldnames(metaBase))
    local_validate_against_base_local(metaBase, rows, cols, channels);
end

codecMeta = struct( ...
    "codec", "tile_jp2", ...
    "containerVersion", uint8(version), ...
    "rows", rows, ...
    "cols", cols, ...
    "channels", channels, ...
    "tileRows", tileRows, ...
    "tileCols", tileCols, ...
    "nTileRows", nTileRows, ...
    "nTileCols", nTileCols, ...
    "tileLengths", tileLengths, ...
    "mode", mode, ...
    "interleaveMode", interleaveMode, ...
    "compressionRatio", double(compressionRatioTimes10) / 10, ...
    "manifestBytes", manifestBytes, ...
    "payloadBytes", payloadBytes);
end

function local_validate_against_base_local(metaBase, rows, cols, channels)
required = ["rows" "cols" "channels"];
for idx = 1:numel(required)
    if ~isfield(metaBase, required(idx))
        error("tile_jp2_parse_manifest_bytes:MissingBaseField", ...
            "metaBase is missing field %s.", required(idx));
    end
end
if double(metaBase.rows) ~= double(rows) || ...
        double(metaBase.cols) ~= double(cols) || ...
        double(metaBase.channels) ~= double(channels)
    error("tile_jp2_parse_manifest_bytes:BaseMismatch", ...
        "Tile JP2 manifest does not match session image dimensions.");
end
end

function values = local_unpack_uint16_local(bytes)
values = typecast(uint8(bytes(:).'), "uint16");
values = values(:);
end

function values = local_unpack_uint32_local(bytes)
values = typecast(uint8(bytes(:).'), "uint32");
values = values(:);
end
