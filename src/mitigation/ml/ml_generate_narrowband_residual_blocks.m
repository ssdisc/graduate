function dataset = ml_generate_narrowband_residual_blocks(p, nBlocks, blockLen, opts)
%ML_GENERATE_NARROWBAND_RESIDUAL_BLOCKS Build supervised residual-CNN blocks.

arguments
    p (1,1) struct
    nBlocks (1,1) double {mustBeInteger, mustBePositive}
    blockLen (1,1) double {mustBeInteger, mustBePositive}
    opts.ebN0dBRange (1,2) double = [4 10]
    opts.jsrDbRange (1,2) double = [-1 3]
    opts.centerFreqPointsList double = -3:0.5:3
    opts.bandwidthFreqPointsList double = 1.0
    opts.targetClipNorm (1,1) double {mustBePositive} = 2.0
    opts.errorWeightSlope (1,1) double {mustBeNonnegative} = 2.0
    opts.verbose (1,1) logical = true
end

waveform = resolve_waveform_cfg(p);
if ~(isfield(p, "fh") && isstruct(p.fh) && isfield(p.fh, "enable") && logical(p.fh.enable))
    error("ml_generate_narrowband_residual_blocks requires p.fh.enable=true.");
end

centers = double(opts.centerFreqPointsList(:));
bandwidths = double(opts.bandwidthFreqPointsList(:));
if isempty(centers) || any(~isfinite(centers))
    error("centerFreqPointsList must contain finite values.");
end
if isempty(bandwidths) || any(~isfinite(bandwidths) | bandwidths <= 0)
    error("bandwidthFreqPointsList must contain positive finite values.");
end

dataset = struct();
dataset.nBlocks = nBlocks;
dataset.blockLen = blockLen;
dataset.inputFeatures = cell(nBlocks, 1);
dataset.targetResidual = cell(nBlocks, 1);
dataset.sampleWeight = cell(nBlocks, 1);
dataset.scale = zeros(nBlocks, 1);
dataset.centerFreqPoints = zeros(nBlocks, 1);
dataset.bandwidthFreqPoints = zeros(nBlocks, 1);
dataset.ebN0dB = zeros(nBlocks, 1);
dataset.jsrDb = zeros(nBlocks, 1);
dataset.featureNames = ml_narrowband_residual_cnn_model().featureNames;

for b = 1:nBlocks
    center = centers(randi(numel(centers), 1, 1));
    bandwidth = bandwidths(randi(numel(bandwidths), 1, 1));
    ebN0dB = opts.ebN0dBRange(1) + rand() * diff(opts.ebN0dBRange);
    jsrDb = opts.jsrDbRange(1) + rand() * diff(opts.jsrDbRange);

    txSym = local_random_qpsk_local(blockLen);
    [txHopped, hopInfo] = fh_modulate(txSym, p.fh);
    txSample = pulse_tx_from_symbol_rate(txHopped, waveform);
    signalPower = mean(abs(txSample).^2);
    if ~(isfinite(signalPower) && signalPower > 0)
        error("Generated training signal has invalid power.");
    end

    pBlock = local_training_channel_local(p, center, bandwidth, signalPower, jsrDb);
    channelSample = adapt_channel_for_sps(pBlock.channel, waveform, pBlock.fh);
    N0 = signalPower * 10^(-ebN0dB / 10);
    rxSample = channel_bg_impulsive(txSample, N0, channelSample);
    rxHopped = pulse_rx_to_symbol_rate(rxSample, waveform);
    rxHopped = local_fit_complex_length_local(rxHopped, numel(txHopped));
    rxSym = fh_demodulate(rxHopped, hopInfo);

    pkt = struct("hopInfo", hopInfo);
    [rxExcised, ~] = narrowband_profile_frontend(rxSym, pkt, p, "narrowband_subband_excision_soft");
    rxExcised = local_fit_complex_length_local(rxExcised, blockLen);

    [features, scale] = ml_narrowband_residual_features(rxExcised);
    target = (txSym(:) - rxExcised(:)) ./ scale;
    targetAbs = abs(target);
    clipNorm = double(opts.targetClipNorm);
    over = targetAbs > clipNorm;
    if any(over)
        target(over) = target(over) .* (clipNorm ./ max(targetAbs(over), eps));
        targetAbs(over) = clipNorm;
    end
    weight = 1 + double(opts.errorWeightSlope) * min(targetAbs, clipNorm) ./ clipNorm;

    dataset.inputFeatures{b} = features;
    dataset.targetResidual{b} = [real(target(:)).'; imag(target(:)).'];
    dataset.sampleWeight{b} = reshape(weight, 1, []);
    dataset.scale(b) = scale;
    dataset.centerFreqPoints(b) = center;
    dataset.bandwidthFreqPoints(b) = bandwidth;
    dataset.ebN0dB(b) = ebN0dB;
    dataset.jsrDb(b) = jsrDb;
end

if opts.verbose
    fprintf("Narrowband residual dataset generated: %d blocks, blockLen=%d.\n", nBlocks, blockLen);
end
end

function pBlock = local_training_channel_local(p, center, bandwidth, signalPower, jsrDb)
pBlock = p;
pBlock.channel.impulseProb = 0;
pBlock.channel.impulseToBgRatio = 0;
pBlock.channel.impulseWeight = 0;
pBlock.channel.singleTone.enable = false;
pBlock.channel.sweep.enable = false;
pBlock.channel.syncImpairment.enable = false;
pBlock.channel.multipath.enable = false;
pBlock.channel.multipath.rayleigh = false;
pBlock.channel.narrowband.enable = true;
pBlock.channel.narrowband.weight = 1.0;
pBlock.channel.narrowband.centerFreqPoints = double(center);
pBlock.channel.narrowband.bandwidthFreqPoints = double(bandwidth);
pBlock.channel.narrowband.power = double(signalPower) * 10^(double(jsrDb) / 10);
end

function sym = local_random_qpsk_local(nSym)
bits = randi([0 1], 2 * nSym, 1, "uint8");
bI = bits(1:2:end);
bQ = bits(2:2:end);
sym = (1 - 2 * double(bI) + 1j * (1 - 2 * double(bQ))) / sqrt(2);
sym = sym(:);
end

function y = local_fit_complex_length_local(x, targetLen)
x = x(:);
targetLen = max(0, round(double(targetLen)));
if numel(x) >= targetLen
    y = x(1:targetLen);
else
    y = [x; complex(zeros(targetLen - numel(x), 1))];
end
end
