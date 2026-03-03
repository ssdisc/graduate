function [bits, meta] = image_to_payload_bits(img, payload)
%IMAGE_TO_PAYLOAD_BITS  将uint8图像转换为载荷比特流。
%
% 输入:
%   img     - 输入图像（uint8）
%   payload - 载荷配置结构体
%             .bitsPerPixel - 每通道位深（当前链路按8处理，对应0-255）
%             .codec        - 'raw' | 'dct'（可选，默认raw）
%             .dct          - DCT压缩配置（codec='dct'时）
%                 .blockSize - DCT分块大小（默认8）
%                 .keepRows  - 保留低频行数（默认4）
%                 .keepCols  - 保留低频列数（默认4）
%                 .quantStep - 量化步长（默认16）
%
% 输出:
%   bits - 图像字节对应的比特流
%   meta - 图像元数据结构体
%          .rows, .cols, .channels
%          .bitsPerPixel, .payloadBytes

rows = size(img, 1);
cols = size(img, 2);
ch = size(img, 3);

[codec, dctCfg] = resolve_payload_codec(payload);
switch codec
    case "raw"
        bytes = reshape(uint8(img), [], 1);
    case "dct"
        bytes = dct_encode_bytes(uint8(img), dctCfg);
    otherwise
        error("不支持的payload.codec: %s", codec);
end

bits = uint_to_bits(bytes, 'uint8vec');

meta = struct();
meta.rows = uint16(rows);
meta.cols = uint16(cols);
meta.channels = uint8(ch);
meta.bitsPerPixel = uint8(payload.bitsPerPixel);
meta.payloadBytes = uint32(numel(bytes));
end

function [codec, dctCfg] = resolve_payload_codec(payload)
codec = "raw";
if isfield(payload, "codec") && strlength(string(payload.codec)) > 0
    codec = lower(string(payload.codec));
end

switch codec
    case {"raw", "none"}
        codec = "raw";
    case {"dct", "dct8", "dct_lossy"}
        codec = "dct";
    otherwise
        error("未知的payload.codec: %s", codec);
end

dctCfg = struct();
if isfield(payload, "dct") && isstruct(payload.dct)
    dctCfg = payload.dct;
end
if ~isfield(dctCfg, "blockSize"); dctCfg.blockSize = 8; end
if ~isfield(dctCfg, "keepRows"); dctCfg.keepRows = 4; end
if ~isfield(dctCfg, "keepCols"); dctCfg.keepCols = 4; end
if ~isfield(dctCfg, "quantStep"); dctCfg.quantStep = 16; end

dctCfg.blockSize = max(2, round(double(dctCfg.blockSize)));
dctCfg.keepRows = max(1, round(double(dctCfg.keepRows)));
dctCfg.keepCols = max(1, round(double(dctCfg.keepCols)));
dctCfg.quantStep = max(eps, double(dctCfg.quantStep));
dctCfg.keepRows = min(dctCfg.keepRows, dctCfg.blockSize);
dctCfg.keepCols = min(dctCfg.keepCols, dctCfg.blockSize);
end

function bytes = dct_encode_bytes(img, cfg)
img = uint8(img);
rows = size(img, 1);
cols = size(img, 2);
ch = size(img, 3);

B = cfg.blockSize;
rPad = ceil(rows / B) * B;
cPad = ceil(cols / B) * B;

imgPad = zeros(rPad, cPad, ch);
imgPad(1:rows, 1:cols, :) = double(img) - 128;

nBr = rPad / B;
nBc = cPad / B;
nKeep = cfg.keepRows * cfg.keepCols;
nBlocks = nBr * nBc * ch;

qCoeffs = zeros(nBlocks * nKeep, 1, "int16");
ptr = 1;

for cc = 1:ch
    for br = 1:nBr
        rIdx = (br-1)*B + (1:B);
        for bc = 1:nBc
            cIdx = (bc-1)*B + (1:B);
            blk = imgPad(rIdx, cIdx, cc);
            c = dct2(blk);
            keep = c(1:cfg.keepRows, 1:cfg.keepCols) / cfg.quantStep;
            keep = round(keep);
            keep = max(min(keep, double(intmax("int16"))), double(intmin("int16")));
            qCoeffs(ptr:ptr+nKeep-1) = int16(keep(:));
            ptr = ptr + nKeep;
        end
    end
end

bytes = reshape(typecast(qCoeffs, "uint8"), [], 1);
end

