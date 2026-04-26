function img = toolbox_image_decode_bytes(bytes, meta, cfg)
%TOOLBOX_IMAGE_DECODE_BYTES Decode bytes produced by MATLAB image codecs.

rows = double(meta.rows);
cols = double(meta.cols);
ch = double(meta.channels);
format = lower(string(cfg.format));
ext = local_extension_local(format);
tmpPath = [tempname, ext];
cleanupObj = onCleanup(@() local_delete_if_exists_local(tmpPath));

try
    fid = fopen(tmpPath, "wb");
    if fid < 0
        error("toolbox_image_decode_bytes:WriteFailed", ...
            "Failed to create temporary encoded image file: %s", tmpPath);
    end
    closeObj = onCleanup(@() fclose(fid));
    fwrite(fid, uint8(bytes(:)), "uint8");
    clear closeObj;

    decoded = imread(tmpPath);
    decoded = im2uint8(decoded);
    img = local_match_meta_local(decoded, rows, cols, ch);
catch
    img = zeros(rows, cols, max(ch, 1), "uint8");
end

if ch == 1 && ndims(img) == 3
    img = img(:, :, 1);
end
clear cleanupObj;
end

function img = local_match_meta_local(decoded, rows, cols, ch)
if ch == 1 && ndims(decoded) == 3
    decoded = rgb2gray(decoded);
elseif ch == 3 && ndims(decoded) == 2
    decoded = repmat(decoded, 1, 1, 3);
end

if size(decoded, 1) ~= rows || size(decoded, 2) ~= cols
    decoded = imresize(decoded, [rows, cols]);
end

if ch == 1
    img = uint8(decoded(:, :, 1));
else
    if size(decoded, 3) < ch
        decoded = repmat(decoded(:, :, 1), 1, 1, ch);
    end
    img = uint8(decoded(:, :, 1:ch));
end
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
        error("toolbox_image_decode_bytes:UnsupportedFormat", ...
            "Unsupported toolbox image format '%s'.", format);
end
end

function local_delete_if_exists_local(pathName)
pathName = char(pathName);
if exist(pathName, "file") == 2
    delete(pathName);
end
end
