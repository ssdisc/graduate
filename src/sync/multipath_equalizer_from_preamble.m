function [eq, ok] = multipath_equalizer_from_preamble(txPreamble, rxPreamble, cfg, N0, channelLenSymbols)
%MULTIPATH_EQUALIZER_FROM_PREAMBLE  Estimate the base multipath channel and
%build a frequency-aware FFE bank for the current FH receiver.
%
% The transmitted FH waveform is dehopped before matched filtering. A delayed
% path therefore picks up a hop-frequency-dependent phase after dehopping:
% h_l(f) = h_l(0) * exp(-j*2*pi*f*tau_l), where f is normalized to symbol
% rate and tau_l is the path delay in symbols. The preamble is not hopped, so
% it estimates h_l(0); the equalizer bank below synthesizes h_l(f) for each
% hop frequency used by PHY/data symbols.
%
% Inputs:
%   txPreamble        - known un-hopped preamble symbols (column)
%   rxPreamble        - received preamble symbols after sync compensation
%   cfg               - equalizer config
%       .method           - "mmse" | "zf"
%       .nTaps            - FFE length in symbols
%       .lambdaFactor     - MMSE regularization, lambda=lambdaFactor*N0
%       .frequencyOffsets - hop frequencies to support, normalized to Rs
%   N0                - complex noise variance for MMSE regularization
%   channelLenSymbols - assumed symbol-spaced channel length
%
% Outputs:
%   eq - equalizer struct with hEst plus gBank(:,k) for frequencyOffsets(k)
%   ok - true when design succeeds; invalid inputs raise errors

arguments
    txPreamble (:,1) double
    rxPreamble (:,1) double
    cfg (1,1) struct = struct()
    N0 (1,1) double {mustBeNonnegative} = 0
    channelLenSymbols (1,1) double {mustBePositive} = 1
end

eq = struct();
ok = false;

method = local_required_string_field(cfg, "method");
method = lower(method);
if ~any(method == ["mmse" "zf"])
    error("Unsupported equalizer method: %s", string(method));
end
nTaps = local_required_positive_integer_field(cfg, "nTaps");
lambdaFactor = local_required_nonnegative_scalar_field(cfg, "lambdaFactor");
frequencyOffsets = local_frequency_offsets_from_cfg(cfg);

Lh = round(double(channelLenSymbols));
if ~(isscalar(Lh) && isfinite(Lh) && Lh >= 1)
    error("channelLenSymbols must be a positive finite integer, got %g.", channelLenSymbols);
end
if abs(double(channelLenSymbols) - Lh) > 1e-12
    error("channelLenSymbols must be an integer, got %g.", channelLenSymbols);
end

tx = txPreamble(:);
rx = rxPreamble(:);
L = min(numel(tx), numel(rx));
minPreambleSymbols = max(8, 2 * Lh);
if L < minPreambleSymbols
    error("Multipath equalizer needs at least %d aligned preamble symbols, got %d.", minPreambleSymbols, L);
end
tx = tx(1:L);
rx = rx(1:L);

Leq = max(Lh, nTaps);
delay = Lh - 1;
symbolDelays = (0:Lh-1).';

% --- Channel estimate h via LS: y ~= x (*) h ---
Xfull = toeplitz([tx; zeros(Lh - 1, 1)], [tx(1); zeros(Lh - 1, 1)]);
X = Xfull(1:L, :);
if rank(X) < Lh
    error("Preamble is rank-deficient for a %d-tap multipath estimate.", Lh);
end
hEst = X \ rx;
if any(~isfinite(hEst))
    error("Multipath channel estimate contains non-finite values.");
end

lambda = 0;
if method == "mmse"
    lambda = lambdaFactor * N0;
end
if ~(isscalar(lambda) && isfinite(lambda) && lambda >= 0)
    error("MMSE regularization lambda must be finite and nonnegative, got %g.", lambda);
end

gBank = complex(zeros(Leq, numel(frequencyOffsets)));
mainTaps = complex(zeros(1, numel(frequencyOffsets)));
hBank = complex(zeros(Lh, numel(frequencyOffsets)));
for k = 1:numel(frequencyOffsets)
    hNow = hEst .* exp(-1j * 2 * pi * double(frequencyOffsets(k)) * symbolDelays);
    [gNow, mainTapNow] = local_design_linear_equalizer(hNow, Leq, delay, lambda);
    hBank(:, k) = hNow;
    gBank(:, k) = gNow;
    mainTaps(k) = mainTapNow;
end

eq.enabled = true;
eq.method = method;
eq.hEst = hEst;
eq.hBank = hBank;
eq.g = gBank(:, local_frequency_bank_index(frequencyOffsets, 0));
eq.gBank = gBank;
eq.delay = delay;
eq.channelLen = Lh;
eq.eqLen = Leq;
eq.lambda = lambda;
eq.mainTap = mainTaps(local_frequency_bank_index(frequencyOffsets, 0));
eq.mainTaps = mainTaps;
eq.frequencyOffsets = frequencyOffsets;
eq.symbolDelays = symbolDelays;
ok = true;

end

function value = local_required_string_field(cfg, fieldName)
if ~(isfield(cfg, fieldName) && strlength(string(cfg.(fieldName))) > 0)
    error("rxSync.multipathEq.%s is required.", fieldName);
end
value = string(cfg.(fieldName));
if ~(isscalar(value) && strlength(value) > 0)
    error("rxSync.multipathEq.%s must be a non-empty string scalar.", fieldName);
end
end

function value = local_required_positive_integer_field(cfg, fieldName)
if ~(isfield(cfg, fieldName) && ~isempty(cfg.(fieldName)))
    error("rxSync.multipathEq.%s is required.", fieldName);
end
value = double(cfg.(fieldName));
if ~(isscalar(value) && isfinite(value) && abs(value - round(value)) < 1e-12 && value >= 1)
    error("rxSync.multipathEq.%s must be a positive integer scalar, got %g.", fieldName, value);
end
value = round(value);
end

function value = local_required_nonnegative_scalar_field(cfg, fieldName)
if ~(isfield(cfg, fieldName) && ~isempty(cfg.(fieldName)))
    error("rxSync.multipathEq.%s is required.", fieldName);
end
value = double(cfg.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("rxSync.multipathEq.%s must be a finite nonnegative scalar, got %g.", fieldName, value);
end
end

function frequencyOffsets = local_frequency_offsets_from_cfg(cfg)
if ~(isfield(cfg, "frequencyOffsets") && ~isempty(cfg.frequencyOffsets))
    frequencyOffsets = 0;
else
    frequencyOffsets = double(cfg.frequencyOffsets(:).');
end
if isempty(frequencyOffsets) || any(~isfinite(frequencyOffsets))
    error("rxSync.multipathEq.frequencyOffsets must contain finite normalized FH frequencies.");
end
frequencyOffsets = unique([0, frequencyOffsets], "stable");
end

function [g, mainTap] = local_design_linear_equalizer(h, Leq, delay, lambda)
Lh = numel(h);
H = toeplitz([h(:); zeros(Leq - 1, 1)], [h(1); zeros(Leq - 1, 1)]);
target = zeros(Lh + Leq - 1, 1);
target(delay + 1) = 1;

A = (H' * H) + lambda * eye(Leq);
b = H' * target;
g = A \ b;
if any(~isfinite(g))
    error("Designed multipath equalizer contains non-finite coefficients.");
end

c = H * g;
mainTap = c(delay + 1);
if abs(mainTap) <= 1e-12
    error("Multipath equalizer main tap collapsed to zero.");
end
g = g / mainTap;
c = c / mainTap;
mainTap = c(delay + 1);
end

function idx = local_frequency_bank_index(frequencyOffsets, targetFreq)
[err, idx] = min(abs(double(frequencyOffsets(:)) - double(targetFreq)));
if isempty(idx) || err > 1e-10
    error("Equalizer bank does not contain normalized frequency %.12g.", targetFreq);
end
end
