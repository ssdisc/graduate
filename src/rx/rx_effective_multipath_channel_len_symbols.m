function channelLen = rx_effective_multipath_channel_len_symbols(runtimeCfg, rxCfg)
%RX_EFFECTIVE_MULTIPATH_CHANNEL_LEN_SYMBOLS Resolve the symbol-spaced
%effective multipath channel length used by the refactored receivers.

arguments
    runtimeCfg (1,1) struct
    rxCfg (1,1) struct = struct()
end

maxDelaySymbols = 0;
if isfield(runtimeCfg, "channel") && isstruct(runtimeCfg.channel) ...
        && isfield(runtimeCfg.channel, "multipath") && isstruct(runtimeCfg.channel.multipath) ...
        && isfield(runtimeCfg.channel.multipath, "enable") && logical(runtimeCfg.channel.multipath.enable)
    if isfield(runtimeCfg.channel.multipath, "pathDelaysSymbols") && ~isempty(runtimeCfg.channel.multipath.pathDelaysSymbols)
        delays = double(runtimeCfg.channel.multipath.pathDelaysSymbols(:));
        if any(~isfinite(delays)) || any(delays < 0) || any(abs(delays - round(delays)) > 1e-12)
            error("runtimeCfg.channel.multipath.pathDelaysSymbols must be nonnegative finite integers.");
        end
        maxDelaySymbols = max(round(delays));
    end
end

spanSymbols = 0;
if isfield(runtimeCfg, "waveform") && isstruct(runtimeCfg.waveform) ...
        && isfield(runtimeCfg.waveform, "enable") && logical(runtimeCfg.waveform.enable) ...
        && isfield(runtimeCfg.waveform, "spanSymbols") && isfinite(double(runtimeCfg.waveform.spanSymbols))
    spanSymbols = max(0, round(double(runtimeCfg.waveform.spanSymbols)));
end

if maxDelaySymbols == 0 ...
        && isfield(rxCfg, "channelState") && isstruct(rxCfg.channelState) ...
        && isfield(rxCfg.channelState, "multipathTaps") && ~isempty(rxCfg.channelState.multipathTaps)
    if ~(isfield(runtimeCfg, "waveform") && isstruct(runtimeCfg.waveform) ...
            && isfield(runtimeCfg.waveform, "sps") && isfinite(double(runtimeCfg.waveform.sps)) ...
            && double(runtimeCfg.waveform.sps) >= 1)
        error("runtimeCfg.waveform.sps is required to infer symbol-spaced channel length from channelState.multipathTaps.");
    end
    sps = max(1, round(double(runtimeCfg.waveform.sps)));
    maxDelaySymbols = ceil((numel(rxCfg.channelState.multipathTaps) - 1) / sps);
end

channelLen = max(1, maxDelaySymbols + 2 * spanSymbols + 1);
end
