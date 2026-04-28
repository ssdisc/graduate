function rxResult = rx_finalize_packet_result(ctx, captureStage, frontEndDiag, headerResult, packetDataBitsRx, symbolReliabilityData, profileDiag, decodeDiag)
%RX_FINALIZE_PACKET_RESULT Finalize one packet RX result with session/CRC checks.

if nargin < 6
    symbolReliabilityData = [];
end
if nargin < 7 || isempty(profileDiag)
    profileDiag = struct();
end
if nargin < 8 || isempty(decodeDiag)
    decodeDiag = struct();
end
if ~isempty(symbolReliabilityData)
    profileDiag.symbolReliabilityData = symbolReliabilityData;
end

frontEndOk = logical(captureStage.frontEndOk) && logical(frontEndDiag.ok);
phyHeaderOk = logical(headerResult.ok);
packetIndexOk = false;
decodedPacketIndex = NaN;
expectedPacketIndex = double(ctx.pkt.packetIndex);
if phyHeaderOk
    if ~(isfield(headerResult, "phy") && isstruct(headerResult.phy) && isfield(headerResult.phy, "packetIndex"))
        error("rx_finalize_packet_result:MissingPacketIndex", ...
            "PHY header decode reported success but headerResult.phy.packetIndex is missing.");
    end
    decodedPacketIndex = double(headerResult.phy.packetIndex);
    packetIndexOk = isfinite(decodedPacketIndex) && decodedPacketIndex == expectedPacketIndex;
end
headerOk = frontEndOk && phyHeaderOk && packetIndexOk;
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

packetReliability = local_resolve_packet_reliability_local(decodeDiag, symbolReliabilityData);

rxResult = struct();
rxResult.method = string(ctx.method);
rxResult.frontEndOk = logical(frontEndOk);
rxResult.phyHeaderOk = logical(phyHeaderOk);
rxResult.headerOk = logical(headerOk);
rxResult.packetSessionRequired = logical(packetSessionRequired);
rxResult.packetSessionOk = logical(sessionHeaderOk);
rxResult.packetOk = logical(rawPacketOk);
rxResult.rawPacketOk = logical(rawPacketOk);
rxResult.packetReliability = double(packetReliability);
rxResult.payloadBits = uint8(payloadBits(:));
rxResult.sessionCtx = sessionCtxOut;
rxResult.metrics = struct( ...
    "ebN0dB", double(ctx.rxCfg.ebN0dB), ...
    "jsrDb", double(ctx.rxCfg.jsrDb), ...
    "packetIndex", double(ctx.pkt.packetIndex), ...
    "decodedPacketIndex", double(decodedPacketIndex), ...
    "phyHeaderOk", logical(phyHeaderOk), ...
    "packetIndexOk", logical(packetIndexOk), ...
    "headerCrcOk", logical(crcOk), ...
    "packetSessionRequired", logical(packetSessionRequired), ...
    "sessionHeaderOk", logical(sessionHeaderOk), ...
    "sessionKnown", logical(sessionCtxOut.known), ...
    "packetReliability", double(packetReliability), ...
    "packetStartSample", double(captureStage.front.packetStartSample), ...
    "packetStopSample", double(captureStage.front.packetStopSample));
rxResult.commonDiagnostics = struct( ...
    "profileName", string(ctx.profileName), ...
    "expectedSymbols", double(ctx.expectedLen), ...
    "receivedSymbols", numel(captureStage.ySymRaw), ...
    "expectedPacketIndex", double(expectedPacketIndex), ...
    "decodedPacketIndex", double(decodedPacketIndex), ...
    "packetIndexOk", logical(packetIndexOk), ...
    "capture", rx_build_capture_diag(captureStage.front), ...
    "frontEnd", frontEndDiag, ...
    "decode", decodeDiag, ...
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

function packetReliability = local_resolve_packet_reliability_local(decodeDiag, symbolReliabilityData)
packetReliability = 0;
if isstruct(decodeDiag) && isfield(decodeDiag, "packetReliability") ...
        && isfinite(double(decodeDiag.packetReliability))
    packetReliability = double(decodeDiag.packetReliability);
elseif ~isempty(symbolReliabilityData)
    symbolReliabilityData = double(symbolReliabilityData(:));
    symbolReliabilityData(~isfinite(symbolReliabilityData)) = 0;
    symbolReliabilityData = max(min(symbolReliabilityData, 1), 0);
    packetReliability = mean(symbolReliabilityData);
end
packetReliability = max(min(packetReliability, 1), 0);
end
