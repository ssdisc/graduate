function [img, imgOriginal] = load_source_image(s)
%LOAD_SOURCE_IMAGE  加载并预处理源图像。
%
% 输入:
%   s - 图像源配置结构体
%       .useBuiltinImage - 是否使用内置图像
%       .imagePath       - 外部图像路径（useBuiltinImage=false时）
%       .grayscale       - 是否转灰度
%       .resizeTo        - 显式重采样尺寸 [rows cols]；非空则直接按此尺寸重采样，
%                          绕过 maxDimension
%       .maxDimension    - 等比例归一目标：将长边缩放到 maxDimension，
%                          保持长宽比。resizeTo 非空时忽略。
%
% 输出:
%   img         - 预处理（含缩小）后的uint8图像，供通信链路使用
%   imgOriginal - 原尺寸 uint8 图像（仅做 grayscale 转换，未 resize），
%                 供接收端恢复原尺寸后评估对比

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

% 原尺寸副本：只做灰度/uint8 规范化，不做任何 resize
imgOriginal = img;

if isfield(s, "resizeTo") && ~isempty(s.resizeTo)
    img = imresize(img, s.resizeTo);
    return;
end

if isfield(s, "maxDimension") && ~isempty(s.maxDimension)
    maxDim = round(double(s.maxDimension));
    if maxDim > 0
        curMax = max(size(img, 1), size(img, 2));
        if curMax <= 0
            error("源图像尺寸无效。");
        end
        if curMax ~= maxDim
            scale = maxDim / double(curMax);
            img = imresize(img, scale);
        end
    end
end
end
