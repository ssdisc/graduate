function codec = get_payload_codec(payload)
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
        codec = "raw";
end
end

