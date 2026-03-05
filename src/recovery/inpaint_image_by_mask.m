function imgOut = inpaint_image_by_mask(imgIn, mask, mode)
img = double(imgIn);
if ndims(img) == 2
    img = reshape(img, size(img, 1), size(img, 2), 1);
end
if ndims(mask) == 2
    mask = reshape(mask, size(mask, 1), size(mask, 2), 1);
end

ch = size(img, 3);
for cc = 1:ch
    img(:, :, cc) = inpaint_plane(img(:, :, cc), logical(mask(:, :, min(cc, size(mask, 3)))), mode);
end

img = uint8(min(max(round(img), 0), 255));
if size(imgIn, 3) == 1
    imgOut = img(:, :, 1);
else
    imgOut = img;
end
end

