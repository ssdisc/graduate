function [bytes, codecMeta] = toolbox_image_encode_bytes(img, cfg)
%TOOLBOX_IMAGE_ENCODE_BYTES Encode an image with MATLAB's image codecs.

img = uint8(img);
format = lower(string(cfg.format));
ext = local_extension_local(format);
tmpPath = [tempname, ext];
cleanupObj = onCleanup(@() local_delete_if_exists_local(tmpPath));

switch format
    case "jp2"
        if cfg.mode == "lossless"
            imwrite(img, tmpPath, 'jp2', 'Mode', 'lossless');
        else
            imwrite(img, tmpPath, 'jp2', 'Mode', 'lossy', ...
                'CompressionRatio', double(cfg.compressionRatio));
        end
    case "jpg"
        imwrite(img, tmpPath, 'jpg', 'Quality', round(double(cfg.quality)));
    case "png"
        imwrite(img, tmpPath, 'png');
    otherwise
        error("toolbox_image_encode_bytes:UnsupportedFormat", ...
            "Unsupported toolbox image format '%s'.", format);
end

fid = fopen(tmpPath, "rb");
if fid < 0
    error("toolbox_image_encode_bytes:ReadFailed", ...
        "Failed to read encoded image file: %s", tmpPath);
end
closeObj = onCleanup(@() fclose(fid));
bytes = fread(fid, Inf, "*uint8");
clear closeObj;

codecMeta = struct( ...
    "codec", "toolbox_image", ...
    "format", format, ...
    "mode", string(cfg.mode), ...
    "compressionRatio", double(cfg.compressionRatio), ...
    "quality", double(cfg.quality), ...
    "payloadBytes", uint32(numel(bytes)));
clear cleanupObj;
end

function ext = local_extension_local(format)
switch format
    case "jp2"
        ext = '.jp2';
    case "jpg"
        ext = '.jpg';
    case "png"
        ext = '.png';
    otherwise
        error("toolbox_image_encode_bytes:UnsupportedFormat", ...
            "Unsupported toolbox image format '%s'.", format);
end
end

function local_delete_if_exists_local(pathName)
pathName = char(pathName);
if exist(pathName, "file") == 2
    delete(pathName);
end
end
