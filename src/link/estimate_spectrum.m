function [psd, f, bw99, eta] = estimate_spectrum(sym, modInfo)
%ESTIMATE_SPECTRUM  Estimate PSD and 99% occupied bandwidth.

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

