function tf = is_long_sync_packet(frameCfg, pktIdx)
%IS_LONG_SYNC_PACKET  判断当前分包是否使用长前导重同步。

if nargin < 2
    pktIdx = 1;
end
pktIdx = max(1, round(double(pktIdx)));

interval = 0;
if isfield(frameCfg, "resyncIntervalPackets") && ~isempty(frameCfg.resyncIntervalPackets)
    interval = max(0, round(double(frameCfg.resyncIntervalPackets)));
end

if pktIdx <= 1
    tf = true;
elseif interval <= 0
    tf = false;
else
    tf = mod(pktIdx - 1, interval) == 0;
end
end
