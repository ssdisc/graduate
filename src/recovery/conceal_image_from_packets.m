function imgOut = conceal_image_from_packets(imgIn, packetOk, txPackets, meta, payload, mode)
% 在图像域/块域做丢包补偿，避免直接在密文比特流上估计。
img = uint8(imgIn);
mode = lower(string(mode));

nPacketsLocal = numel(txPackets);
ok = normalize_packet_ok(packetOk, nPacketsLocal);
if nPacketsLocal <= 1 || all(ok)
    imgOut = img;
    return;
end

codec = get_payload_codec(payload);
if codec == "dct"
    mask = build_dct_pixel_mask_from_packets(ok, txPackets, meta, payload);
else
    mask = build_raw_pixel_mask_from_packets(ok, txPackets, meta);
end

imgOut = inpaint_image_by_mask(img, mask, mode);
end

