function [payloadMetaOut, payloadCfgOut] = resolve_payload_decode_inputs(sessionCtx, txArtifacts, payloadCfgIn)
%RESOLVE_PAYLOAD_DECODE_INPUTS Resolve payload meta/cfg for RX-side image reconstruction.

payloadMetaOut = txArtifacts.payloadAssist.payloadMeta;
payloadCfgOut = payloadCfgIn;

if ~(isstruct(sessionCtx) && isfield(sessionCtx, "known") && logical(sessionCtx.known) ...
        && isfield(sessionCtx, "meta") && isstruct(sessionCtx.meta))
    return;
end

metaRx = sessionCtx.meta;
payloadMetaOut = local_merge_payload_meta_local(payloadMetaOut, metaRx);
if isfield(metaRx, "codec") && strlength(string(metaRx.codec)) > 0
    payloadCfgOut.codec = string(metaRx.codec);
end
payloadCfgOut = local_merge_payload_cfg_local(payloadCfgOut, payloadMetaOut);
end

function payloadMetaOut = local_merge_payload_meta_local(payloadMetaIn, metaRx)
payloadMetaOut = payloadMetaIn;
fieldNames = string(fieldnames(metaRx));
for idx = 1:numel(fieldNames)
    payloadMetaOut.(fieldNames(idx)) = metaRx.(fieldNames(idx));
end
end

function payloadCfgOut = local_merge_payload_cfg_local(payloadCfgIn, payloadMeta)
payloadCfgOut = payloadCfgIn;
codec = "raw";
if isfield(payloadMeta, "codec") && strlength(string(payloadMeta.codec)) > 0
    codec = lower(string(payloadMeta.codec));
end

codecMeta = struct();
if isfield(payloadMeta, "codecMeta") && isstruct(payloadMeta.codecMeta)
    codecMeta = payloadMeta.codecMeta;
end

switch codec
    case "raw"
        return;

    case "dct"
        if isempty(fieldnames(codecMeta))
            return;
        end
        if ~isfield(payloadCfgOut, "dct") || ~isstruct(payloadCfgOut.dct)
            payloadCfgOut.dct = struct();
        end
        payloadCfgOut.dct = local_copy_all_fields_local(payloadCfgOut.dct, codecMeta);

    case "toolbox_image"
        if ~isfield(payloadCfgOut, "toolboxImage") || ~isstruct(payloadCfgOut.toolboxImage)
            payloadCfgOut.toolboxImage = struct();
        end
        payloadCfgOut.toolboxImage = local_copy_all_fields_local(payloadCfgOut.toolboxImage, codecMeta);

    case "tile_jp2"
        if ~isfield(payloadCfgOut, "tileJp2") || ~isstruct(payloadCfgOut.tileJp2)
            payloadCfgOut.tileJp2 = struct();
        end
        payloadCfgOut.tileJp2 = local_copy_all_fields_local(payloadCfgOut.tileJp2, codecMeta);

    otherwise
        error("resolve_payload_decode_inputs:UnsupportedCodec", ...
            "Unsupported payload codec '%s'.", codec);
end
end

function dst = local_copy_all_fields_local(dst, src)
fieldNames = string(fieldnames(src));
for idx = 1:numel(fieldNames)
    dst.(fieldNames(idx)) = src.(fieldNames(idx));
end
end
