function nBits = fec_coded_bits_length(nInfoBits, fec)
%FEC_CODED_BITS_LENGTH  Return transmitted coded-bit length for payload FEC.

nInfoBits = double(nInfoBits);
if ~isscalar(nInfoBits) || ~isfinite(nInfoBits) || nInfoBits < 0 || abs(nInfoBits - round(nInfoBits)) > 0
    error("nInfoBits must be a nonnegative integer scalar.");
end
nInfoBits = round(nInfoBits);
if nInfoBits == 0
    nBits = 0;
    return;
end

info = fec_get_info(fec);
switch info.kind
    case "conv"
        nBits = round(nInfoBits * info.convOutputBits / info.convInputBits);
    case "ldpc"
        if nInfoBits > info.numInfoBits
            error("LDPC单个码字最多承载 %d 比特，当前请求 %d 比特。", ...
                info.numInfoBits, nInfoBits);
        end
        nBits = info.blockLength;
    otherwise
        error("Unsupported FEC kind: %s", info.kind);
end
end

