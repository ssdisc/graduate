function [codec, cfg] = resolve_payload_codec(payload)
%RESOLVE_PAYLOAD_CODEC  Parse and normalize payload codec configuration.
%
% 输出:
%   codec - "raw" | "dct" | "toolbox_image"
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
    case {"toolbox_image", "jpeg2000", "jp2", "jpeg", "jpg", "png"}
        codec = "toolbox_image";
    otherwise
        error("未知的payload.codec: %s", codec);
end

cfg = struct();
cfg.dct = local_resolve_dct_cfg_local(payload);
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

