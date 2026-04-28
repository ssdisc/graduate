function [codec, cfg] = resolve_payload_codec(payload)
%RESOLVE_PAYLOAD_CODEC  Parse and normalize payload codec configuration.
%
% 输出:
%   codec - "raw" | "dct" | "toolbox_image" | "tile_jp2"
%   cfg   - 归一化后的 codec 配置结构体

codec = "raw";
if isfield(payload, "codec") && strlength(string(payload.codec)) > 0
    codec = lower(string(payload.codec));
end

switch codec
    case {"raw", "none"}
        codec = "raw";
    case {"dct", "dct8", "dct_lossy"}
        codec = "dct";
    case {"tile_jp2", "tiled_jp2", "jp2_tiles"}
        codec = "tile_jp2";
    case {"toolbox_image", "jpeg2000", "jp2", "jpeg", "jpg", "png"}
        codec = "toolbox_image";
    otherwise
        error("未知的payload.codec: %s", codec);
end

cfg = struct();
cfg.dct = local_resolve_dct_cfg_local(payload);
cfg.tileJp2 = local_resolve_tile_jp2_cfg_local(payload);
cfg.toolboxImage = local_resolve_toolbox_image_cfg_local(payload, codec);
end

function dctCfg = local_resolve_dct_cfg_local(payload)
dctCfg = struct();
if isfield(payload, "dct") && isstruct(payload.dct)
    dctCfg = payload.dct;
end
if ~isfield(dctCfg, "blockSize"); dctCfg.blockSize = 8; end
if ~isfield(dctCfg, "keepRows"); dctCfg.keepRows = 4; end
if ~isfield(dctCfg, "keepCols"); dctCfg.keepCols = 4; end
if ~isfield(dctCfg, "quantStep"); dctCfg.quantStep = 16; end

dctCfg.blockSize = max(2, round(double(dctCfg.blockSize)));
dctCfg.keepRows = max(1, round(double(dctCfg.keepRows)));
dctCfg.keepCols = max(1, round(double(dctCfg.keepCols)));
dctCfg.quantStep = max(eps, double(dctCfg.quantStep));
dctCfg.keepRows = min(dctCfg.keepRows, dctCfg.blockSize);
dctCfg.keepCols = min(dctCfg.keepCols, dctCfg.blockSize);
end

function tileCfg = local_resolve_tile_jp2_cfg_local(payload)
tileCfg = struct();
if isfield(payload, "tileJp2") && isstruct(payload.tileJp2)
    tileCfg = payload.tileJp2;
end

if ~isfield(tileCfg, "tileRows"); tileCfg.tileRows = 128; end
if ~isfield(tileCfg, "tileCols"); tileCfg.tileCols = 128; end
if ~isfield(tileCfg, "mode"); tileCfg.mode = "lossy"; end
if ~isfield(tileCfg, "compressionRatio"); tileCfg.compressionRatio = 8; end
if ~isfield(tileCfg, "quality"); tileCfg.quality = 75; end
if ~isfield(tileCfg, "decodeFailureFill"); tileCfg.decodeFailureFill = "zeros"; end

tileCfg.tileRows = round(double(tileCfg.tileRows));
tileCfg.tileCols = round(double(tileCfg.tileCols));
if tileCfg.tileRows < 8 || tileCfg.tileCols < 8
    error("payload.tileJp2.tileRows 和 tileCols 必须 >= 8。");
end

tileCfg.mode = lower(string(tileCfg.mode));
if ~any(tileCfg.mode == ["lossy" "lossless"])
    error("payload.tileJp2.mode 必须是 'lossy' 或 'lossless'。");
end

tileCfg.compressionRatio = max(1, double(tileCfg.compressionRatio));
tileCfg.quality = max(0, min(100, round(double(tileCfg.quality))));
tileCfg.decodeFailureFill = lower(string(tileCfg.decodeFailureFill));
if ~any(tileCfg.decodeFailureFill == ["zeros" "gray"])
    error("payload.tileJp2.decodeFailureFill 必须是 'zeros' 或 'gray'。");
end
end

function toolboxCfg = local_resolve_toolbox_image_cfg_local(payload, codec)
toolboxCfg = struct();
if isfield(payload, "toolboxImage") && isstruct(payload.toolboxImage)
    toolboxCfg = payload.toolboxImage;
end
if ~isfield(toolboxCfg, "format")
    toolboxCfg.format = "jp2";
end

codecText = "";
if isfield(payload, "codec")
    codecText = lower(string(payload.codec));
end
if any(codecText == ["jpeg2000" "jp2"])
    toolboxCfg.format = "jp2";
elseif any(codecText == ["jpeg" "jpg"])
    toolboxCfg.format = "jpg";
elseif codecText == "png"
    toolboxCfg.format = "png";
end

toolboxCfg.format = lower(string(toolboxCfg.format));
switch toolboxCfg.format
    case {"jp2", "j2k", "jpeg2000"}
        toolboxCfg.format = "jp2";
    case {"jpg", "jpeg"}
        toolboxCfg.format = "jpg";
    case "png"
        toolboxCfg.format = "png";
    otherwise
        if codec == "toolbox_image"
            error("payload.toolboxImage.format 必须是 'jp2'、'jpg' 或 'png'。");
        end
end

if ~isfield(toolboxCfg, "compressionRatio"); toolboxCfg.compressionRatio = 8; end
if ~isfield(toolboxCfg, "mode"); toolboxCfg.mode = "lossy"; end
if ~isfield(toolboxCfg, "quality"); toolboxCfg.quality = 75; end

toolboxCfg.compressionRatio = max(1, double(toolboxCfg.compressionRatio));
toolboxCfg.mode = lower(string(toolboxCfg.mode));
if ~any(toolboxCfg.mode == ["lossy" "lossless"])
    error("payload.toolboxImage.mode 必须是 'lossy' 或 'lossless'。");
end
toolboxCfg.quality = max(0, min(100, round(double(toolboxCfg.quality))));
end

