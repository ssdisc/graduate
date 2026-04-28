function rxResult = rx_finalize_packet_result(ctx, captureStage, frontEndDiag, headerResult, packetDataBitsRx, symbolReliabilityData, profileDiag)
%RX_FINALIZE_PACKET_RESULT Finalize one packet RX result with session/CRC checks.

if nargin < 6
    symbolReliabilityData = [];
end
if nargin < 7 || isempty(profileDiag)
    profileDiag = struct();
end
if ~isempty(symbolReliabilityData)
    profileDiag.symbolReliabilityData = symbolReliabilityData;
end

frontEndOk = logical(captureStage.frontEndOk) && logical(frontEndDiag.ok);
phyHeaderOk = logical(headerResult.ok);
headerOk = frontEndOk && phyHeaderOk;
packetDataBitsRx = uint8(packetDataBitsRx(:));

sessionMode = session_transport_mode(ctx.runtimeCfg.frame);
sessionCtxIn = local_session_context_in_local(ctx.rxCfg, sessionMode);
sessionCtxOut = sessionCtxIn;
payloadBits = uint8([]);
crcOk = false;
sessionHeaderOk = false;
sessionMetaUpdated = false;
packetSessionRequired = sessionMode ~= "preshared";

if headerOk && ~isempty(packetDataBitsRx)
    packetDataBitsRx = fit_bits_length(packetDataBitsRx, numel(ctx.pkt.packetDataBits));
    crcOk = crc16_ccitt_bits(packetDataBitsRx) == headerResult.phy.packetDataCrc16;
    if crcOk
        if logical(ctx.pkt.hasSessionHeader)
            [metaNow, payloadBits, sessionHeaderOk] = parse_session_header_bits(packetDataBitsRx, ctx.runtimeCfg.frame);
            if sessionHeaderOk
                sessionCtxNow = rx_build_session_context(metaNow, sessionMode, "packet_embedded");
                if sessionCtxIn.known
                    sessionHeaderOk = rx_session_meta_compatible(sessionCtxIn.meta, sessionCtxNow.meta);
                end
                if sessionHeaderOk
                    sessionCtxOut = sessionCtxNow;
                    sessionMetaUpdated = true;
                else
                    payloadBits = uint8([]);
                end
            end
        else
            sessionHeaderOk = sessionCtxIn.known;
            if sessionHeaderOk
                payloadBits = packetDataBitsRx;
            end
        end
    end
end

if sessionCtxOut.known
    sessionHeaderOk = sessionHeaderOk && double(ctx.pkt.packetIndex) <= double(sessionCtxOut.totalPackets);
end

rawPacketOk = frontEndOk && headerOk && crcOk && sessionHeaderOk;
if ~rawPacketOk
    payloadBits = uint8([]);
end

rxResult = struct();
rxResult.method = string(ctx.method);
rxResult.frontEndOk = logical(frontEndOk);
rxResult.phyHeaderOk = logical(phyHeaderOk);
rxResult.headerOk = logical(headerOk);
rxResult.packetSessionRequired = logical(packetSessionRequired);
rxResult.packetSessionOk = logical(sessionHeaderOk);
rxResult.packetOk = logical(rawPacketOk);
rxResult.rawPacketOk = logical(rawPacketOk);
rxResult.payloadBits = uint8(payloadBits(:));
rxResult.sessionCtx = sessionCtxOut;
rxResult.metrics = struct( ...
    "ebN0dB", double(ctx.rxCfg.ebN0dB), ...
    "jsrDb", double(ctx.rxCfg.jsrDb), ...
    "packetIndex", double(ctx.pkt.packetIndex), ...
    "phyHeaderOk", logical(phyHeaderOk), ...
    "headerCrcOk", logical(crcOk), ...
    "packetSessionRequired", logical(packetSessionRequired), ...
    "sessionHeaderOk", logical(sessionHeaderOk), ...
    "sessionKnown", logical(sessionCtxOut.known), ...
    "packetStartSample", double(captureStage.front.packetStartSample), ...
    "packetStopSample", double(captureStage.front.packetStopSample));
rxResult.commonDiagnostics = struct( ...
    "profileName", string(ctx.profileName), ...
    "expectedSymbols", double(ctx.expectedLen), ...
    "receivedSymbols", numel(captureStage.ySymRaw), ...
    "capture", rx_build_capture_diag(captureStage.front), ...
    "frontEnd", frontEndDiag, ...
    "session", struct( ...
        "transportMode", string(sessionMode), ...
        "known", logical(sessionCtxOut.known), ...
        "source", string(sessionCtxOut.source), ...
        "updatedByPacket", logical(sessionMetaUpdated)));
rxResult.profileDiagnostics = profileDiag;
end

function sessionCtx = local_session_context_in_local(rxCfg, sessionMode)
sessionCtx = rx_build_session_context(struct(), sessionMode, "none");
if isfield(rxCfg, "sessionCtx") && isstruct(rxCfg.sessionCtx)
    sessionCtx = rxCfg.sessionCtx;
end
end
