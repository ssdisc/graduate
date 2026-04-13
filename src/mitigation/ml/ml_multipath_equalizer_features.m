function [X, baselineOut] = ml_multipath_equalizer_features(rx, freqBySymbol, hBank, bankFreqs, N0, model)
%ML_MULTIPATH_EQUALIZER_FEATURES  Build per-symbol features for the offline multipath equalizer.

arguments
    rx (:,1)
    freqBySymbol (:,1) double
    hBank (:,:) double
    bankFreqs (:,1) double
    N0 (1,1) double {mustBeNonnegative}
    model (1,1) struct
end

if ~(isfield(model, "eqLen") && isfield(model, "channelLen") && isfield(model, "delay"))
    error("ML multipath equalizer model must define eqLen, channelLen and delay.");
end
eqLen = round(double(model.eqLen));
channelLen = round(double(model.channelLen));
delay = round(double(model.delay));
if ~(eqLen >= 1 && channelLen >= 1 && delay >= 0)
    error("Invalid ML multipath equalizer dimensions.");
end

rx = rx(:);
N = numel(rx);
freqBySymbol = double(freqBySymbol(:));
if numel(freqBySymbol) ~= N
    error("freqBySymbol length %d does not match rx length %d.", numel(freqBySymbol), N);
end
if size(hBank, 1) ~= channelLen
    error("hBank row count %d does not match model.channelLen=%d.", size(hBank, 1), channelLen);
end
if size(hBank, 2) ~= numel(bankFreqs)
    error("hBank column count must match bankFreqs length.");
end
if any(~isfinite(freqBySymbol)) || any(~isfinite(bankFreqs))
    error("Frequency features must be finite.");
end

nFeatures = 2 * eqLen + 2 * channelLen + 7;
X = zeros(N, nFeatures);
baselineOut = complex(zeros(N, 1));
bankIdx = local_bank_indices(bankFreqs, freqBySymbol);
gBank = local_baseline_equalizer_bank(hBank, N0, eqLen, delay, model);

for n = 1:N
    window = complex(zeros(eqLen, 1));
    for tap = 1:eqLen
        srcIdx = n + delay - tap + 1;
        if srcIdx >= 1 && srcIdx <= N
            window(tap) = rx(srcIdx);
        end
    end
    h = hBank(:, bankIdx(n));
    g = gBank(:, bankIdx(n));
    freq = freqBySymbol(n);
    winPow = mean(abs(window).^2);
    baseline = sum(g(:) .* window(:));
    baselineOut(n) = baseline;
    X(n, :) = [ ...
        real(window(:)).', imag(window(:)).', ...
        real(h(:)).', imag(h(:)).', ...
        freq, abs(freq), freq.^2, log10(double(N0) + eps), log10(winPow + eps), ...
        real(baseline), imag(baseline)];
end

if isfield(model, "inputChannels") && size(X, 2) ~= double(model.inputChannels)
    error("Built %d features, model expects %d.", size(X, 2), model.inputChannels);
end
end

function gBank = local_baseline_equalizer_bank(hBank, N0, eqLen, delay, model)
if ~(isfield(model, "baselineLambdaFactor") && ~isempty(model.baselineLambdaFactor))
    error("ML multipath equalizer model must define baselineLambdaFactor.");
end
lambdaFactor = double(model.baselineLambdaFactor);
if ~(isscalar(lambdaFactor) && isfinite(lambdaFactor) && lambdaFactor >= 0)
    error("model.baselineLambdaFactor must be a finite nonnegative scalar.");
end
lambda = lambdaFactor * double(N0);
gBank = complex(zeros(eqLen, size(hBank, 2)));
for k = 1:size(hBank, 2)
    gBank(:, k) = local_design_linear_equalizer(hBank(:, k), eqLen, delay, lambda);
end
end

function g = local_design_linear_equalizer(h, eqLen, delay, lambda)
H = toeplitz([h(:); zeros(eqLen - 1, 1)], [h(1); zeros(eqLen - 1, 1)]);
d = zeros(size(H, 1), 1);
tapIdx = delay + 1;
if tapIdx > numel(d)
    error("Invalid baseline equalizer delay %d for response length %d.", delay, numel(d));
end
d(tapIdx) = 1;
g = (H' * H + lambda * eye(eqLen)) \ (H' * d);
c = H * g;
mainTap = c(tapIdx);
if abs(mainTap) <= 1e-12
    error("Baseline ML feature equalizer main tap collapsed to zero.");
end
g = g / mainTap;
if any(~isfinite(g))
    error("Baseline ML feature equalizer contains non-finite coefficients.");
end
end

function bankIdx = local_bank_indices(bankFreqs, freqBySymbol)
bankFreqs = double(bankFreqs(:));
freqBySymbol = double(freqBySymbol(:));
bankIdx = zeros(numel(freqBySymbol), 1);
tol = 1e-10;
for k = 1:numel(freqBySymbol)
    [err, idx] = min(abs(bankFreqs - freqBySymbol(k)));
    if isempty(idx) || err > tol
        error("ML equalizer bank does not contain normalized frequency %.12g.", freqBySymbol(k));
    end
    bankIdx(k) = idx;
end
end
