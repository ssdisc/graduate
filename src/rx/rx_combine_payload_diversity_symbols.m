function [symOut, relOut] = rx_combine_payload_diversity_symbols(symIn, relIn, pkt)
%RX_COMBINE_PAYLOAD_DIVERSITY_SYMBOLS Collapse slow-FH payload diversity copies.

arguments
    symIn (:,1)
    relIn (:,1)
    pkt (1,1) struct
end

symIn = symIn(:);
relIn = rx_expand_reliability(relIn, numel(symIn));
symOut = symIn;
relOut = relIn;

if ~(isfield(pkt, "payloadDiversityInfo") && isstruct(pkt.payloadDiversityInfo) ...
        && isfield(pkt.payloadDiversityInfo, "enable") && logical(pkt.payloadDiversityInfo.enable))
    return;
end
if ~(isfield(pkt, "fhCfg") && isstruct(pkt.fhCfg) && isfield(pkt.fhCfg, "enable") && logical(pkt.fhCfg.enable))
    error("Payload FH diversity RX requires pkt.fhCfg.enable=true.");
end
if fh_is_fast(pkt.fhCfg)
    error("Payload FH diversity RX only supports slow FH.");
end

div = pkt.payloadDiversityInfo;
copies = local_required_positive_integer_local(div, "copies", "pkt.payloadDiversityInfo");
hopLen = local_required_positive_integer_local(div, "hopLen", "pkt.payloadDiversityInfo");
logicalHops = local_required_nonnegative_integer_local(div, "logicalHops", "pkt.payloadDiversityInfo");
logicalSymbolsPadded = local_required_nonnegative_integer_local(div, "logicalSymbolsPadded", "pkt.payloadDiversityInfo");
expectedPhysicalLen = logicalSymbolsPadded * copies;

if numel(symIn) ~= expectedPhysicalLen
    error("Payload FH diversity combine expects %d symbols, got %d.", expectedPhysicalLen, numel(symIn));
end
if logicalSymbolsPadded == 0
    symOut = complex(zeros(0, 1));
    relOut = zeros(0, 1);
    return;
end

symMat = reshape(symIn, hopLen, copies, logicalHops);
relMat = reshape(relIn, hopLen, copies, logicalHops);
symBest = complex(zeros(hopLen, logicalHops));
relBest = zeros(hopLen, logicalHops);

for hopIdx = 1:logicalHops
    symHop = reshape(symMat(:, :, hopIdx), hopLen, copies);
    relHop = reshape(relMat(:, :, hopIdx), hopLen, copies);
    relHop = max(0, min(1, relHop));
    relHop(~isfinite(relHop)) = 0;
    copyScores = mean(relHop, 1);
    [~, refCopyIdx] = max(copyScores);
    refSym = symHop(:, refCopyIdx);
    [symBest(:, hopIdx), relBest(:, hopIdx)] = local_weighted_diversity_combine_local(symHop, relHop, refSym);
end

symOut = symBest(:);
relOut = max(0, min(1, relBest(:)));
symOut = rx_fit_complex_length(symOut, double(pkt.nDataSymBase));
relOut = rx_expand_reliability(relOut, double(pkt.nDataSymBase));
end

function value = local_required_positive_integer_local(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s.%s is required.", ownerName, fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 1)
    error("%s.%s must be a positive integer scalar, got %g.", ownerName, fieldName, value);
end
value = round(value);
end

function [symOut, relOut] = local_weighted_diversity_combine_local(symHop, relHop, refSym)
hopLen = size(symHop, 1);
copies = size(symHop, 2);
symAccum = complex(zeros(hopLen, 1));
weightAccum = zeros(hopLen, 1);

for copyIdx = 1:copies
    symNow = symHop(:, copyIdx);
    relNow = relHop(:, copyIdx);
    phaseRef = sum(symNow .* conj(refSym) .* relNow);
    if abs(phaseRef) > eps
        symNow = symNow * exp(-1j * angle(phaseRef));
    end
    symAccum = symAccum + relNow .* symNow;
    weightAccum = weightAccum + relNow;
end

symOut = refSym;
use = weightAccum > eps;
symOut(use) = symAccum(use) ./ weightAccum(use);
relOut = 1 - prod(1 - relHop, 2);
relOut = max(0, min(1, relOut));
end

function value = local_required_nonnegative_integer_local(s, fieldName, ownerName)
if ~(isfield(s, fieldName) && ~isempty(s.(fieldName)))
    error("%s.%s is required.", ownerName, fieldName);
end
value = double(s.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 0)
    error("%s.%s must be a nonnegative integer scalar, got %g.", ownerName, fieldName, value);
end
value = round(value);
end
