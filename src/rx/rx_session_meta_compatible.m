function ok = rx_session_meta_compatible(metaA, metaB)
%RX_SESSION_META_COMPATIBLE Check whether two recovered session metas describe the same image session.

fields = ["rows" "cols" "channels" "bitsPerPixel" ...
    "totalPayloadBytes" "totalDataPackets" "totalPackets" ...
    "rsDataPacketsPerBlock" "rsParityPacketsPerBlock"];
ok = true;
for idx = 1:numel(fields)
    fieldName = fields(idx);
    if ~isfield(metaA, fieldName) || ~isfield(metaB, fieldName)
        ok = false;
        return;
    end
    ok = ok && double(metaA.(fieldName)) == double(metaB.(fieldName));
end
end
