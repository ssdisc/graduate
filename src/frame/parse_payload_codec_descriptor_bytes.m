function [codec, codecMeta] = parse_payload_codec_descriptor_bytes(codecId, manifestBytes, metaBase)
%PARSE_PAYLOAD_CODEC_DESCRIPTOR_BYTES Parse payload codec metadata from session control.

if nargin < 3
    metaBase = struct();
end

codecId = double(codecId);
manifestBytes = uint8(manifestBytes(:));

switch codecId
    case 0
        codec = "raw";
        codecMeta = struct();

    case 1
        codec = "dct";
        codecMeta = local_parse_dct_manifest_local(manifestBytes);

    case 2
        codec = "toolbox_image";
        codecMeta = local_parse_toolbox_manifest_local(manifestBytes);

    case 3
        codec = "tile_jp2";
        codecMeta = tile_jp2_parse_manifest_bytes(manifestBytes, metaBase);

    otherwise
        error("parse_payload_codec_descriptor_bytes:UnsupportedCodecId", ...
            "Unsupported payload codec id %d.", codecId);
end
end

function codecMeta = local_parse_dct_manifest_local(manifestBytes)
if numel(manifestBytes) ~= 7
    error("parse_payload_codec_descriptor_bytes:BadDctManifest", ...
        "DCT manifest must be 7 bytes, got %d.", numel(manifestBytes));
end

codecMeta = struct( ...
    "blockSize", double(manifestBytes(1)), ...
    "keepRows", double(manifestBytes(2)), ...
    "keepCols", double(manifestBytes(3)), ...
    "quantStep", double(typecast(uint8(manifestBytes(4:7).'), "single")));
end

function codecMeta = local_parse_toolbox_manifest_local(manifestBytes)
if numel(manifestBytes) ~= 7
    error("parse_payload_codec_descriptor_bytes:BadToolboxManifest", ...
        "toolbox_image manifest must be 7 bytes, got %d.", numel(manifestBytes));
end

codecMeta = struct( ...
    "format", local_toolbox_format_local(manifestBytes(1)), ...
    "mode", local_toolbox_mode_local(manifestBytes(2)), ...
    "compressionRatio", double(typecast(uint8(manifestBytes(3:6).'), "single")), ...
    "quality", double(manifestBytes(7)));
end

function format = local_toolbox_format_local(formatId)
switch double(formatId)
    case 0
        format = "jp2";
    case 1
        format = "jpg";
    case 2
        format = "png";
    otherwise
        error("Unsupported toolbox image format id %d.", double(formatId));
end
end

function mode = local_toolbox_mode_local(modeId)
switch double(modeId)
    case 0
        mode = "lossy";
    case 1
        mode = "lossless";
    otherwise
        error("Unsupported toolbox image mode id %d.", double(modeId));
end
end
