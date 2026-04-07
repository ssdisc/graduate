function info = fec_get_info(fec)
%FEC_GET_INFO  Resolve payload FEC parameters and derived coding metadata.

arguments
    fec (1,1) struct
end

kind = local_required_string_field(fec, "kind", "fec.kind");
switch lower(kind)
    case "conv"
        if ~isfield(fec, "trellis")
            error("fec.kind='conv' requires fec.trellis.");
        end
        numInputBits = log2(fec.trellis.numInputSymbols);
        numOutputBits = log2(fec.trellis.numOutputSymbols);
        if ~isfinite(numInputBits) || ~isfinite(numOutputBits) || numInputBits <= 0 || numOutputBits <= 0
            error("卷积码trellis无效，无法推导码率。");
        end

        info = struct( ...
            "kind", "conv", ...
            "codeRate", numInputBits / numOutputBits, ...
            "convInputBits", numInputBits, ...
            "convOutputBits", numOutputBits, ...
            "ldpcRateName", "", ...
            "ldpcFrameType", "", ...
            "numInfoBits", NaN, ...
            "blockLength", NaN, ...
            "ldpcEncoderConfig", [], ...
            "ldpcDecoderConfig", [], ...
            "ldpcMaxIterations", NaN, ...
            "ldpcMinSumScalingFactor", NaN, ...
            "ldpcMinSumOffset", NaN, ...
            "ldpcTermination", "", ...
            "ldpcMultithreaded", false);

    case "ldpc"
        if ~isfield(fec, "ldpc") || ~isstruct(fec.ldpc)
            error("fec.kind='ldpc' requires a fec.ldpc struct.");
        end

        rateName = local_required_string_field(fec.ldpc, "rate", "fec.ldpc.rate");
        frameType = lower(local_required_string_field(fec.ldpc, "frameType", "fec.ldpc.frameType"));
        supportedFrameTypes = ["normal" "medium" "short"];
        if ~any(frameType == supportedFrameTypes)
            error("fec.ldpc.frameType=%s is unsupported. Expected one of: %s.", ...
                frameType, strjoin(cellstr(supportedFrameTypes), ", "));
        end

        codec = local_cached_dvbs_ldpc_codec(rateName, frameType);
        info = struct( ...
            "kind", "ldpc", ...
            "codeRate", codec.numInfoBits / codec.blockLength, ...
            "convInputBits", NaN, ...
            "convOutputBits", NaN, ...
            "ldpcRateName", rateName, ...
            "ldpcFrameType", frameType, ...
            "numInfoBits", codec.numInfoBits, ...
            "blockLength", codec.blockLength, ...
            "ldpcEncoderConfig", codec.encoderConfig, ...
            "ldpcDecoderConfig", codec.decoderConfig, ...
            "ldpcMaxIterations", local_positive_integer_field(fec.ldpc, "maxIterations", "fec.ldpc.maxIterations"), ...
            "ldpcMinSumScalingFactor", local_scalar_in_range(fec.ldpc, "minSumScalingFactor", ...
                "fec.ldpc.minSumScalingFactor", 0, 1, false), ...
            "ldpcMinSumOffset", local_nonnegative_scalar_field(fec.ldpc, "minSumOffset", "fec.ldpc.minSumOffset"), ...
            "ldpcTermination", local_enum_string_field(fec.ldpc, "termination", "fec.ldpc.termination", ["early" "max"]), ...
            "ldpcMultithreaded", local_logical_scalar_field(fec.ldpc, "multithreaded", "fec.ldpc.multithreaded"));

    otherwise
        error("Unsupported fec.kind: %s", kind);
end
end

function codec = local_cached_dvbs_ldpc_codec(rateName, frameType)
persistent cacheKeys cacheVals
if isempty(cacheKeys)
    cacheKeys = strings(0, 1);
    cacheVals = cell(0, 1);
end

key = rateName + "|" + frameType;
idx = find(cacheKeys == key, 1, "first");
if ~isempty(idx)
    codec = cacheVals{idx};
    return;
end

pcm = dvbsLDPCPCM(rateName, frameType, "sparse");
encoderConfig = ldpcEncoderConfig(pcm);
decoderConfig = ldpcDecoderConfig(pcm);
codec = struct( ...
    "encoderConfig", encoderConfig, ...
    "decoderConfig", decoderConfig, ...
    "numInfoBits", double(encoderConfig.NumInformationBits), ...
    "blockLength", double(encoderConfig.BlockLength));
cacheKeys(end + 1, 1) = key;
cacheVals{end + 1, 1} = codec;
end

function value = local_required_string_field(s, fieldName, label)
if ~isfield(s, fieldName)
    error("Missing required field %s.", label);
end
value = string(s.(fieldName));
if strlength(value) == 0
    error("%s must be a non-empty string.", label);
end
value = value(1);
end

function value = local_positive_integer_field(s, fieldName, label)
if ~isfield(s, fieldName)
    error("Missing required field %s.", label);
end
value = double(s.(fieldName));
if ~isscalar(value) || ~isfinite(value) || value <= 0 || abs(value - round(value)) > 0
    error("%s must be a positive integer scalar.", label);
end
value = round(value);
end

function value = local_nonnegative_scalar_field(s, fieldName, label)
if ~isfield(s, fieldName)
    error("Missing required field %s.", label);
end
value = double(s.(fieldName));
if ~isscalar(value) || ~isfinite(value) || value < 0
    error("%s must be a nonnegative finite scalar.", label);
end
end

function value = local_scalar_in_range(s, fieldName, label, lowerBound, upperBound, includeLower)
if ~isfield(s, fieldName)
    error("Missing required field %s.", label);
end
value = double(s.(fieldName));
if ~isscalar(value) || ~isfinite(value) || value > upperBound
    error("%s must be a finite scalar in the valid range.", label);
end
if includeLower
    lowerOk = value >= lowerBound;
else
    lowerOk = value > lowerBound;
end
if ~lowerOk
    error("%s must be greater than %.4g.", label, lowerBound);
end
end

function value = local_enum_string_field(s, fieldName, label, validValues)
value = lower(local_required_string_field(s, fieldName, label));
if ~any(value == validValues)
    error("%s=%s is unsupported. Expected one of: %s.", ...
        label, value, strjoin(cellstr(validValues), ", "));
end
end

function value = local_logical_scalar_field(s, fieldName, label)
if ~isfield(s, fieldName)
    error("Missing required field %s.", label);
end
raw = s.(fieldName);
if ~(islogical(raw) || isnumeric(raw))
    error("%s must be a logical scalar.", label);
end
value = logical(raw);
if ~isscalar(value)
    error("%s must be a logical scalar.", label);
end
end
