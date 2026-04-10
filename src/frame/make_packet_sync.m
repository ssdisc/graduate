function [syncBits, syncSym, syncInfo] = make_packet_sync(frameCfg, pktIdx)
%MAKE_PACKET_SYNC  生成首包长前导或后续短同步字。
%
% 首包使用长前导；后续包使用短同步字。

if nargin < 2
    pktIdx = 1;
end
pktIdx = max(1, round(double(pktIdx)));

cfgUse = frameCfg;
if is_long_sync_packet(frameCfg, pktIdx)
    syncLen = local_first_sync_length(frameCfg);
    syncKind = "preamble";
else
    syncLen = local_packet_sync_length(frameCfg);
    syncKind = "sync_word";
    cfgUse = local_apply_packet_sync_cfg(frameCfg);
end

[syncBits, syncSym] = make_preamble(syncLen, cfgUse);
[syncSym, protectInfo] = local_protect_sync_symbols_local(syncSym, cfgUse);
syncInfo = struct( ...
    "kind", syncKind, ...
    "length", syncLen, ...
    "symbolLength", numel(syncSym), ...
    "spreadFactor", protectInfo.spreadFactor);
end

function syncLen = local_first_sync_length(frameCfg)
syncLen = 127;
if isfield(frameCfg, "preambleLength") && ~isempty(frameCfg.preambleLength)
    syncLen = max(1, round(double(frameCfg.preambleLength)));
end
end

function syncLen = local_packet_sync_length(frameCfg)
syncLen = 31;
if isfield(frameCfg, "packetSyncLength") && ~isempty(frameCfg.packetSyncLength)
    syncLen = max(1, round(double(frameCfg.packetSyncLength)));
end
end

function cfgOut = local_apply_packet_sync_cfg(frameCfg)
cfgOut = frameCfg;
if isfield(frameCfg, "packetSyncType") && strlength(string(frameCfg.packetSyncType)) > 0
    cfgOut.preambleType = frameCfg.packetSyncType;
end
if isfield(frameCfg, "packetSyncPnPolynomial") && ~isempty(frameCfg.packetSyncPnPolynomial)
    cfgOut.preamblePnPolynomial = frameCfg.packetSyncPnPolynomial;
end
if isfield(frameCfg, "packetSyncPnInit") && ~isempty(frameCfg.packetSyncPnInit)
    cfgOut.preamblePnInit = frameCfg.packetSyncPnInit;
end
if isfield(frameCfg, "packetSyncChaosMethod") && strlength(string(frameCfg.packetSyncChaosMethod)) > 0
    cfgOut.preambleChaosMethod = frameCfg.packetSyncChaosMethod;
end
if isfield(frameCfg, "packetSyncChaosParams") && isstruct(frameCfg.packetSyncChaosParams)
    cfgOut.preambleChaosParams = frameCfg.packetSyncChaosParams;
end
end

function [syncSym, info] = local_protect_sync_symbols_local(syncSymIn, frameCfg)
syncSym = syncSymIn(:);
dsssCfg = phy_header_dsss_cfg(frameCfg);
info = struct("spreadFactor", 1);
if ~dsssCfg.enable
    return;
end
[syncSym, dsssInfo] = dsss_spread(syncSym, dsssCfg);
info.spreadFactor = dsssInfo.spreadFactor;
end
