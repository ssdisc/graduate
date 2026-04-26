function syncCfg = rx_prepare_capture_sync_cfg(syncCfgIn, channelCfg)
%RX_PREPARE_CAPTURE_SYNC_CFG Resolve capture-search limits for packet/session capture.

syncCfg = syncCfgIn;
if ~isfield(syncCfg, "minSearchIndex") || ~isfinite(double(syncCfg.minSearchIndex))
    syncCfg.minSearchIndex = 1;
end
if ~isfield(syncCfg, "maxSearchIndex") || ~isfinite(double(syncCfg.maxSearchIndex))
    syncCfg.maxSearchIndex = local_default_capture_search_symbols_local(channelCfg);
end
end

function searchMax = local_default_capture_search_symbols_local(channelCfg)
searchMax = 6;
mpExtra = 0;
if isfield(channelCfg, "multipath") && isstruct(channelCfg.multipath) ...
        && isfield(channelCfg.multipath, "enable") && logical(channelCfg.multipath.enable)
    if isfield(channelCfg.multipath, "pathDelaysSymbols") && ~isempty(channelCfg.multipath.pathDelaysSymbols)
        mpExtra = max(double(channelCfg.multipath.pathDelaysSymbols(:)));
    elseif isfield(channelCfg.multipath, "pathDelays") && ~isempty(channelCfg.multipath.pathDelays)
        mpExtra = max(double(channelCfg.multipath.pathDelays(:)));
    end
end
if isfield(channelCfg, "maxDelaySymbols") && isfinite(double(channelCfg.maxDelaySymbols))
    searchMax = max(searchMax, ceil(double(channelCfg.maxDelaySymbols) + mpExtra + 6));
else
    searchMax = max(searchMax, ceil(mpExtra + 6));
end
end
