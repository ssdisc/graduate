function imgDec = chaos_decrypt(imgEnc, encInfo)
%CHAOS_DECRYPT  混沌图像解密（逆扩散 + 逆置乱）。
%
% 解密流程（加密的逆过程）:
%   1. 逆扩散：使用相同的混沌密钥流进行逆向异或
%   2. 逆空间置乱：恢复像素位置
%
% 输入:
%   imgEnc  - 加密图像（uint8）
%   encInfo - 加密信息结构体（来自chaos_encrypt）
%             .enabled        - 是否启用解密（false时直接透传）
%             .spatialMethod  - 空间置乱方法（'arnold'/'chaos_permutation'）
%             .arnoldIter     - Arnold逆置乱迭代次数（arnold模式）
%             .chaosMethod    - 混沌映射类型
%             .chaosParams    - 混沌参数（与加密一致）
%             .diffusionRounds- 扩散轮数（与加密一致）
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
            prevCipher = key(1);%第一个像素没有前一个密文，使用密钥的第一个值作为“前一密文”
        else
            prevCipher = imgVec(i-1);%前一个密文像素
        end

        % 逆异或：明文 = 密文 XOR 密钥 XOR 前一密文
        decrypted(i) = bitxor(bitxor(imgVec(i), key(i)), prevCipher);
    end

    imgVec = decrypted;
end

imgScrambled = reshape(imgVec, rows, cols, channels);

%% 步骤3: 逆空间置乱
imgDec = zeros(rows, cols, channels, 'uint8');
if isfield(encInfo, 'spatialMethod')
    spatialMethod = string(encInfo.spatialMethod);
elseif rows == cols
    spatialMethod = "arnold";
else
    spatialMethod = "chaos_permutation";
end

switch lower(spatialMethod)
    case "arnold"
        for ch = 1:channels
            imgDec(:, :, ch) = arnold_transform(imgScrambled(:, :, ch), encInfo.arnoldIter, true);
        end

    case "chaos_permutation"
        [~, invPerm] = chaos_permutation(rows * cols, encInfo.chaosMethod, encInfo.chaosParams);
        for ch = 1:channels
            imgVec = reshape(imgScrambled(:, :, ch), [], 1);
            imgVec = imgVec(invPerm);
            imgDec(:, :, ch) = reshape(imgVec, rows, cols);
        end

    otherwise
        error('未知的空间置乱方法: %s', spatialMethod);
end

end
