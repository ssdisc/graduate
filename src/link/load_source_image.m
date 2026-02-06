function img = load_source_image(s)
%LOAD_SOURCE_IMAGE  加载并预处理源图像，读取默认图像或自定义图像路径，设置灰度图或彩色图像，调整图像大小。

if isfield(s, "useBuiltinImage") && s.useBuiltinImage
    img = imread("cameraman.tif");
else
    if strlength(string(s.imagePath)) == 0
        error("source.imagePath为空而useBuiltinImage=false。");
    end
    img = imread(s.imagePath);
end

if isfield(s, "grayscale") && s.grayscale && size(img, 3) > 1
    img = rgb2gray(img);
end
img = im2uint8(img);

if isfield(s, "resizeTo") && ~isempty(s.resizeTo)
    img = imresize(img, s.resizeTo);
end
end

