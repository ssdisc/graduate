function [eq, ok] = multipath_equalizer_from_preamble(txPreamble, rxPreamble, cfg, N0, channelLenSymbols)
%MULTIPATH_EQUALIZER_FROM_PREAMBLE  Estimate a short multipath channel from a known preamble
%and design a linear FFE equalizer (ZF or MMSE).
%
% This helper is intentionally lightweight (no toolbox dependency) and is meant for
% symbol-rate processing after matched filtering / coarse sync.
%
% Inputs:
%   txPreamble        - known transmitted preamble symbols (column)
%   rxPreamble        - received preamble symbols (column), aligned to txPreamble start
%   cfg               - config struct (optional)
%       .method       - "mmse" (default) | "zf"
%       .nTaps        - equalizer length (default 9)
%       .lambdaFactor - MMSE regularization factor (default 1.0), lambda=lambdaFactor*N0
%   N0                - noise power (complex variance) used for MMSE regularization
%   channelLenSymbols - assumed channel length in symbols (>=1)
%
% Outputs:
%   eq - equalizer struct
%       .enabled/.method/.hEst/.g/.delay/.channelLen/.eqLen/.lambda/.mainTap
%   ok - true if design succeeded

arguments
    txPreamble (:,1) double
    rxPreamble (:,1) double
    cfg (1,1) struct = struct()
    N0 (1,1) double {mustBeNonnegative} = 0
    channelLenSymbols (1,1) double {mustBePositive} = 1
end

eq = struct();
eq.enabled = false;
ok = false;

% Defaults
method = "mmse";
if isfield(cfg, "method") && strlength(string(cfg.method)) > 0
    method = lower(string(cfg.method));
end
nTaps = 9;
if isfield(cfg, "nTaps") && ~isempty(cfg.nTaps)
    nTaps = max(1, round(double(cfg.nTaps)));
end
lambdaFactor = 1.0;
if isfield(cfg, "lambdaFactor") && ~isempty(cfg.lambdaFactor)
    lambdaFactor = max(0, double(cfg.lambdaFactor));
end

tx = txPreamble(:);
rx = rxPreamble(:);
L = min(numel(tx), numel(rx));
if L < 8
    return;
end
tx = tx(1:L);
rx = rx(1:L);

Lh = max(1, round(double(channelLenSymbols)));
Leq = max(Lh, nTaps);
delay = Lh - 1;

% --- Channel estimate h via LS: y ~= x (*) h ---
Xfull = toeplitz([tx; zeros(Lh - 1, 1)], [tx(1); zeros(Lh - 1, 1)]);
X = Xfull(1:L, :);
try
    hEst = X \ rx;
catch
    return;
end
if any(~isfinite(hEst))
    return;
end

% --- Equalizer design g: minimize ||conv(h,g)-delta||^2 (+ lambda||g||^2) ---
H = toeplitz([hEst; zeros(Leq - 1, 1)], [hEst(1); zeros(Leq - 1, 1)]);
target = zeros(Lh + Leq - 1, 1);
target(delay + 1) = 1;

lambda = 0;
if method == "mmse"
    lambda = lambdaFactor * N0;
elseif method == "zf"
    lambda = 0;
else
    error("Unsupported equalizer method: %s", string(method));
end

A = (H' * H) + lambda * eye(Leq);
b = H' * target;
g = A \ b;

if any(~isfinite(g))
    return;
end

% Normalize to keep the main tap close to 1 (helps soft-metric scaling).
c = H * g;
mainTap = c(delay + 1);
if abs(mainTap) > 1e-12
    g = g / mainTap;
    c = c / mainTap;
end

eq.enabled = true;
eq.method = method;
eq.hEst = hEst;
eq.g = g;
eq.delay = delay;
eq.channelLen = Lh;
eq.eqLen = Leq;
eq.lambda = lambda;
eq.mainTap = c(delay + 1);
ok = true;

end
