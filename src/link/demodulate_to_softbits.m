function soft = demodulate_to_softbits(r, mod, fec, softCfg, reliability)
%DEMODULATE_TO_SOFTBITS  Produce Viterbi input metrics with reliability weighting.
%
% Inputs:
%   r          - Received symbols (complex or real)
%   mod        - Modulation parameters
%   fec        - FEC parameters (decisionType, softBits)
%   softCfg    - Soft metric config (clipA)
%   reliability- (optional) Per-symbol reliability weights (0-1)
%                Low reliability pushes soft output toward "erasure" (middle value)

if nargin < 5
    reliability = [];
end

switch upper(string(mod.type))
    case "BPSK"
        metric = real(r(:));
    otherwise
        error("Unsupported modulation: %s", mod.type);
end

if strcmpi(fec.decisionType, "hard")
    soft = uint8(metric < 0);
    return;
end

ns = fec.softBits;
maxv = 2^ns - 1;
midv = maxv / 2;  % Middle value = erasure/uncertain
A = softCfg.clipA;

metric = max(min(metric, A), -A);

% Quantize so that 0 => strong '0', maxv => strong '1'
soft = (A - metric) / (2*A) * maxv;

% Apply reliability weighting if provided
% Low reliability -> push toward middle (erasure)
if ~isempty(reliability)
    reliability = reliability(:);
    if numel(reliability) == numel(soft)
        % Interpolate between soft value and middle (uncertain) value
        soft = reliability .* soft + (1 - reliability) .* midv;
    end
end

soft = round(soft);
soft = uint8(max(min(soft, maxv), 0));
end


