function capture = adaptive_frontend_bootstrap_capture(rxRaw, syncSymRef, totalLen, syncCfg, mitigation, modCfg, chain)
%ADAPTIVE_FRONTEND_BOOTSTRAP_CAPTURE  Try multiple light preprocessing chains for initial sync.

arguments
    rxRaw (:,1)
    syncSymRef (:,1)
    totalLen (1,1) double {mustBePositive}
    syncCfg (1,1) struct
    mitigation (1,1) struct
    modCfg (1,1) struct
    chain = strings(1, 0)
end

rxRaw = rxRaw(:);
syncSymRef = syncSymRef(:);
if isempty(chain)
    chain = local_bootstrap_chain(mitigation);
else
    chain = string(chain(:).');
end

capture = struct( ...
    "ok", false, ...
    "bootstrapPath", "", ...
    "preprocessMethod", "", ...
    "startIdx", NaN, ...
    "syncInfo", struct(), ...
    "rxSync", complex(zeros(0, 1)), ...
    "rFull", complex(zeros(0, 1)), ...
    "reliabilityFull", zeros(0, 1), ...
    "triedPaths", chain);

for k = 1:numel(chain)
    pathName = string(chain(k));
    [rxPrep, reliability, methodName] = local_prepare_candidate(rxRaw, pathName, mitigation);
    [startIdx, rxSync, syncInfo] = frame_sync(rxPrep, syncSymRef, syncCfg);
    if isempty(startIdx)
        continue;
    end

    [rFull, okFull] = extract_fractional_block(rxSync, startIdx, totalLen, syncCfg, modCfg);
    if ~okFull
        continue;
    end

    capture.ok = true;
    capture.bootstrapPath = pathName;
    capture.preprocessMethod = methodName;
    capture.startIdx = startIdx;
    capture.syncInfo = syncInfo;
    capture.rxSync = rxSync;
    capture.rFull = rFull;
    capture.reliabilityFull = local_extract_reliability_block(reliability, startIdx, totalLen);
    return;
end
end

function chain = local_bootstrap_chain(mitigation)
chain = ["raw" "adaptive_notch" "blanking"];
if isfield(mitigation, "adaptiveFrontend") && isstruct(mitigation.adaptiveFrontend) ...
        && isfield(mitigation.adaptiveFrontend, "bootstrapSyncChain") ...
        && ~isempty(mitigation.adaptiveFrontend.bootstrapSyncChain)
    chain = string(mitigation.adaptiveFrontend.bootstrapSyncChain(:).');
end
end

function [rxPrep, reliability, methodName] = local_prepare_candidate(rxRaw, pathName, mitigation)
pathName = lower(string(pathName));
switch pathName
    case "raw"
        rxPrep = rxRaw;
        reliability = ones(numel(rxRaw), 1);
        methodName = "none";
    case {"adaptive_notch", "blanking", "fft_notch", "fft_bandstop", "stft_notch", "clipping", "ml_blanking", "ml_cnn", "ml_gru"}
        methodName = pathName;
        [rxPrep, reliability] = mitigate_impulses(rxRaw, methodName, mitigation);
    otherwise
        error("Unsupported bootstrap sync chain entry: %s", char(pathName));
end
end

function relBlk = local_extract_reliability_block(reliability, startPos, nSamp)
reliability = double(reliability(:));
if nSamp <= 0 || isempty(reliability)
    relBlk = zeros(0, 1);
    return;
end

idx = (1:numel(reliability)).';
t = startPos + (0:nSamp-1).';
relBlk = interp1(idx, reliability, t, "linear", 0);
relBlk = max(min(relBlk, 1), 0);
end
