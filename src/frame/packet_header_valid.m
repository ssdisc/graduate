function ok = packet_header_valid(metaRx, packetIndex, totalPackets, packetPayloadBytes, totalPayloadBytes)
% 校验分包头关键信息是否与当前上下文一致。
ok = true;
needFields = ["packetIndex", "totalPackets", "packetPayloadBytes", "totalPayloadBytes"];
for k = 1:numel(needFields)
    if ~isfield(metaRx, needFields(k))
        ok = false;
        return;
    end
end

if double(metaRx.packetIndex) ~= double(packetIndex)
    ok = false;
    return;
end
if double(metaRx.totalPackets) ~= double(totalPackets)
    ok = false;
    return;
end
if double(metaRx.packetPayloadBytes) ~= double(packetPayloadBytes)
    ok = false;
    return;
end
if double(metaRx.totalPayloadBytes) ~= double(totalPayloadBytes)
    ok = false;
    return;
end
end

