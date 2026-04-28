function ok = rx_session_meta_compatible(metaA, metaB)
%RX_SESSION_META_COMPATIBLE Check whether two recovered session metas describe the same image session.

fields = ["rows" "cols" "channels" "bitsPerPixel" ...
    "totalPayloadBytes" "totalDataPackets" "totalPackets" ...
    "rsDataPacketsPerBlock" "rsParityPacketsPerBlock"];
ok = true;
for idx = 1:numel(fields)
    fieldName = fields(idx);
    if ~isfield(metaA, fieldName) || ~isfield(metaB, fieldName)
        ok = false;
        return;
    end
    ok = ok && double(metaA.(fieldName)) == double(metaB.(fieldName));
end

codecA = local_codec_local(metaA);
codecB = local_codec_local(metaB);
ok = ok && codecA == codecB;
if ~ok
    return;
end
ok = local_codec_meta_compatible_local(metaA, metaB, codecA);
end

function codec = local_codec_local(meta)
codec = "raw";
if isfield(meta, "codec") && strlength(string(meta.codec)) > 0
    codec = lower(string(meta.codec));
end
end

function ok = local_codec_meta_compatible_local(metaA, metaB, codec)
ok = true;
switch codec
    case "tile_jp2"
        ok = local_compare_codec_field_local(metaA, metaB, "tileRows");
        ok = ok && local_compare_codec_field_local(metaA, metaB, "tileCols");
        ok = ok && local_compare_codec_field_local(metaA, metaB, "nTileRows");
        ok = ok && local_compare_codec_field_local(metaA, metaB, "nTileCols");
        ok = ok && local_compare_codec_vector_local(metaA, metaB, "tileLengths");
    case "toolbox_image"
        ok = local_compare_codec_field_local(metaA, metaB, "format");
        ok = ok && local_compare_codec_field_local(metaA, metaB, "mode");
    case "dct"
        ok = local_compare_codec_field_local(metaA, metaB, "blockSize");
        ok = ok && local_compare_codec_field_local(metaA, metaB, "keepRows");
        ok = ok && local_compare_codec_field_local(metaA, metaB, "keepCols");
        ok = ok && local_compare_codec_field_local(metaA, metaB, "quantStep");
    otherwise
        ok = true;
end
end

function ok = local_compare_codec_field_local(metaA, metaB, fieldName)
codecMetaA = local_codec_meta_local(metaA);
codecMetaB = local_codec_meta_local(metaB);
if ~isfield(codecMetaA, fieldName) || ~isfield(codecMetaB, fieldName)
    ok = false;
    return;
end
valueA = codecMetaA.(fieldName);
valueB = codecMetaB.(fieldName);
if isnumeric(valueA) || islogical(valueA)
    ok = isequal(double(valueA), double(valueB));
else
    ok = string(valueA) == string(valueB);
end
end

function ok = local_compare_codec_vector_local(metaA, metaB, fieldName)
codecMetaA = local_codec_meta_local(metaA);
codecMetaB = local_codec_meta_local(metaB);
if ~isfield(codecMetaA, fieldName) || ~isfield(codecMetaB, fieldName)
    ok = false;
    return;
end
ok = isequal(double(codecMetaA.(fieldName)(:)), double(codecMetaB.(fieldName)(:)));
end

function codecMeta = local_codec_meta_local(meta)
codecMeta = struct();
if isfield(meta, "codecMeta") && isstruct(meta.codecMeta)
    codecMeta = meta.codecMeta;
end
end
