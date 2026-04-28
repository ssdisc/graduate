function segmentPlan = build_payload_data_segments(payloadBits, meta, pktBitsPerPacket)
%BUILD_PAYLOAD_DATA_SEGMENTS Build packet-aligned payload segments.

payloadBits = uint8(payloadBits(:) ~= 0);
pktBitsPerPacket = round(double(pktBitsPerPacket));
if pktBitsPerPacket <= 0 || mod(pktBitsPerPacket, 8) ~= 0
    error("build_payload_data_segments:InvalidPacketSize", ...
        "pktBitsPerPacket must be a positive multiple of 8.");
end

pktBytesPerPacket = pktBitsPerPacket / 8;
codec = "raw";
if isfield(meta, "codec") && strlength(string(meta.codec)) > 0
    codec = lower(string(meta.codec));
end

if codec == "tile_jp2"
    segmentPlan = local_build_tile_segments_local(payloadBits, meta, pktBytesPerPacket);
else
    segmentPlan = local_build_fixed_segments_local(payloadBits, pktBitsPerPacket);
end

segmentPlan.packetBitsPerPacket = pktBitsPerPacket;
segmentPlan.packetBytesPerPacket = pktBytesPerPacket;
segmentPlan.totalPayloadBits = numel(payloadBits);
segmentPlan.totalPayloadBytes = ceil(numel(payloadBits) / 8);
segmentPlan.codec = codec;
end

function plan = local_build_fixed_segments_local(payloadBits, pktBitsPerPacket)
totalBits = numel(payloadBits);
nSegments = max(1, ceil(totalBits / pktBitsPerPacket));
segments = repmat(local_segment_template_local(), nSegments, 1);
for segIdx = 1:nSegments
    startBit = (segIdx - 1) * pktBitsPerPacket + 1;
    endBit = min(segIdx * pktBitsPerPacket, totalBits);
    segments(segIdx).startBit = startBit;
    segments(segIdx).endBit = endBit;
    segments(segIdx).payloadBits = payloadBits(startBit:endBit);
    segments(segIdx).segmentBytes = ceil((endBit - startBit + 1) / 8);
end
plan = struct( ...
    "tileAware", false, ...
    "segments", segments);
end

function plan = local_build_tile_segments_local(payloadBits, meta, pktBytesPerPacket)
if mod(numel(payloadBits), 8) ~= 0
    error("build_payload_data_segments:TilePayloadByteAlign", ...
        "tile_jp2 payloadBits must be byte-aligned.");
end
if ~(isfield(meta, "codecMeta") && isstruct(meta.codecMeta) && isfield(meta.codecMeta, "tileLengths"))
    error("build_payload_data_segments:MissingTileLengths", ...
        "tile_jp2 meta.codecMeta.tileLengths is required for tile-aware packetization.");
end

tileLengths = double(meta.codecMeta.tileLengths(:));
if any(tileLengths < 0) || any(~isfinite(tileLengths))
    error("build_payload_data_segments:InvalidTileLengths", ...
        "tileLengths must be finite nonnegative values.");
end
payloadBytes = numel(payloadBits) / 8;
if round(sum(tileLengths)) ~= payloadBytes
    error("build_payload_data_segments:TileLengthSumMismatch", ...
        "sum(tileLengths)=%d does not match payloadBytes=%d.", round(sum(tileLengths)), payloadBytes);
end

segments = repmat(local_segment_template_local(), 0, 1);
bitCursor = 1;
for tileIdx = 1:numel(tileLengths)
    tileBytesTotal = round(tileLengths(tileIdx));
    tileBytesRemaining = tileBytesTotal;
    tileOffsetBytes = 0;
    tileSegmentIndex = 1;
    while tileBytesRemaining > 0
        segmentBytes = min(pktBytesPerPacket, tileBytesRemaining);
        segBits = segmentBytes * 8;
        startBit = bitCursor;
        endBit = bitCursor + segBits - 1;

        seg = local_segment_template_local();
        seg.startBit = startBit;
        seg.endBit = endBit;
        seg.payloadBits = payloadBits(startBit:endBit);
        seg.segmentBytes = segmentBytes;
        seg.tileIndex = tileIdx;
        seg.tileSegmentIndex = tileSegmentIndex;
        seg.tileOffsetBytes = tileOffsetBytes;
        seg.tileBytesTotal = tileBytesTotal;
        seg.isTileStart = tileOffsetBytes == 0;
        seg.isTileEnd = (tileOffsetBytes + segmentBytes) == tileBytesTotal;
        segments(end+1, 1) = seg; %#ok<AGROW>

        bitCursor = endBit + 1;
        tileOffsetBytes = tileOffsetBytes + segmentBytes;
        tileBytesRemaining = tileBytesRemaining - segmentBytes;
        tileSegmentIndex = tileSegmentIndex + 1;
    end
end

if bitCursor ~= numel(payloadBits) + 1
    error("build_payload_data_segments:BitCursorMismatch", ...
        "Tile-aware segmentation consumed %d bits, expected %d.", bitCursor - 1, numel(payloadBits));
end

plan = struct( ...
    "tileAware", true, ...
    "segments", segments, ...
    "tileLengths", uint32(tileLengths(:)));
end

function seg = local_segment_template_local()
seg = struct( ...
    "startBit", 0, ...
    "endBit", 0, ...
    "payloadBits", uint8([]), ...
    "segmentBytes", 0, ...
    "tileIndex", 0, ...
    "tileSegmentIndex", 0, ...
    "tileOffsetBytes", 0, ...
    "tileBytesTotal", 0, ...
    "isTileStart", false, ...
    "isTileEnd", false);
end
