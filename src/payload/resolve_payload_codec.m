function [codec, dctCfg] = resolve_payload_codec(payload)
%RESOLVE_PAYLOAD_CODEC  统一解析payload编解码配置。
%
% 输入:
%   payload - 载荷配置结构体
%
% 输出:
%   codec  - "raw" 或 "dct"
%   dctCfg - DCT相关配置（当codec="dct"时使用）

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

