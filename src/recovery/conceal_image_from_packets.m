function imgOut = conceal_image_from_packets(imgIn, packetOk, txPackets, meta, payload, mode)
% 在图像域/块域做丢包补偿，避免直接在密文比特流上估计。
img = uint8(imgIn);
mode = lower(string(mode));
if ~any(mode == ["nearest" "blend"])
    error("conceal_image_from_packets:InvalidMode", ...
        "mode must be 'nearest' or 'blend'.");
end

[ok, layout] = local_resolve_packet_layout_local(packetOk, txPackets);
nPacketsLocal = numel(layout);
if nPacketsLocal <= 1 || all(ok)
    imgOut = img;
    return;
end

codec = get_payload_codec(payload);
if codec == "dct"
    mask = build_dct_pixel_mask_from_packets(ok, layout, meta, payload);
elseif codec == "raw"
    mask = build_raw_pixel_mask_from_packets(ok, layout, meta);
elseif codec == "tile_jp2"
    mask = build_tile_jp2_pixel_mask_from_packets(ok, layout, meta, payload);
else
    error("conceal_image_from_packets:UnsupportedCodec", ...
        "Packet-loss concealment is not implemented for payload.codec='%s'.", codec);
end

imgOut = inpaint_image_by_mask(img, mask, mode);
end

function [okOut, layoutOut] = local_resolve_packet_layout_local(packetOkIn, txPacketsIn)
packetOkIn = logical(packetOkIn(:).');
txPackets = txPacketsIn(:);
if isempty(txPackets)
    error("conceal_image_from_packets:EmptyTxPackets", "txPackets must not be empty.");
end

if ~isfield(txPackets, "isDataPacket")
    if numel(packetOkIn) ~= numel(txPackets)
        error("conceal_image_from_packets:PacketLengthMismatch", ...
            "packetOk length (%d) must equal txPackets length (%d).", ...
            numel(packetOkIn), numel(txPackets));
    end
    okOut = packetOkIn;
    layoutOut = txPackets;
    return;
end

dataMask = arrayfun(@(pkt) logical(pkt.isDataPacket), txPackets);
nDataPackets = sum(dataMask);
if nDataPackets < 1
    error("conceal_image_from_packets:NoDataPackets", ...
        "txPackets must contain at least one data packet.");
end
layoutOut = local_sort_data_packets_by_source_local(txPackets(dataMask), nDataPackets);

if numel(packetOkIn) == nDataPackets
    okOut = packetOkIn;
elseif numel(packetOkIn) == numel(txPackets)
    okOut = false(1, nDataPackets);
    for pktIdx = 1:numel(txPackets)
        pkt = txPackets(pktIdx);
        if ~logical(pkt.isDataPacket)
            continue;
        end
        srcIdx = local_required_source_idx_local(pkt, nDataPackets, pktIdx);
        okOut(srcIdx) = packetOkIn(pktIdx);
    end
else
    error("conceal_image_from_packets:PacketLengthMismatch", ...
        "packetOk length (%d) must equal data packet count (%d) or tx packet count (%d).", ...
        numel(packetOkIn), nDataPackets, numel(txPackets));
end
end

function dataPacketsSorted = local_sort_data_packets_by_source_local(dataPackets, nDataPackets)
dataPacketsSorted = repmat(dataPackets(1), nDataPackets, 1);
filled = false(1, nDataPackets);
for idx = 1:numel(dataPackets)
    srcIdx = local_required_source_idx_local(dataPackets(idx), nDataPackets, idx);
    if filled(srcIdx)
        error("conceal_image_from_packets:DuplicateSourcePacket", ...
            "Duplicate sourcePacketIndex=%d found in data packets.", srcIdx);
    end
    dataPacketsSorted(srcIdx) = dataPackets(idx);
    filled(srcIdx) = true;
end
if any(~filled)
    missing = find(~filled, 1, "first");
    error("conceal_image_from_packets:MissingSourcePacket", ...
        "Missing data packet for sourcePacketIndex=%d.", missing);
end
end

function srcIdx = local_required_source_idx_local(pkt, nDataPackets, pktPos)
if ~(isfield(pkt, "sourcePacketIndex") && isfinite(double(pkt.sourcePacketIndex)))
    error("conceal_image_from_packets:MissingSourcePacketIndex", ...
        "Data packet %d lacks sourcePacketIndex.", pktPos);
end
srcVal = double(pkt.sourcePacketIndex);
if ~(isscalar(srcVal) && abs(srcVal - round(srcVal)) <= 1e-12 ...
        && srcVal >= 1 && srcVal <= nDataPackets)
    error("conceal_image_from_packets:InvalidSourcePacketIndex", ...
        "Data packet %d has invalid sourcePacketIndex=%g.", pktPos, srcVal);
end
srcIdx = round(srcVal);
end

