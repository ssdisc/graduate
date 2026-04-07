function coded = fec_encode(bits, fec)
%FEC_ENCODE  Payload FEC encode for convolutional or LDPC modes.
%
% 输入:
%   bits - 输入比特流
%   fec  - FEC参数结构体
%
% 输出:
%   coded - 编码后的比特流

bits = uint8(bits(:) ~= 0);
info = fec_get_info(fec);
switch info.kind
    case "conv"
        coded = convenc(bits, fec.trellis);
    case "ldpc"
        if numel(bits) > info.numInfoBits
            error("LDPC单个码字最多承载 %d 比特，当前输入 %d 比特。", ...
                info.numInfoBits, numel(bits));
        end
        infoBitsPadded = false(info.numInfoBits, 1);
        infoBitsPadded(1:numel(bits)) = logical(bits);
        coded = uint8(ldpcEncode(infoBitsPadded, info.ldpcEncoderConfig));
    otherwise
        error("Unsupported FEC kind: %s", info.kind);
end
coded = uint8(coded(:) ~= 0);
end

