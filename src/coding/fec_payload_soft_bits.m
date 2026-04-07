function nSoft = fec_payload_soft_bits(fec)
%FEC_PAYLOAD_SOFT_BITS  Resolve payload soft-metric quantization width.

if ~isfield(fec, "kind")
    error("Missing required field fec.kind.");
end

kind = lower(string(fec.kind));
switch kind
    case "conv"
        if ~isfield(fec, "softBits")
            error("fec.kind='conv' requires fec.softBits.");
        end
        rawValue = fec.softBits;
    case "ldpc"
        if ~isfield(fec, "ldpc") || ~isstruct(fec.ldpc) || ~isfield(fec.ldpc, "softBits")
            error("fec.kind='ldpc' requires fec.ldpc.softBits.");
        end
        rawValue = fec.ldpc.softBits;
    otherwise
        error("Unsupported fec.kind: %s", string(fec.kind));
end

nSoft = double(rawValue);
if ~isscalar(nSoft) || ~isfinite(nSoft) || abs(nSoft - round(nSoft)) > 0 || nSoft < 1 || nSoft > 13
    error("Payload softBits must be an integer in [1, 13].");
end
nSoft = round(nSoft);
end
