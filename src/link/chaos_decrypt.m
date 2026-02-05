function imgDec = chaos_decrypt(imgEnc, encInfo)
%CHAOS_DECRYPT  混沌图像解密（逆扩散 + 逆置乱）。
%
% 解密流程（加密的逆过程）:
%   1. 逆扩散：使用相同的混沌密钥流进行逆向异或
%   2. 逆Arnold变换：恢复像素位置
%
% 输入:
%   imgEnc  - 加密图像（uint8）
%   encInfo - 加密信息结构体（来自chaos_encrypt）
%
% 输出:
%   imgDec  - 解密后的图像（uint8）

arguments
    imgEnc (:,:,:) uint8
    encInfo (1,1) struct
end

% 检查是否启用了加密
if ~isfield(encInfo, 'enabled') || ~encInfo.enabled
    imgDec = imgEnc;
    return;
end

rows = size(imgEnc, 1);
cols = size(imgEnc, 2);
channels = size(imgEnc, 3);
nElems = numel(imgEnc);

%% 步骤1: 生成相同的混沌密钥流
seqLen = nElems * encInfo.diffusionRounds;
chaosSeq = chaos_generate(seqLen, encInfo.chaosMethod, encInfo.chaosParams);

% 量化为0-255
keyStream = uint8(floor(chaosSeq * 256));
keyStream(keyStream > 255) = 255;

%% 步骤2: 逆扩散（从最后一轮开始逆向）
imgVec = reshape(imgEnc, [], 1);

for round = encInfo.diffusionRounds:-1:1
    % 当前轮的密钥
    keyStart = (round - 1) * nElems + 1;
    keyEnd = round * nElems;
    key = keyStream(keyStart:keyEnd);

    % 逆向扩散
    decrypted = zeros(nElems, 1, 'uint8');

    % 从最后一个像素开始逆向解密
    for i = nElems:-1:1
        if i == 1
            prevCipher = key(1);
        else
            prevCipher = imgVec(i-1);
        end

        % 逆异或：明文 = 密文 XOR 密钥 XOR 前一密文
        decrypted(i) = bitxor(bitxor(imgVec(i), key(i)), prevCipher);
    end

    imgVec = decrypted;
end

imgScrambled = reshape(imgVec, rows, cols, channels);

%% 步骤3: 逆Arnold置乱
imgDec = zeros(rows, cols, channels, 'uint8');
for ch = 1:channels
    imgCh = imgScrambled(:, :, ch);
    if rows ~= cols
        % 填充为正方形进行逆变换
        maxDim = max(rows, cols);
        imgPad = zeros(maxDim, maxDim, 'uint8');
        imgPad(1:rows, 1:cols) = imgCh;
        decCh = arnold_transform(imgPad, encInfo.arnoldIter, true);
        decCh = decCh(1:rows, 1:cols);
    else
        decCh = arnold_transform(imgCh, encInfo.arnoldIter, true);
    end
    imgDec(:, :, ch) = decCh;
end

end
