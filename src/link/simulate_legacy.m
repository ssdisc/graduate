function results = simulate_legacy(p)
%SIMULATE  End-to-end link simulation with impulsive-noise mitigation.
%
% Returns a struct containing BER/PSNR/PSD results and saves figures when enabled.

arguments
    p (1,1) struct
end

rng(p.rngSeed);

set(0, 'DefaultFigureVisible', 'off');

imgTx = load_source_image(p.source);
[payloadBits, meta] = image_to_payload_bits(imgTx, p.payload);

[preambleBits, preambleSym] = make_preamble(p.frame.preambleLength);
[headerBits, headerStruct] = build_header_bits(meta, p.frame.magic16);

dataBitsTx = [headerBits; payloadBits];
dataBitsTxScr = scramble_bits(dataBitsTx, p.scramble);

codedBits = fec_encode(dataBitsTxScr, p.fec);
[codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);

[dataSymTx, modInfo] = modulate_bits(codedBitsInt, p.mod);

txSym = [preambleSym; dataSymTx];

EbN0dBList = p.sim.ebN0dBList(:).';
methods = string(p.mitigation.methods(:).');

ber = nan(numel(methods), numel(EbN0dBList));
psnrVals = nan(numel(methods), numel(EbN0dBList));
ssimVals = nan(numel(methods), numel(EbN0dBList));

example = struct();

for ie = 1:numel(EbN0dBList)
    EbN0dB = EbN0dBList(ie);
    EbN0 = 10.^(EbN0dB/10);

    nErr = zeros(numel(methods), 1);
    nTot = zeros(numel(methods), 1);
    psnrAcc = zeros(numel(methods), 1);
    ssimAcc = zeros(numel(methods), 1);
    nPsnr = zeros(numel(methods), 1);
    nSsim = zeros(numel(methods), 1);

    for frameIdx = 1:p.sim.nFramesPerPoint
        delay = randi([0, p.channel.maxDelaySymbols], 1, 1);
        tx = [zeros(delay, 1); txSym];

        N0 = ebn0_to_n0(EbN0, modInfo.codeRate, modInfo.bitsPerSymbol, 1.0);
        rx = channel_bg_impulsive(tx, N0, p.channel);

        startIdx = frame_sync(rx, preambleSym);
        if isempty(startIdx)
            % If sync fails, count as all-bits error for this frame
            for im = 1:numel(methods)
                nErr(im) = nErr(im) + numel(payloadBits);
                nTot(im) = nTot(im) + numel(payloadBits);
            end
            continue;
        end

        dataStart = startIdx + numel(preambleSym);
        dataStop = dataStart + numel(dataSymTx) - 1;
        if dataStop > numel(rx)
            for im = 1:numel(methods)
                nErr(im) = nErr(im) + numel(payloadBits);
                nTot(im) = nTot(im) + numel(payloadBits);
            end
            continue;
        end

        rData = rx(dataStart:dataStop);

        for im = 1:numel(methods)
            rMit = mitigate_impulses(rData, methods(im), p.mitigation);

            demodSoft = demodulate_to_softbits(rMit, p.mod, p.fec, p.softMetric);
            demodDeint = deinterleave_bits(demodSoft, intState, p.interleaver);

            dataBitsRxScr = fec_decode(demodDeint, p.fec);
            dataBitsRx = descramble_bits(dataBitsRxScr, p.scramble);

            [payloadBitsRx, metaRx, okHeader] = parse_frame_bits(dataBitsRx, p.frame.magic16);
            if ~okHeader
                nErr(im) = nErr(im) + numel(payloadBits);
                nTot(im) = nTot(im) + numel(payloadBits);
                continue;
            end

            payloadBitsRx = payloadBitsRx(1:min(end, numel(payloadBits)));
            payloadBitsTxTrunc = payloadBits(1:numel(payloadBitsRx));

            nErr(im) = nErr(im) + sum(payloadBitsRx ~= payloadBitsTxTrunc);
            nTot(im) = nTot(im) + numel(payloadBitsTxTrunc);

            imgRx = payload_bits_to_image(payloadBitsRx, metaRx);

            [psnrNow, ssimNow] = image_quality(imgTx, imgRx);
            if isfinite(psnrNow)
                psnrAcc(im) = psnrAcc(im) + psnrNow;
                nPsnr(im) = nPsnr(im) + 1;
            end
            if isfinite(ssimNow)
                ssimAcc(im) = ssimAcc(im) + ssimNow;
                nSsim(im) = nSsim(im) + 1;
            end

            if frameIdx == 1 && ie == ceil(numel(EbN0dBList)/2)
                example.(methods(im)).EbN0dB = EbN0dB;
                example.(methods(im)).imgRx = imgRx;
            end
        end
    end

    ber(:, ie) = nErr ./ max(nTot, 1);

    psnrOut = nan(numel(methods), 1);
    ssimOut = nan(numel(methods), 1);
    validPsnr = nPsnr > 0;
    validSsim = nSsim > 0;
    psnrOut(validPsnr) = psnrAcc(validPsnr) ./ nPsnr(validPsnr);
    ssimOut(validSsim) = ssimAcc(validSsim) ./ nSsim(validSsim);
    psnrVals(:, ie) = psnrOut;
    ssimVals(:, ie) = ssimOut;
end

% Waveform / spectrum (one burst, no channel)
[psd, freqHz, bw99Hz, etaBpsHz] = estimate_spectrum(txSym, modInfo);

results = struct();
results.params = p;
results.ebN0dB = EbN0dBList;
results.methods = methods;
results.ber = ber;
results.psnr = psnrVals;
results.ssim = ssimVals;
results.example = example;
results.spectrum = struct("freqHz", freqHz, "psd", psd, "bw99Hz", bw99Hz, "etaBpsHz", etaBpsHz);

results.summary = make_summary(results);

if p.sim.saveFigures
    outDir = make_results_dir(p.sim.resultsDir);
    save(fullfile(outDir, "results.mat"), "-struct", "results");
    save_figures(outDir, imgTx, results);
end

end

function img = load_source_image(s)
if isfield(s, "useBuiltinImage") && s.useBuiltinImage
    img = imread("cameraman.tif");
else
    if strlength(string(s.imagePath)) == 0
        error("source.imagePath is empty while useBuiltinImage=false.");
    end
    img = imread(s.imagePath);
end

if isfield(s, "grayscale") && s.grayscale && size(img, 3) > 1
    img = rgb2gray(img);
end
img = im2uint8(img);

if isfield(s, "resizeTo") && ~isempty(s.resizeTo)
    img = imresize(img, s.resizeTo);
end
end

function [bits, meta] = image_to_payload_bits(img, payload)
rows = size(img, 1);
cols = size(img, 2);
ch = size(img, 3);

bytes = reshape(uint8(img), [], 1);
bits = uint8vec_to_bits(bytes);

meta = struct();
meta.rows = uint16(rows);
meta.cols = uint16(cols);
meta.channels = uint8(ch);
meta.bitsPerPixel = uint8(payload.bitsPerPixel);
meta.payloadBytes = uint32(numel(bytes));
end

function img = payload_bits_to_image(bits, meta)
bytes = bits_to_uint8vec(bits);
needBytes = double(meta.rows) * double(meta.cols) * double(meta.channels);
if numel(bytes) < needBytes
    bytes(end+1:needBytes, 1) = 0; %#ok<AGROW>
else
    bytes = bytes(1:needBytes);
end
img = reshape(uint8(bytes), double(meta.rows), double(meta.cols), double(meta.channels));
end

function bits = uint8vec_to_bits(bytes)
bytes = uint8(bytes(:));
n = numel(bytes);
bits = false(8*n, 1);
for k = 1:8
    bits(k:8:end) = bitget(bytes, 9-k) ~= 0;
end
bits = uint8(bits);
end

function bytes = bits_to_uint8vec(bits)
bits = uint8(bits(:) ~= 0);
nBits = numel(bits);
nBytes = floor(nBits / 8);
bits = bits(1:8*nBytes);
bits = reshape(bits, 8, nBytes).';
bytes = zeros(nBytes, 1, "uint8");
for k = 1:8
    bytes = bitset(bytes, 9-k, bits(:, k));
end
end

function [preambleBits, preambleSym] = make_preamble(L)
pn = comm.PNSequence( ...
    "Polynomial", [1 0 0 1 1], ...
    "InitialConditions", [0 0 0 1], ...
    "SamplesPerFrame", L);
preambleBits = uint8(pn());
preambleSym = 1 - 2*double(preambleBits);
end

function [headerBits, header] = build_header_bits(meta, magic16)
header = struct();
header.magic = uint16(magic16);
header.rows = meta.rows;
header.cols = meta.cols;
header.channels = meta.channels;
header.bitsPerPixel = meta.bitsPerPixel;
header.payloadBytes = meta.payloadBytes;

fields = [ ...
    uint16_to_bits(header.magic); ...
    uint16_to_bits(header.rows); ...
    uint16_to_bits(header.cols); ...
    uint8_scalar_to_bits(header.channels); ...
    uint8_scalar_to_bits(header.bitsPerPixel); ...
    uint32_to_bits(header.payloadBytes) ...
    ];
headerBits = uint8(fields);
end

function [payloadBits, meta, ok] = parse_frame_bits(rxBits, magic16)
rxBits = uint8(rxBits(:) ~= 0);

needHeaderBits = 16 + 16 + 16 + 8 + 8 + 32;
if numel(rxBits) < needHeaderBits
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end

idx = 1;
magic = bits_to_uint16(rxBits(idx:idx+15)); idx = idx + 16;
if magic ~= uint16(magic16)
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end

rows = bits_to_uint16(rxBits(idx:idx+15)); idx = idx + 16;
cols = bits_to_uint16(rxBits(idx:idx+15)); idx = idx + 16;
channels = bits_to_uint8_scalar(rxBits(idx:idx+7)); idx = idx + 8;
bpp = bits_to_uint8_scalar(rxBits(idx:idx+7)); idx = idx + 8;
payloadBytes = bits_to_uint32(rxBits(idx:idx+31)); idx = idx + 32;

% Basic sanity checks to avoid catastrophic reshape on corrupted headers
if rows == 0 || cols == 0 || rows > 2048 || cols > 2048
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end
if ~(channels == 1 || channels == 3)
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end
if bpp ~= 8
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end
expectedBytes = uint32(rows) * uint32(cols) * uint32(channels);
if payloadBytes ~= expectedBytes
    payloadBits = uint8([]);
    meta = struct();
    ok = false;
    return;
end

meta = struct();
meta.rows = rows;
meta.cols = cols;
meta.channels = channels;
meta.bitsPerPixel = bpp;
meta.payloadBytes = payloadBytes;

payloadBits = rxBits(idx:end);
ok = true;
end

function bits = uint16_to_bits(x)
bits = false(16, 1);
for k = 1:16
    bits(k) = bitget(uint16(x), 17-k) ~= 0;
end
bits = uint8(bits);
end

function bits = uint32_to_bits(x)
bits = false(32, 1);
for k = 1:32
    bits(k) = bitget(uint32(x), 33-k) ~= 0;
end
bits = uint8(bits);
end

function bits = uint8_scalar_to_bits(x)
bits = false(8, 1);
for k = 1:8
    bits(k) = bitget(uint8(x), 9-k) ~= 0;
end
bits = uint8(bits);
end

function x = bits_to_uint16(bits)
bits = uint8(bits(:) ~= 0);
val = uint16(0);
for k = 1:16
    val = bitshift(val, 1);
    val = bitor(val, uint16(bits(k)));
end
x = val;
end

function x = bits_to_uint32(bits)
bits = uint8(bits(:) ~= 0);
val = uint32(0);
for k = 1:32
    val = bitshift(val, 1);
    val = bitor(val, uint32(bits(k)));
end
x = val;
end

function x = bits_to_uint8_scalar(bits)
bits = uint8(bits(:) ~= 0);
val = uint8(0);
for k = 1:8
    val = bitshift(val, 1);
    val = bitor(val, uint8(bits(k)));
end
x = val;
end

function out = scramble_bits(bits, s)
if ~s.enable
    out = uint8(bits(:) ~= 0);
    return;
end
pn = comm.PNSequence( ...
    "Polynomial", s.pnPolynomial, ...
    "InitialConditions", s.pnInit, ...
    "SamplesPerFrame", numel(bits));
pnBits = uint8(pn());
out = bitxor(uint8(bits(:) ~= 0), pnBits);
end

function out = descramble_bits(bits, s)
out = scramble_bits(bits, s);
end

function coded = fec_encode(bits, fec)
bits = uint8(bits(:) ~= 0);
coded = convenc(bits, fec.trellis);
end

function bits = fec_decode(metrics, fec)
if strcmpi(fec.decisionType, "hard")
    hardBits = uint8(metrics(:) ~= 0);
    bits = vitdec(hardBits, fec.trellis, fec.tracebackDepth, fec.opmode, 'hard');
else
    nsdec = fec.softBits;
    soft = uint8(metrics(:));
    bits = vitdec(soft, fec.trellis, fec.tracebackDepth, fec.opmode, 'soft', nsdec);
end
bits = uint8(bits(:));
end

function [y, state] = interleave_bits(x, inter)
if ~inter.enable
    y = x(:);
    state = struct("pad", 0, "nRows", 1, "nCols", numel(y));
    return;
end

nRows = inter.nRows;
n = numel(x);
nCols = ceil(n / nRows);
pad = nRows*nCols - n;
xPad = [x(:); zeros(pad, 1, 'like', x)];

mat = reshape(xPad, nCols, nRows).';
y = mat(:);

state = struct("pad", pad, "nRows", nRows, "nCols", nCols);
end

function x = deinterleave_bits(y, state, inter)
if ~inter.enable
    x = y(:);
    return;
end
mat = reshape(y, state.nRows, state.nCols);
xPad = reshape(mat.', [], 1);
if state.pad > 0
    x = xPad(1:end-state.pad);
else
    x = xPad;
end
end

function [sym, info] = modulate_bits(bits, mod)
bits = uint8(bits(:) ~= 0);
switch upper(string(mod.type))
    case "BPSK"
        sym = 1 - 2*double(bits);
        info.bitsPerSymbol = 1;
    otherwise
        error("Unsupported modulation: %s", mod.type);
end

info.codeRate = 1/2;
end

function soft = demodulate_to_softbits(r, mod, fec, softCfg)
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
A = softCfg.clipA;

metric = max(min(metric, A), -A);

% Quantize so that 0 => strong '0', maxv => strong '1'
soft = round((A - metric) / (2*A) * maxv);
soft = uint8(max(min(soft, maxv), 0));
end

function y = channel_bg_impulsive(x, N0, ch)
% Complex AWGN with variance N0 plus Bernoulli-Gaussian impulses.
x = x(:);
nBg = sqrt(N0/2) * (randn(size(x)) + 1j*randn(size(x)));

impMask = rand(size(x)) < ch.impulseProb;
N0imp = ch.impulseToBgRatio * N0;
nImp = sqrt(N0imp/2) * (randn(size(x)) + 1j*randn(size(x)));

y = x + nBg + impMask .* nImp;
end

function idx = frame_sync(r, preambleSym)
% Coarse frame sync by correlation with known preamble.
r = r(:);
p = preambleSym(:);
if numel(r) < numel(p)
    idx = [];
    return;
end

c = abs(conv(r, flipud(conj(p)), 'valid'));
[~, k] = max(c);
idx = k;
end

function rOut = mitigate_impulses(rIn, method, mit)
r = rIn(:);

switch string(mit.thresholdStrategy)
    case "median"
        T = mit.thresholdAlpha * median(abs(r));
    case "fixed"
        T = mit.thresholdFixed;
    otherwise
        error("Unknown thresholdStrategy: %s", mit.thresholdStrategy);
end

switch lower(string(method))
    case "none"
        rOut = r;
    case "blanking"
        rOut = r;
        rOut(abs(r) > T) = 0;
    case "clipping"
        mag = abs(r);
        scale = ones(size(r));
        over = mag > T;
        scale(over) = T ./ mag(over);
        rOut = r .* scale;
    otherwise
        error("Unknown mitigation method: %s", method);
end
end

function N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, Es)
Eb = Es / (codeRate * bitsPerSym);
N0 = Eb / EbN0;
end

function [psd, f, bw99, eta] = estimate_spectrum(sym, modInfo)
Rs = 10e3;      % symbol rate for reference plots (Hz)
sps = 8;        % samples/symbol
rolloff = 0.25;
span = 10;      % symbols
Fs = Rs * sps;

rrc = rcosdesign(rolloff, span, sps, "sqrt");
wave = upfirdn(sym(:), rrc, sps, 1);

[psd, f] = pwelch(wave, 4096, [], 4096, Fs, "centered");
try
    [bwTmp, flo, ~] = obw(wave, Fs); % default is 99% occupied bandwidth
    % For real-valued baseband, obw() reports one-sided bandwidth; convert to two-sided.
    if isreal(wave) && flo >= 0
        bw99 = 2 * bwTmp;
    else
        bw99 = bwTmp;
    end
catch
    bw99 = NaN;
end

Rb = Rs * modInfo.bitsPerSymbol * modInfo.codeRate; % information bitrate
eta = Rb / bw99;
end

function [psnrVal, ssimVal] = image_quality(ref, test)
ref = im2uint8(ref);
test = im2uint8(test);

if ~isequal(size(ref), size(test))
    psnrVal = NaN;
    ssimVal = NaN;
    return;
end

try
    psnrVal = psnr(test, ref);
catch
    mse = mean((double(test(:)) - double(ref(:))).^2);
    psnrVal = 10*log10(255^2 / max(mse, eps));
end

try
    ssimVal = ssim(test, ref);
catch
    ssimVal = NaN;
end
end

function outDir = make_results_dir(rootDir)
ts = datetime("now", "Format", "yyyyMMdd_HHmmss");
outDir = fullfile(rootDir, "matlab_" + string(ts));
if ~exist(outDir, "dir")
    mkdir(outDir);
end
end

function save_figures(outDir, imgTx, results)
methods = results.methods;
EbN0dB = results.ebN0dB;

fig1 = figure("Name", "BER");
semilogy(EbN0dB, results.ber.', "o-");
grid on;
xlabel("E_b/N_0 (dB)");
ylabel("BER (payload)");
legend(methods, "Location", "southwest");
exportgraphics(fig1, fullfile(outDir, "ber.png"));
close(fig1);

fig2 = figure("Name", "PSNR");
plot(EbN0dB, results.psnr.', "o-");
grid on;
xlabel("E_b/N_0 (dB)");
ylabel("PSNR (dB)");
legend(methods, "Location", "southeast");
exportgraphics(fig2, fullfile(outDir, "psnr.png"));
close(fig2);

fig3 = figure("Name", "Spectrum");
plot(results.spectrum.freqHz/1e3, 10*log10(results.spectrum.psd));
grid on;
xlabel("Frequency (kHz)");
ylabel("PSD (dB/Hz)");
title(sprintf("99%% OBW=%.1f Hz,  \\eta=%.3f b/s/Hz", results.spectrum.bw99Hz, results.spectrum.etaBpsHz));
exportgraphics(fig3, fullfile(outDir, "psd.png"));
close(fig3);

fig4 = figure("Name", "Images");
tiledlayout(1, numel(methods) + 1);
nexttile;
imshow(imgTx);
title("TX");
for k = 1:numel(methods)
    nexttile;
    if isfield(results.example, methods(k))
        imshow(results.example.(methods(k)).imgRx);
        title(sprintf("RX - %s", methods(k)));
    else
        text(0.1, 0.5, "No example", "Units", "normalized");
        axis off;
        title(sprintf("RX - %s", methods(k)));
    end
end
exportgraphics(fig4, fullfile(outDir, "images.png"));
close(fig4);
end

function s = make_summary(results)
s = struct();
s.methods = results.methods;
s.ebN0dB = results.ebN0dB;
s.berAtMaxEbN0 = results.ber(:, end);
s.psnrAtMaxEbN0 = results.psnr(:, end);
s.spectrum99ObwHz = results.spectrum.bw99Hz;
s.spectralEfficiency = results.spectrum.etaBpsHz;
end
