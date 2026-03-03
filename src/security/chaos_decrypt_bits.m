function bitsOut = chaos_decrypt_bits(bitsEnc, encInfo)
%CHAOS_DECRYPT_BITS  混沌比特流解密（对应chaos_encrypt_bits）。

arguments
    bitsEnc (:,1) {mustBeNumeric}
    encInfo (1,1) struct
end

bits = uint8(bitsEnc(:) ~= 0);
if ~isfield(encInfo, "enabled") || ~encInfo.enabled
    bitsOut = bits;
    return;
end

if ~isfield(encInfo, "nValidBits")
    nValidBits = numel(bits);
else
    nValidBits = double(encInfo.nValidBits);
end
if ~isfield(encInfo, "nBytes")
    nBytes = ceil(nValidBits / 8);
else
    nBytes = double(encInfo.nBytes);
end

if numel(bits) < 8 * nBytes
    bitsPad = [bits; zeros(8 * nBytes - numel(bits), 1, "uint8")];
else
    bitsPad = bits(1:8*nBytes);
end
bytes = bits_to_uint(bitsPad, "uint8vec");

seqLen = nBytes * encInfo.diffusionRounds;
chaosSeq = chaos_generate(seqLen, string(encInfo.chaosMethod), encInfo.chaosParams);
keyStream = uint8(floor(chaosSeq * 256));
keyStream(keyStream > 255) = 255;

data = bytes;
for round = encInfo.diffusionRounds:-1:1
    key = keyStream((round-1)*nBytes + (1:nBytes));
    out = zeros(nBytes, 1, "uint8");
    for i = nBytes:-1:1
        if i == 1
            prevCipher = key(1);
        else
            prevCipher = data(i-1);
        end
        out(i) = bitxor(bitxor(data(i), key(i)), prevCipher);
    end
    data = out;
end

bitsAll = uint_to_bits(data, "uint8vec");
bitsOut = bitsAll(1:min(nValidBits, numel(bitsAll)));
end
