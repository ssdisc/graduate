function img = payload_bits_to_image(bits, meta, payload)
%PAYLOAD_BITS_TO_IMAGE  将载荷比特流转换回图像。
%
% 输入:
%   bits - 载荷比特流
%   meta - 图像元数据结构体
%          .rows, .cols, .channels
%   payload - 载荷配置结构体（可选）
%             .codec - 'raw' | 'dct'
%             .dct   - DCT解压配置（codec='dct'）
%
% 输出:
%   img - 恢复后的uint8图像

if nargin < 3
    payload = struct();
end

bytes = bits_to_uint(bits, 'uint8vec');
declaredBytes = double(meta.payloadBytes);
if numel(bytes) < declaredBytes
    bytes(end+1:declaredBytes, 1) = 0;
else
    bytes = bytes(1:declaredBytes);
end

[codec, dctCfg] = resolve_payload_codec(payload);
switch codec
    case "raw"
        img = raw_decode(bytes, meta);
    case "dct"
        img = dct_decode_bytes(bytes, meta, dctCfg);
    otherwise
        error("不支持的payload.codec: %s", codec);
end
end

function img = raw_decode(bytes, meta)
rows = double(meta.rows);
cols = double(meta.cols);
ch = double(meta.channels);
needBytes = rows * cols * ch;

if numel(bytes) < needBytes
    bytes(end+1:needBytes, 1) = 0;
else
    bytes = bytes(1:needBytes);
end

if ch == 1
    img = reshape(uint8(bytes), rows, cols);
else
    img = reshape(uint8(bytes), rows, cols, ch);
end
end

function img = dct_decode_bytes(bytes, meta, cfg)
rows = double(meta.rows);
cols = double(meta.cols);
ch = double(meta.channels);

B = cfg.blockSize;
rPad = ceil(rows / B) * B;
cPad = ceil(cols / B) * B;
nBr = rPad / B;
nBc = cPad / B;
nKeep = cfg.keepRows * cfg.keepCols;
nCoeffsNeed = nBr * nBc * ch * nKeep;

if mod(numel(bytes), 2) ~= 0
    bytes(end+1, 1) = 0;
end
qCoeffs = double(typecast(uint8(bytes), "int16"));
if numel(qCoeffs) < nCoeffsNeed
    qCoeffs(end+1:nCoeffsNeed, 1) = 0;
else
    qCoeffs = qCoeffs(1:nCoeffsNeed);
end

imgPad = zeros(rPad, cPad, ch);
ptr = 1;
for cc = 1:ch
    for br = 1:nBr
        rIdx = (br-1)*B + (1:B);
        for bc = 1:nBc
            cIdx = (bc-1)*B + (1:B);
            qBlk = reshape(qCoeffs(ptr:ptr+nKeep-1), cfg.keepRows, cfg.keepCols);
            ptr = ptr + nKeep;

            c = zeros(B, B);
            c(1:cfg.keepRows, 1:cfg.keepCols) = qBlk * cfg.quantStep;
            imgPad(rIdx, cIdx, cc) = idct2(c);
        end
    end
end

imgCrop = imgPad(1:rows, 1:cols, :) + 128;
imgCrop = uint8(min(max(round(imgCrop), 0), 255));

if ch == 1
    img = imgCrop(:, :, 1);
else
    img = imgCrop;
end
end

