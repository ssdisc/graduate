function sessionCtx = rx_build_session_context(meta, transportMode, sourceLabel)
%RX_BUILD_SESSION_CONTEXT Standardize recovered session metadata.

if nargin < 2 || strlength(string(transportMode)) == 0
    transportMode = "unknown";
end
if nargin < 3 || strlength(string(sourceLabel)) == 0
    sourceLabel = "unknown";
end

sessionCtx = struct( ...
    "known", false, ...
    "meta", struct(), ...
    "transportMode", string(transportMode), ...
    "source", string(sourceLabel), ...
    "totalPackets", NaN, ...
    "totalDataPackets", NaN);

if ~isstruct(meta) || isempty(fieldnames(meta))
    return;
end

required = ["rows" "cols" "channels" "bitsPerPixel" "totalPayloadBytes" "totalDataPackets" ...
    "totalPackets" "rsDataPacketsPerBlock" "rsParityPacketsPerBlock"];
for idx = 1:numel(required)
    if ~isfield(meta, required(idx))
        error("Session meta is missing field %s.", required(idx));
    end
end

sessionCtx.known = true;
sessionCtx.meta = meta;
sessionCtx.totalPackets = double(meta.totalPackets);
sessionCtx.totalDataPackets = double(meta.totalDataPackets);
end
