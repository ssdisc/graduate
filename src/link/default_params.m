function p = default_params()
%DEFAULT_PARAMS  Default parameter set for Track 1 baseline link.

p = struct();

p.rngSeed = 1;

% Source (image)
p.source = struct();
p.source.useBuiltinImage = true;
p.source.imagePath = ""; % used when useBuiltinImage=false
p.source.resizeTo = [128 128]; % [rows cols], [] to keep original
p.source.grayscale = true;

% Payload format (raw bytes from image)
p.payload = struct();
p.payload.bitsPerPixel = 8;

% Preamble / frame
p.frame = struct();
p.frame.preambleLength = 127; % bits (BPSK), PN sequence
p.frame.magic16 = hex2dec('A55A');

% Scrambling (acts as whitening/encryption-lite)
p.scramble = struct();
p.scramble.enable = true;
p.scramble.pnPolynomial = [1 0 0 1 1]; % x^4 + x + 1
p.scramble.pnInit = [0 0 0 1];         % nonzero init

% Channel coding (convolutional, rate 1/2)
p.fec = struct();
p.fec.trellis = poly2trellis(7, [171 133]);
p.fec.tracebackDepth = 34;
p.fec.opmode = 'trunc'; % 'trunc' for simplicity
p.fec.decisionType = 'soft'; % 'hard' | 'soft'
p.fec.softBits = 3; % nsdec in vitdec (1..13), used when decisionType='soft'

% Interleaving (block interleaver)
p.interleaver = struct();
p.interleaver.enable = true;
p.interleaver.nRows = 64;

% Modulation
p.mod = struct();
p.mod.type = 'BPSK';

% Channel: AWGN + Bernoulli-Gaussian impulsive noise
p.channel = struct();
p.channel.maxDelaySymbols = 200; % random leading zeros to test frame sync
p.channel.impulseProb = 0.01;    % probability of impulse on each symbol
p.channel.impulseToBgRatio = 50; % impulse variance = ratio * background variance

% Impulse mitigation
p.mitigation = struct();
p.mitigation.methods = ["none" "blanking" "clipping" "ml_blanking" "ml_cnn" "ml_gru"]; % run & compare
p.mitigation.thresholdStrategy = "median"; % "median" | "fixed"
p.mitigation.thresholdAlpha = 4.0; % T = alpha * median(abs(r))
p.mitigation.thresholdFixed = 3.0; % used when thresholdStrategy="fixed"
p.mitigation.ml = ml_impulse_lr_model();      % Legacy LR model
p.mitigation.mlCnn = ml_cnn_impulse_model();  % 1D CNN model (untrained default)
p.mitigation.mlGru = ml_gru_impulse_model();  % GRU model (untrained default)

% Soft metric quantization (for vitdec 'soft')
p.softMetric = struct();
p.softMetric.clipA = 4.0; % clip real(symbol) to [-A, A] before quantization

% Simulation
p.sim = struct();
p.sim.ebN0dBList = 0:2:10;
p.sim.nFramesPerPoint = 1;
p.sim.saveFigures = true;
p.sim.resultsDir = fullfile(pwd, "results");

% Eavesdropper / interceptor (Eve)
p.eve = struct();
p.eve.enable = true;
% Eve Eb/N0 = Bob Eb/N0 + offset (dB). Negative => Eve has worse channel.
p.eve.ebN0dBOffset = -6;
% Eve receiver knowledge model:
%   "known"     : knows scrambling key (best-case intercept)
%   "none"      : ignores scrambling (no descrambling)
%   "wrong_key" : uses a wrong scrambling key (shows garbled image)
p.eve.scrambleAssumption = "wrong_key";

% Covert / LPD support (warden detection)
p.covert = struct();
p.covert.enable = true;
p.covert.warden = struct();
p.covert.warden.enable = true;
% Energy detector (radiometer) settings at the adversary
p.covert.warden.pfaTarget = 0.01;
p.covert.warden.nObs = 4096;   % observation window (symbols)
p.covert.warden.nTrials = 200; % Monte Carlo trials for Pd/Pfa estimate

end
