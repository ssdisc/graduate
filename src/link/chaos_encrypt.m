function [imgEnc, encInfo] = chaos_encrypt(imgIn, enc)
%CHAOS_ENCRYPT  混沌图像加密（置乱 + 扩散）。
%
% 加密流程:
%   1. Arnold变换进行像素位置置乱（打破空间相关性）
%   2. Logistic混沌序列生成密钥流
%   3. 密文反馈异或扩散（增强抗差分攻击能力）
%
% 输入:
%   imgIn - 输入图像（灰度uint8）
%   enc   - 加密参数结构体
%           .enable        - 是否启用加密
%           .arnoldIter    - Arnold置乱迭代次数
%           .chaosMethod   - 混沌映射类型 ('logistic', 'henon', 'tent')
%           .chaosParams   - 混沌参数（密钥）
%           .diffusionRounds - 扩散轮数
%
% 输出:
%   imgEnc  - 加密后的图像（uint8）
%   encInfo - 加密信息结构体（用于解密）

arguments
    imgIn (:,:) uint8
    enc (1,1) struct
end

% 检查是否启用加密
if ~isfield(enc, 'enable') || ~enc.enable
    imgEnc = imgIn;
    encInfo = struct('enabled', false);
    return;
end

% 默认参数
if ~isfield(enc, 'arnoldIter'); enc.arnoldIter = 5; end
if ~isfield(enc, 'chaosMethod'); enc.chaosMethod = 'logistic'; end
if ~isfield(enc, 'chaosParams'); enc.chaosParams = struct(); end
if ~isfield(enc, 'diffusionRounds'); enc.diffusionRounds = 2; end

[rows, cols] = size(imgIn);
nPixels = rows * cols;

% 保存原始尺寸
origRows = rows;
origCols = cols;

%% 步骤1: Arnold置乱（需要正方形图像）
if rows ~= cols
    % 填充为正方形
    maxDim = max(rows, cols);
    imgPad = zeros(maxDim, maxDim, 'uint8');
    imgPad(1:rows, 1:cols) = imgIn;
    imgScrambled = arnold_transform(imgPad, enc.arnoldIter, false);
    % 裁剪回原始区域（保持置乱效果）
    imgScrambled = imgScrambled(1:rows, 1:cols);
else
    imgScrambled = arnold_transform(imgIn, enc.arnoldIter, false);
end

%% 步骤2: 生成混沌密钥流
% 需要足够长的序列用于多轮扩散
seqLen = nPixels * enc.diffusionRounds;
chaosSeq = chaos_generate(seqLen, enc.chaosMethod, enc.chaosParams);

% 将混沌序列量化为0-255的整数
keyStream = uint8(floor(chaosSeq * 256));
keyStream(keyStream > 255) = 255;

%% 步骤3: 密文反馈扩散
imgVec = reshape(imgScrambled, [], 1);

for round = 1:enc.diffusionRounds
    % 当前轮的密钥
    keyStart = (round - 1) * nPixels + 1;
    keyEnd = round * nPixels;
    key = keyStream(keyStart:keyEnd);

    % 正向扩散（带密文反馈）
    encrypted = zeros(nPixels, 1, 'uint8');

    % 初始值（使用密钥的一部分）
    prevCipher = key(1);

    for i = 1:nPixels
        % 异或：明文 XOR 密钥 XOR 前一密文
        encrypted(i) = bitxor(bitxor(imgVec(i), key(i)), prevCipher);
        prevCipher = encrypted(i);
    end

    imgVec = encrypted;
end

imgEnc = reshape(imgVec, rows, cols);

%% 保存加密信息
encInfo = struct();
encInfo.enabled = true;
encInfo.origRows = origRows;
encInfo.origCols = origCols;
encInfo.arnoldIter = enc.arnoldIter;
encInfo.chaosMethod = enc.chaosMethod;
encInfo.chaosParams = enc.chaosParams;
encInfo.diffusionRounds = enc.diffusionRounds;

end
