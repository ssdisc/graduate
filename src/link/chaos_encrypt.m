function [imgEnc, encInfo] = chaos_encrypt(imgIn, enc)
%CHAOS_ENCRYPT  混沌图像加密（置乱 + 扩散）。
%
% 加密流程:
%   1. 空间置乱（方图使用Arnold；非方图使用混沌置乱索引）
%   2. Logistic混沌序列生成密钥流
%   3. 密文反馈异或扩散（增强抗差分攻击能力）
%
% 输入:
%   imgIn - 输入图像（uint8，灰度或RGB）
%   enc   - 加密参数结构体
%           .enable        - 是否启用加密
%           .arnoldIter    - Arnold置乱迭代次数
%           .chaosMethod   - 混沌映射类型 ('logistic', 'henon', 'tent')
%           .chaosParams   - 混沌参数（密钥）
%                            logistic: .mu, .x0
%                            henon   : .a, .b, .x0, .y0
%                            tent    : .mu, .x0
%           .diffusionRounds - 扩散轮数
%
% 输出:
%   imgEnc  - 加密后的图像（uint8）
%   encInfo - 加密信息结构体（用于解密）
%             .enabled, .origRows, .origCols, .origChannels
%             .arnoldIter, .spatialMethod, .chaosMethod
%             .chaosParams, .diffusionRounds

arguments
    imgIn (:,:,:) uint8
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

rows = size(imgIn, 1);
cols = size(imgIn, 2);
channels = size(imgIn, 3);
nElems = numel(imgIn);

% 保存原始尺寸
origRows = rows;
origCols = cols;
origChannels = channels;

%% 步骤1: 空间置乱（支持任意尺寸）
imgScrambled = zeros(rows, cols, channels, 'uint8');
if rows == cols
    for ch = 1:channels
        imgScrambled(:, :, ch) = arnold_transform(imgIn(:, :, ch), enc.arnoldIter, false);
    end
    spatialMethod = "arnold";
else
    [perm, ~] = chaos_permutation(rows * cols, enc.chaosMethod, enc.chaosParams);
    for ch = 1:channels
        imgVec = reshape(imgIn(:, :, ch), [], 1); %冒号全取，中括号自动推断
        imgVec = imgVec(perm); %序列索引置乱
        imgScrambled(:, :, ch) = reshape(imgVec, rows, cols);
    end
    spatialMethod = "chaos_permutation";
end

%% 步骤2: 生成混沌密钥流
% 需要足够长的序列用于多轮扩散
seqLen = nElems * enc.diffusionRounds;
chaosSeq = chaos_generate(seqLen, enc.chaosMethod, enc.chaosParams);

% 将混沌序列量化为0-255的整数
keyStream = uint8(floor(chaosSeq * 256));
keyStream(keyStream > 255) = 255; %逻辑索引

%% 步骤3: 密文反馈扩散
imgVec = reshape(imgScrambled, [], 1);%又变成列向量

for round = 1:enc.diffusionRounds
    % 当前轮的密钥
    keyStart = (round - 1) * nElems + 1;
    keyEnd = round * nElems;
    key = keyStream(keyStart:keyEnd);

    % 正向扩散（带密文反馈）
    encrypted = zeros(nElems, 1, 'uint8');

    % 初始值（使用密钥的一部分）
    prevCipher = key(1);

    for i = 1:nElems
        % 异或：明文 XOR 密钥 XOR 前一密文
        encrypted(i) = bitxor(bitxor(imgVec(i), key(i)), prevCipher);%明文是打乱后的图像，也是0-255的uint8
        prevCipher = encrypted(i);
    end

    imgVec = encrypted;
end

imgEnc = reshape(imgVec, rows, cols, channels);

%% 保存加密信息
encInfo = struct();
encInfo.enabled = true;
encInfo.origRows = origRows;
encInfo.origCols = origCols;
encInfo.origChannels = origChannels;
encInfo.arnoldIter = enc.arnoldIter;
encInfo.spatialMethod = char(spatialMethod);
encInfo.chaosMethod = enc.chaosMethod;
encInfo.chaosParams = enc.chaosParams;
encInfo.diffusionRounds = enc.diffusionRounds;

end
