function imgOut = ml_image_denoise(imgIn, model)
%ML_IMAGE_DENOISE  使用训练好的DnCNN模型对图像进行降噪。
%
% 输入:
%   imgIn  - 输入图像（灰度，uint8或double，任意尺寸）
%   model  - 来自ml_train_image_denoise的已训练模型
%
% 输出:
%   imgOut - 降噪后的图像（与输入类型和尺寸相同）

% 检查模型是否已训练
if ~model.trained
    warning('ml_image_denoise:untrained', '模型未训练，返回原始图像');
    imgOut = imgIn;
    return;
end

% 记录输入类型
inputClass = class(imgIn);
inputSize = size(imgIn);

% 转换为double [0,1]
if isa(imgIn, 'uint8')
    img = double(imgIn) / 255;
else
    img = double(imgIn);
    if max(img(:)) > 1
        img = img / 255;
    end
end

% 确保是2D灰度图
if ndims(img) == 3
    img = rgb2gray(img);
end

[H, W] = size(img);

% 填充到能被patchSize整除的尺寸
patchSize = model.patchSize;
padH = ceil(H / patchSize) * patchSize - H;
padW = ceil(W / patchSize) * patchSize - W;

if padH > 0 || padW > 0
    imgPad = padarray(img, [padH, padW], 'symmetric', 'post');
else
    imgPad = img;
end

[Hp, Wp] = size(imgPad);

% 分块处理（避免内存问题）
imgDenoise = zeros(Hp, Wp);

% 使用滑动窗口处理，带重叠以减少边界伪影
overlap = 8;
step = patchSize - overlap;

for i = 1:step:(Hp - patchSize + 1)
    for j = 1:step:(Wp - patchSize + 1)
        % 提取patch
        patch = imgPad(i:i+patchSize-1, j:j+patchSize-1);

        % 转换为dlarray格式 'SSCB' (Height x Width x Channel x Batch)
        patchDl = dlarray(single(reshape(patch, [patchSize, patchSize, 1, 1])), 'SSCB');

        % 前向传播得到残差
        residual = predict(model.net, patchDl);
        residual = double(extractdata(residual));

        % 残差学习：去噪图像 = 输入 - 残差
        patchDenoise = patch - squeeze(residual);
        patchDenoise = max(0, min(1, patchDenoise));  % 裁剪到[0,1]

        % 计算有效区域（去除重叠边界）
        iStart = i;
        iEnd = i + patchSize - 1;
        jStart = j;
        jEnd = j + patchSize - 1;

        % 对于非边界patch，只取中心区域
        if i > 1
            patchIStart = overlap/2 + 1;
            iStart = i + overlap/2;
        else
            patchIStart = 1;
        end

        if j > 1
            patchJStart = overlap/2 + 1;
            jStart = j + overlap/2;
        else
            patchJStart = 1;
        end

        if i + step <= Hp - patchSize + 1
            patchIEnd = patchSize - overlap/2;
            iEnd = i + patchSize - 1 - overlap/2;
        else
            patchIEnd = patchSize;
        end

        if j + step <= Wp - patchSize + 1
            patchJEnd = patchSize - overlap/2;
            jEnd = j + patchSize - 1 - overlap/2;
        else
            patchJEnd = patchSize;
        end

        % 写入结果
        imgDenoise(iStart:iEnd, jStart:jEnd) = patchDenoise(patchIStart:patchIEnd, patchJStart:patchJEnd);
    end
end

% 裁剪回原始尺寸
imgDenoise = imgDenoise(1:H, 1:W);

% 转换回原始类型
if strcmp(inputClass, 'uint8')
    imgOut = uint8(imgDenoise * 255);
else
    imgOut = imgDenoise;
end

% 确保输出尺寸正确
if numel(inputSize) == 2
    imgOut = reshape(imgOut, inputSize);
end

end
