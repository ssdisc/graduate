function [psnrVal, ssimVal] = image_quality(ref, test)
%IMAGE_QUALITY  计算参考图像和测试图像之间的PSNR/SSIM。

ref = im2uint8(ref);
test = im2uint8(test);

if ~isequal(size(ref), size(test))
    psnrVal = NaN;
    ssimVal = NaN;
    return;
end

try
    psnrVal = psnr(test, ref);
catch
    mse = mean((double(test(:)) - double(ref(:))).^2);
    psnrVal = 10*log10(255^2 / max(mse, eps));
end

try
    ssimVal = ssim(test, ref);
catch
    ssimVal = NaN;
end
end

