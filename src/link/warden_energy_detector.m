function m = warden_energy_detector(txBurst, N0, ch, maxDelaySymbols, det)
%WARDEN_ENERGY_DETECTOR  Radiometer (energy detector) Pd/Pfa estimate.
%
% txBurst: transmitted symbols (no leading delay), column vector.
% N0: noise spectral density used by channel_bg_impulsive().
% ch: channel config used by channel_bg_impulsive().
% maxDelaySymbols: random leading-zero delay range [0, maxDelaySymbols].
% det: struct with fields:
%   - pfaTarget (0..1)
%   - nObs (observation window length in symbols)
%   - nTrials (Monte Carlo trials)

arguments
    txBurst (:,1) double
    N0 (1,1) double {mustBePositive}
    ch (1,1) struct
    maxDelaySymbols (1,1) double {mustBeNonnegative}
    det (1,1) struct
end

if ~isfield(det, "pfaTarget"); det.pfaTarget = 0.01; end
if ~isfield(det, "nObs"); det.nObs = 4096; end
if ~isfield(det, "nTrials"); det.nTrials = 200; end

pfaTarget = double(det.pfaTarget);
nObs = double(det.nObs);
nTrials = double(det.nTrials);

if ~(pfaTarget > 0 && pfaTarget < 1)
    error("pfaTarget must be in (0,1).");
end
if ~(nObs >= 16)
    error("nObs must be >= 16.");
end
if ~(nTrials >= 10)
    error("nTrials must be >= 10.");
end

txBurst = txBurst(:);
L = min(nObs, numel(txBurst) + maxDelaySymbols);

T0 = zeros(nTrials, 1);
T1 = zeros(nTrials, 1);

for i = 1:nTrials
    delay = randi([0, maxDelaySymbols], 1, 1);

    txWin = zeros(L, 1);
    if delay < L
        nSig = min(numel(txBurst), L - delay);
        if nSig > 0
            txWin(delay+1:delay+nSig) = txBurst(1:nSig);
        end
    end

    r0 = channel_bg_impulsive(zeros(L, 1), N0, ch);
    r1 = channel_bg_impulsive(txWin, N0, ch);

    T0(i) = mean(abs(r0).^2);
    T1(i) = mean(abs(r1).^2);
end

T0s = sort(T0);
q = 1 - pfaTarget;
idx = max(1, min(nTrials, ceil(q * nTrials)));
threshold = T0s(idx);

pfaEst = mean(T0 > threshold);
pdEst = mean(T1 > threshold);
peEst = 0.5 * (pfaEst + 1 - pdEst);

m = struct();
m.pfaTarget = pfaTarget;
m.nObs = L;
m.nTrials = nTrials;
m.threshold = threshold;
m.pfaEst = pfaEst;
m.pdEst = pdEst;
m.peEst = peEst;
end

