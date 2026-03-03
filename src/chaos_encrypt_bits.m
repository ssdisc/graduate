function [bitsEnc, encInfo] = chaos_encrypt_bits(bitsIn, enc)
%CHAOS_ENCRYPT_BITS  对比特流进行混沌字节流加密（扩散反馈）。
%
% 输入:
%   bitsIn - 输入比特流（0/1）
%   enc    - 加密参数结构体
%            .enable          - 是否启用
%            .chaosMethod     - 'logistic'/'henon'/'tent'
%            .chaosParams     - 混沌参数
%            .diffusionRounds - 扩散轮数
%
% 输出:
%   bitsEnc - 加密后比特流
%   encInfo - 解密所需信息

arguments
    bitsIn (:,1) {mustBeNumeric}
    enc (1,1) struct
end

bits = uint8(bitsIn(:) ~= 0);
if ~isfield(enc, "enable") || ~enc.enable
    bitsEnc = bits;
    encInfo = struct("enabled", false, "mode", "none");
    return;
end

if ~isfield(enc, "chaosMethod"); enc.chaosMethod = "logistic"; end
if ~isfield(enc, "chaosParams"); enc.chaosParams = struct(); end
if ~isfield(enc, "diffusionRounds"); enc.diffusionRounds = 2; end

nValidBits = numel(bits);
nBytes = ceil(nValidBits / 8);
if numel(bits) < 8 * nBytes
    bitsPad = [bits; zeros(8 * nBytes - numel(bits), 1, "uint8")];
else
    bitsPad = bits;
end
bytes = bits_to_uint(bitsPad, "uint8vec");

seqLen = nBytes * enc.diffusionRounds;
chaosSeq = chaos_generate(seqLen, string(enc.chaosMethod), enc.chaosParams);
keyStream = uint8(floor(chaosSeq * 256));
keyStream(keyStream > 255) = 255;

data = bytes;
for round = 1:enc.diffusionRounds
    key = keyStream((round-1)*nBytes + (1:nBytes));
    out = zeros(nBytes, 1, "uint8");
    prevCipher = key(1);
    for i = 1:nBytes
        out(i) = bitxor(bitxor(data(i), key(i)), prevCipher);
        prevCipher = out(i);
    end
    data = out;
end

bitsAll = uint_to_bits(data, "uint8vec");
bitsEnc = bitsAll(1:nValidBits);

encInfo = struct();
encInfo.enabled = true;
encInfo.mode = "payload_bits";
encInfo.chaosMethod = string(enc.chaosMethod);
encInfo.chaosParams = enc.chaosParams;
encInfo.diffusionRounds = enc.diffusionRounds;
encInfo.nBytes = uint32(nBytes);
encInfo.nValidBits = uint32(nValidBits);
end
