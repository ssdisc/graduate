function [psnrVal, ssimVal, mseVal] = image_quality(ref, test)
%IMAGE_QUALITY  计算参考图像和测试图像之间的MSE/PSNR/SSIM。
%   输入：
%       ref - 参考图像，可以是灰度图像或彩色图像
%       test - 测试图像，与参考图像具有相同的尺寸和通道数
%   输出： 
%       psnrVal - 计算得到的PSNR值，如果图像尺寸不匹配则返回NaN
%       ssimVal - 计算得到的SSIM值，如果图像尺寸不匹配则返回NaN
%       mseVal  - 计算得到的MSE值，如果图像尺寸不匹配则返回NaN

ref = im2uint8(ref);
test = im2uint8(test);

if ~isequal(size(ref), size(test))
    psnrVal = NaN;
    ssimVal = NaN;
    mseVal = NaN;
    return;
end

mseVal = mean((double(test(:)) - double(ref(:))).^2);

try
    psnrVal = psnr(test, ref);
catch
    psnrVal = 10*log10(255^2 / max(mseVal, eps));
end

try
    ssimVal = ssim(test, ref);
catch
    ssimVal = NaN;
end
end

