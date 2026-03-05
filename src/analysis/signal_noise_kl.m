function [klSN, klNS, klSymVal] = signal_noise_kl(sig, N0, nBins)
% 比较跳频信号幅度分布与背景噪声幅度（Rayleigh）分布。
sig = sig(:);
if isempty(sig) || ~isfinite(N0) || N0 <= 0
    klSN = NaN;
    klNS = NaN;
    klSymVal = NaN;
    return;
end

magSig = abs(double(sig));
if all(~isfinite(magSig))
    klSN = NaN;
    klNS = NaN;
    klSymVal = NaN;
    return;
end
magSig = magSig(isfinite(magSig));
if isempty(magSig)
    klSN = NaN;
    klNS = NaN;
    klSymVal = NaN;
    return;
end

sigma = sqrt(max(double(N0), eps) / 2);
rMax = max(max(magSig) * 1.05, 6 * sigma);
if ~isfinite(rMax) || rMax <= 0
    klSN = NaN;
    klNS = NaN;
    klSymVal = NaN;
    return;
end

nBins = max(16, round(double(nBins)));
edges = linspace(0, rMax, nBins + 1);
pSig = histcounts(magSig, edges, "Normalization", "probability");

centers = 0.5 * (edges(1:end-1) + edges(2:end));
binWidth = diff(edges);
pNoisePdf = (centers ./ (sigma.^2)) .* exp(-(centers.^2) ./ (2 * sigma.^2));
pNoise = pNoisePdf .* binWidth;

epsProb = 1e-12;
pSig = pSig + epsProb;
pNoise = pNoise + epsProb;
pSig = pSig / sum(pSig);
pNoise = pNoise / sum(pNoise);

klSN = sum(pSig .* log(pSig ./ pNoise));
klNS = sum(pNoise .* log(pNoise ./ pSig));
klSymVal = 0.5 * (klSN + klNS);
end
