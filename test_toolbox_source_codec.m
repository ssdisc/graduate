function report = test_toolbox_source_codec()
%TEST_TOOLBOX_SOURCE_CODEC Lightweight smoke test for MATLAB image codecs.

repoRoot = fileparts(mfilename("fullpath"));
addpath(genpath(fullfile(repoRoot, "src")));

p = default_params( ...
    "linkProfileName", "narrowband", ...
    "strictModelLoad", false, ...
    "requireTrainedMlModels", false, ...
    "loadMlModels", strings(1, 0));
p.commonTx.payload.codec = "toolbox_image";
p.commonTx.payload.toolboxImage.format = "jp2";
p.commonTx.payload.toolboxImage.mode = "lossy";
p.commonTx.payload.toolboxImage.compressionRatio = 8;

img = imread("cameraman.tif");
[bits, meta] = image_to_payload_bits(img, p.commonTx.payload);
imgRx = payload_bits_to_image(bits, meta, p.commonTx.payload);
[psnrVal, ssimVal, mseVal] = image_quality(img, imgRx);

if ~isequal(size(img), size(imgRx))
    error("test_toolbox_source_codec:SizeMismatch", ...
        "Decoded image size does not match input size.");
end
if double(meta.payloadBytes) <= 0 || numel(bits) ~= double(meta.payloadBytes) * 8
    error("test_toolbox_source_codec:InvalidPayloadSize", ...
        "Toolbox payload size metadata is inconsistent.");
end

report = struct( ...
    "payloadBytes", double(meta.payloadBytes), ...
    "payloadBits", numel(bits), ...
    "psnr", double(psnrVal), ...
    "ssim", double(ssimVal), ...
    "mse", double(mseVal));

fprintf("toolbox_image payloadBytes=%d bits=%d psnr=%.3f ssim=%.4f mse=%.3f\n", ...
    report.payloadBytes, report.payloadBits, report.psnr, report.ssim, report.mse);
end
