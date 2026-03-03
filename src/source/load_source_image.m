function img = load_source_image(s)
%LOAD_SOURCE_IMAGE  加载并预处理源图像，读取默认图像或自定义图像路径，设置灰度图或彩色图像，调整图像大小。
%
% 输入:
%   s - 图像源配置结构体
%       .useBuiltinImage - 是否使用内置图像
%       .imagePath       - 外部图像路径（useBuiltinImage=false时）
%       .grayscale       - 是否转灰度
%       .resizeTo        - 重采样尺寸[rows cols]，空表示不缩放
%
% 输出:
%   img - 预处理后的uint8图像

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

