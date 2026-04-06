function info = packet_role_from_session_meta(meta, packetIndex)
%PACKET_ROLE_FROM_SESSION_META  Resolve whether a packet index carries data or RS parity.

packetIndex = round(double(packetIndex));
if packetIndex < 1
    error("packetIndex 必须 >= 1。");
end

required = ["totalPackets", "totalDataPackets", "rsDataPacketsPerBlock", "rsParityPacketsPerBlock"];
for k = 1:numel(required)
    if ~isfield(meta, required(k))
        error("session meta 缺少字段 %s。", required(k));
    end
end

totalTxPackets = round(double(meta.totalPackets));
totalDataPackets = round(double(meta.totalDataPackets));
dataPacketsPerBlock = round(double(meta.rsDataPacketsPerBlock));
parityPacketsPerBlock = round(double(meta.rsParityPacketsPerBlock));

if packetIndex > totalTxPackets
    error("packetIndex=%d 超出总发包数 %d。", packetIndex, totalTxPackets);
end
if totalDataPackets < 1
    error("session meta.totalDataPackets 必须 >= 1。");
end
if dataPacketsPerBlock < 1
    error("session meta.rsDataPacketsPerBlock 必须 >= 1。");
end
if parityPacketsPerBlock < 0
    error("session meta.rsParityPacketsPerBlock 必须 >= 0。");
end

info = struct( ...
    "packetIndex", uint16(packetIndex), ...
    "isDataPacket", false, ...
    "isParityPacket", false, ...
    "sourcePacketIndex", uint16(0), ...
    "blockIndex", uint16(0), ...
    "blockDataCount", uint16(0), ...
    "blockParityCount", uint16(0), ...
    "blockLocalDataIndex", uint16(0), ...
    "blockLocalParityIndex", uint16(0));

if parityPacketsPerBlock == 0
    info.isDataPacket = true;
    info.sourcePacketIndex = uint16(packetIndex);
    info.blockIndex = uint16(ceil(double(packetIndex) / double(dataPacketsPerBlock)));
    info.blockDataCount = uint16(min(dataPacketsPerBlock, totalDataPackets));
    info.blockParityCount = uint16(0);
    info.blockLocalDataIndex = uint16(mod(packetIndex - 1, dataPacketsPerBlock) + 1);
    return;
end

txBase = 0;
dataBase = 0;
blockIndex = 0;
remainingData = totalDataPackets;
while remainingData > 0
    blockIndex = blockIndex + 1;
    kBlock = min(dataPacketsPerBlock, remainingData);
    nBlock = kBlock + parityPacketsPerBlock;
    if packetIndex <= txBase + nBlock
        idxInBlock = packetIndex - txBase;
        info.blockIndex = uint16(blockIndex);
        info.blockDataCount = uint16(kBlock);
        info.blockParityCount = uint16(parityPacketsPerBlock);
        if idxInBlock <= kBlock
            info.isDataPacket = true;
            info.sourcePacketIndex = uint16(dataBase + idxInBlock);
            info.blockLocalDataIndex = uint16(idxInBlock);
        else
            info.isParityPacket = true;
            info.blockLocalParityIndex = uint16(idxInBlock - kBlock);
        end
        return;
    end
    txBase = txBase + nBlock;
    dataBase = dataBase + kBlock;
    remainingData = remainingData - kBlock;
end

error("无法从session meta推断 packetIndex=%d 的角色。", packetIndex);
end
