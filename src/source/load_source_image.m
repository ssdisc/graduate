function img = load_source_image(s)
%LOAD_SOURCE_IMAGE  加载并预处理源图像。
%
% 输入:
%   s - 图像源配置结构体
%       .useBuiltinImage - 是否使用内置图像
%       .imagePath       - 外部图像路径（useBuiltinImage=false时）
%       .grayscale       - 是否转灰度
%       .resizeTo        - 显式重采样尺寸 [rows cols]；非空则直接按此尺寸重采样，
%                          绕过 maxDimension
%       .maxDimension    - 等比例上限：当 max(rows,cols) > maxDimension 时按比例
%                          缩小，保持长宽比。resizeTo 非空时忽略。
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
    return;
end

if isfield(s, "maxDimension") && ~isempty(s.maxDimension)
    maxDim = round(double(s.maxDimension));
    if maxDim > 0
        curMax = max(size(img, 1), size(img, 2));
        if curMax > maxDim
            scale = maxDim / double(curMax);
            img = imresize(img, scale);
        end
    end
end
end
