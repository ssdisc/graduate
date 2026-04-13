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
%       .method           - "mmse" | "zf" | "ml_ridge" | "ml_mlp"
%       .nTaps            - FFE length in symbols
%       .lambdaFactor     - MMSE regularization, lambda=lambdaFactor*N0
%       .frequencyOffsets - hop frequencies to support, normalized to Rs
%       .mlRidge          - online supervised ridge equalizer config
%       .mlMlp            - offline trained symbol-domain MLP equalizer
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
    if ~any(method == ["ml_ridge" "ml_mlp"])
        error("Unsupported equalizer method: %s", string(method));
    end
end
nTaps = local_required_positive_integer_field(cfg, "nTaps");
lambdaFactor = local_required_nonnegative_scalar_field(cfg, "lambdaFactor");
frequencyOffsets = local_frequency_offsets_from_cfg(cfg);
mlRidgeCfg = local_ml_ridge_cfg(cfg, method);
mlMlpModel = local_ml_mlp_model(cfg, method);

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
if method == "ml_mlp"
    if double(mlMlpModel.eqLen) ~= Leq || double(mlMlpModel.channelLen) ~= Lh || double(mlMlpModel.delay) ~= delay
        error("rxSync.multipathEq.mlMlp dimensions do not match current equalizer: model(eqLen=%d, channelLen=%d, delay=%d), current(%d,%d,%d).", ...
            double(mlMlpModel.eqLen), double(mlMlpModel.channelLen), double(mlMlpModel.delay), Leq, Lh, delay);
    end
end

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
elseif method == "ml_ridge"
    lambda = mlRidgeCfg.lambdaFactor * N0 + mlRidgeCfg.ridgeFloor;
end
if ~(isscalar(lambda) && isfinite(lambda) && lambda >= 0)
    error("Equalizer regularization lambda must be finite and nonnegative, got %g.", lambda);
end

gBank = complex(zeros(Leq, numel(frequencyOffsets)));
mainTaps = complex(zeros(1, numel(frequencyOffsets)));
hBank = complex(zeros(Lh, numel(frequencyOffsets)));
for k = 1:numel(frequencyOffsets)
    hNow = hEst .* exp(-1j * 2 * pi * double(frequencyOffsets(k)) * symbolDelays);
    if method == "ml_mlp"
        gNow = complex(zeros(Leq, 1));
        mainTapNow = complex(1, 0);
    elseif method == "ml_ridge"
        if abs(double(frequencyOffsets(k))) <= 1e-10
            rxTrain = rx;
        else
            rxTrain = filter(hNow, 1, tx);
        end
        [gNow, mainTapNow] = local_train_ml_ridge_equalizer(tx, rxTrain, hNow, Leq, delay, lambda);
    else
        [gNow, mainTapNow] = local_design_linear_equalizer(hNow, Leq, delay, lambda);
    end
    hBank(:, k) = hNow;
    gBank(:, k) = gNow;
    mainTaps(k) = mainTapNow;
end

eq.enabled = true;
eq.method = method;
eq.hEst = hEst;
eq.hBank = hBank;
if method == "ml_mlp"
    eq.g = complex(zeros(Leq, 1));
    eq.mlMlp = mlMlpModel;
    eq.mlMlpBlend = local_ml_mlp_preamble_blend(tx, rx, hBank, frequencyOffsets, N0, mlMlpModel);
else
    eq.g = gBank(:, local_frequency_bank_index(frequencyOffsets, 0));
end
eq.gBank = gBank;
eq.delay = delay;
eq.channelLen = Lh;
eq.eqLen = Leq;
eq.lambda = lambda;
eq.mainTap = mainTaps(local_frequency_bank_index(frequencyOffsets, 0));
eq.mainTaps = mainTaps;
eq.frequencyOffsets = frequencyOffsets;
eq.symbolDelays = symbolDelays;
eq.N0 = N0;
ok = true;

end

function blend = local_ml_mlp_preamble_blend(tx, rx, hBank, frequencyOffsets, N0, model)
freqPre = zeros(numel(rx), 1);
[yMl, info] = ml_predict_multipath_equalizer_symbols(rx, freqPre, hBank, double(frequencyOffsets(:)), double(N0), model);
if ~(isfield(info, "baseline") && numel(info.baseline) == numel(yMl))
    error("ML MLP preamble validation requires baseline predictions.");
end
tx = tx(:);
L = min([numel(tx), numel(yMl), numel(info.baseline)]);
if L < 1
    error("ML MLP preamble validation has no samples.");
end
mseMl = mean(abs(yMl(1:L) - tx(1:L)).^2);
mseBase = mean(abs(info.baseline(1:L) - tx(1:L)).^2);
if ~(isfinite(mseMl) && isfinite(mseBase))
    error("ML MLP preamble validation produced non-finite MSE.");
end
minGain = local_model_nonnegative_scalar(model, "preambleGateMinGain");
if minGain <= 0
    preambleBlend = double(mseMl <= mseBase);
else
    preambleBlend = max(0, min(1, (mseBase - mseMl) / max(mseBase, eps) / minGain));
end
blend = preambleBlend * local_ml_mlp_preamble_snr_blend(tx, rx, hBank, frequencyOffsets, model);
end

function blend = local_ml_mlp_preamble_snr_blend(tx, rx, hBank, frequencyOffsets, model)
snrMinDb = local_model_finite_scalar(model, "residualSnrMinDb");
snrFullDb = local_model_finite_scalar(model, "residualSnrFullDb");
if snrFullDb <= snrMinDb
    error("rxSync.multipathEq.mlMlp.residualSnrFullDb must be greater than residualSnrMinDb.");
end
idx0 = local_frequency_bank_index(frequencyOffsets, 0);
hBase = hBank(:, idx0);
tx = tx(:);
rx = rx(:);
L = min(numel(tx), numel(rx));
Xfull = toeplitz([tx(1:L); zeros(numel(hBase) - 1, 1)], [tx(1); zeros(numel(hBase) - 1, 1)]);
fit = Xfull(1:L, :) * hBase(:);
err = rx(1:L) - fit;
signalPower = mean(abs(fit).^2);
noisePower = mean(abs(err).^2);
snrDb = 10 * log10(max(signalPower, eps) / max(noisePower, eps));
if ~isfinite(snrDb)
    error("ML MLP preamble SNR gate produced a non-finite SNR.");
end
if snrDb <= snrMinDb
    blend = 0;
elseif snrDb >= snrFullDb
    blend = 1;
else
    blend = (snrDb - snrMinDb) / (snrFullDb - snrMinDb);
end
end

function value = local_model_nonnegative_scalar(model, fieldName)
if ~(isfield(model, fieldName) && ~isempty(model.(fieldName)))
    error("rxSync.multipathEq.mlMlp.%s is required.", fieldName);
end
value = double(model.(fieldName));
if ~(isscalar(value) && isfinite(value) && value >= 0)
    error("rxSync.multipathEq.mlMlp.%s must be a finite nonnegative scalar.", fieldName);
end
end

function value = local_model_finite_scalar(model, fieldName)
if ~(isfield(model, fieldName) && ~isempty(model.(fieldName)))
    error("rxSync.multipathEq.mlMlp.%s is required.", fieldName);
end
value = double(model.(fieldName));
if ~(isscalar(value) && isfinite(value))
    error("rxSync.multipathEq.mlMlp.%s must be a finite scalar.", fieldName);
end
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

function mlRidgeCfg = local_ml_ridge_cfg(cfg, method)
mlRidgeCfg = struct("lambdaFactor", 0, "ridgeFloor", 0);
if method ~= "ml_ridge"
    return;
end
if ~(isfield(cfg, "mlRidge") && isstruct(cfg.mlRidge))
    error("rxSync.multipathEq.mlRidge is required for method='ml_ridge'.");
end
mlRidgeCfg.lambdaFactor = local_required_nonnegative_scalar_field(cfg.mlRidge, "lambdaFactor");
mlRidgeCfg.ridgeFloor = local_required_nonnegative_scalar_field(cfg.mlRidge, "ridgeFloor");
end

function model = local_ml_mlp_model(cfg, method)
model = struct();
if method ~= "ml_mlp"
    return;
end
if ~(isfield(cfg, "mlMlp") && isstruct(cfg.mlMlp))
    error("rxSync.multipathEq.mlMlp is required for method='ml_mlp'.");
end
model = cfg.mlMlp;
if ~(isfield(model, "type") && string(model.type) == "multipath_equalizer_symbol_mlp")
    error("rxSync.multipathEq.mlMlp must be a multipath_equalizer_symbol_mlp model.");
end
if ~(isfield(model, "trained") && logical(model.trained))
    error("rxSync.multipathEq.mlMlp must be trained before method='ml_mlp' can be used.");
end
if ~(isfield(model, "outputMode") && string(model.outputMode) == "mmse_residual")
    error("rxSync.multipathEq.mlMlp must use outputMode='mmse_residual'.");
end
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

function [g, mainTap] = local_train_ml_ridge_equalizer(tx, rxTrain, h, Leq, delay, lambda)
tx = tx(:);
rxTrain = rxTrain(:);
L = min(numel(tx), numel(rxTrain));
if L < Leq + delay + 1
    error("ML ridge equalizer needs at least %d training symbols, got %d.", Leq + delay + 1, L);
end
tx = tx(1:L);
rxTrain = rxTrain(1:L);

X = complex(zeros(L, Leq));
for n = 1:L
    for tap = 1:Leq
        srcIdx = n + delay - tap + 1;
        if srcIdx >= 1 && srcIdx <= L
            X(n, tap) = rxTrain(srcIdx);
        end
    end
end

A = (X' * X) + lambda * eye(Leq);
b = X' * tx;
g = A \ b;
if any(~isfinite(g))
    error("ML ridge equalizer contains non-finite coefficients.");
end

H = toeplitz([h(:); zeros(Leq - 1, 1)], [h(1); zeros(Leq - 1, 1)]);
c = H * g;
mainTap = c(delay + 1);
if abs(mainTap) <= 1e-12
    error("ML ridge equalizer main tap collapsed to zero.");
end
end

function idx = local_frequency_bank_index(frequencyOffsets, targetFreq)
[err, idx] = min(abs(double(frequencyOffsets(:)) - double(targetFreq)));
if isempty(idx) || err > 1e-10
    error("Equalizer bank does not contain normalized frequency %.12g.", targetFreq);
end
end
