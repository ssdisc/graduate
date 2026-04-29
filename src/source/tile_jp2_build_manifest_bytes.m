function manifestBytes = tile_jp2_build_manifest_bytes(rows, cols, ch, cfg, tileLengths)
%TILE_JP2_BUILD_MANIFEST_BYTES Build the tile manifest carried by session control.

rows = round(double(rows));
cols = round(double(cols));
ch = round(double(ch));
tileRows = round(double(cfg.tileRows));
tileCols = round(double(cfg.tileCols));
tileLengths = uint32(tileLengths(:));

if rows < 1 || cols < 1
    error("tile_jp2_build_manifest_bytes:InvalidSize", "rows/cols must be positive.");
end
if ~(ch == 1 || ch == 3)
    error("tile_jp2_build_manifest_bytes:InvalidChannels", "channels must be 1 or 3.");
end
if tileRows < 8 || tileCols < 8
    error("tile_jp2_build_manifest_bytes:InvalidTileSize", "tileRows/tileCols must be >= 8.");
end

nTileRows = ceil(rows / tileRows);
nTileCols = ceil(cols / tileCols);
tileCount = nTileRows * nTileCols;
if numel(tileLengths) ~= tileCount
    error("tile_jp2_build_manifest_bytes:TileCountMismatch", ...
        "Expected %d tile lengths, got %d.", tileCount, numel(tileLengths));
end

flags = uint8(0);
if isfield(cfg, "mode") && string(cfg.mode) == "lossless"
    flags = bitor(flags, uint8(1));
end
if isfield(cfg, "interleaveMode") && lower(string(cfg.interleaveMode)) == "polyphase"
    flags = bitor(flags, uint8(2));
end

magic = uint8('TJP2').';
version = uint8(1);
reserved = uint8(0);
compressionRatioTimes10 = uint16(10);
if isfield(cfg, "compressionRatio")
    compressionRatioTimes10 = uint16(round(double(cfg.compressionRatio) * 10));
end
manifestLen = uint32(28 + 4 * double(tileCount));

manifestBytes = [ ...
    magic; ...
    version; ...
    flags; ...
    uint8(ch); ...
    reserved; ...
    local_pack_uint16_local(uint16(rows)); ...
    local_pack_uint16_local(uint16(cols)); ...
    local_pack_uint16_local(uint16(tileRows)); ...
    local_pack_uint16_local(uint16(tileCols)); ...
    local_pack_uint16_local(uint16(nTileRows)); ...
    local_pack_uint16_local(uint16(nTileCols)); ...
    local_pack_uint16_local(uint16(tileCount)); ...
    local_pack_uint16_local(compressionRatioTimes10); ...
    local_pack_uint32_local(manifestLen); ...
    local_pack_uint32_local(tileLengths)];
end

function bytes = local_pack_uint16_local(values)
bytes = reshape(typecast(uint16(values(:)), "uint8"), [], 1);
end

function bytes = local_pack_uint32_local(values)
bytes = reshape(typecast(uint32(values(:)), "uint8"), [], 1);
end
