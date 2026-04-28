function [codecId, manifestBytes, info] = build_payload_codec_descriptor_bytes(meta)
%BUILD_PAYLOAD_CODEC_DESCRIPTOR_BYTES Serialize payload codec metadata into session control.

codec = "raw";
if isfield(meta, "codec") && strlength(string(meta.codec)) > 0
    codec = lower(string(meta.codec));
end

codecMeta = struct();
if isfield(meta, "codecMeta") && isstruct(meta.codecMeta)
    codecMeta = meta.codecMeta;
end

switch codec
    case "raw"
        codecId = uint8(0);
        manifestBytes = uint8([]);

    case "dct"
        codecId = uint8(1);
        manifestBytes = local_build_dct_manifest_local(codecMeta);

    case "toolbox_image"
        codecId = uint8(2);
        manifestBytes = local_build_toolbox_manifest_local(codecMeta);

    case "tile_jp2"
        codecId = uint8(3);
        if isfield(codecMeta, "manifestBytes") && ~isempty(codecMeta.manifestBytes)
            manifestBytes = uint8(codecMeta.manifestBytes(:));
        else
            required = ["tileRows" "tileCols" "tileLengths"];
            for idx = 1:numel(required)
                if ~isfield(codecMeta, required(idx))
                    error("build_payload_codec_descriptor_bytes:MissingTileField", ...
                        "tile_jp2 codecMeta missing field %s.", required(idx));
                end
            end
            manifestBytes = tile_jp2_build_manifest_bytes( ...
                meta.rows, meta.cols, meta.channels, codecMeta, codecMeta.tileLengths);
        end

    otherwise
        error("build_payload_codec_descriptor_bytes:UnsupportedCodec", ...
            "Unsupported payload codec '%s'.", codec);
end

info = struct( ...
    "codec", codec, ...
    "codecId", codecId, ...
    "manifestBytes", uint8(manifestBytes(:)), ...
    "manifestLengthBytes", uint16(numel(manifestBytes)));
end

function manifestBytes = local_build_dct_manifest_local(codecMeta)
required = ["blockSize" "keepRows" "keepCols" "quantStep"];
for idx = 1:numel(required)
    if ~isfield(codecMeta, required(idx))
        error("build_payload_codec_descriptor_bytes:MissingDctField", ...
            "DCT codecMeta missing field %s.", required(idx));
    end
end

manifestBytes = [ ...
    uint8(round(double(codecMeta.blockSize))); ...
    uint8(round(double(codecMeta.keepRows))); ...
    uint8(round(double(codecMeta.keepCols))); ...
    reshape(typecast(single(double(codecMeta.quantStep)), "uint8"), [], 1)];
end

function manifestBytes = local_build_toolbox_manifest_local(codecMeta)
required = ["format" "mode" "compressionRatio" "quality"];
for idx = 1:numel(required)
    if ~isfield(codecMeta, required(idx))
        error("build_payload_codec_descriptor_bytes:MissingToolboxField", ...
            "toolbox_image codecMeta missing field %s.", required(idx));
    end
end

formatId = local_toolbox_format_id_local(codecMeta.format);
modeId = local_toolbox_mode_id_local(codecMeta.mode);
manifestBytes = [ ...
    uint8(formatId); ...
    uint8(modeId); ...
    reshape(typecast(single(double(codecMeta.compressionRatio)), "uint8"), [], 1); ...
    uint8(round(double(codecMeta.quality)))];
end

function formatId = local_toolbox_format_id_local(format)
format = lower(string(format));
switch format
    case "jp2"
        formatId = 0;
    case "jpg"
        formatId = 1;
    case "png"
        formatId = 2;
    otherwise
        error("Unsupported toolbox image format '%s'.", format);
end
end

function modeId = local_toolbox_mode_id_local(mode)
mode = lower(string(mode));
switch mode
    case "lossy"
        modeId = 0;
    case "lossless"
        modeId = 1;
    otherwise
        error("Unsupported toolbox image mode '%s'.", mode);
end
end
