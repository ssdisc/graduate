function [psd, f, bw99, eta, info] = estimate_spectrum(txWave, modInfo, waveform, opts)
%ESTIMATE_SPECTRUM  基于真实发射波形估计PSD和99%占用带宽。
%
% 输入:
%   txWave  - 发射端实际输出的采样波形（信道前）
%   modInfo - 调制信息结构体
%             .bitsPerSymbol - 每符号比特数
%             .codeRate      - 码率
%   waveform - 波形成型配置（至少含symbolRateHz/sampleRateHz/sps）
%   opts    - 可选配置
%             .payloadBits - 当前突发承载的净载荷比特数
%
% 输出:
%   psd  - 功率谱密度估计
%   f    - 频率轴（Hz）
%   bw99 - 99%占用带宽（Hz）
%   eta  - 净载荷频谱效率（bit/s/Hz）
%   info - 统计细节（采样率、符号率、突发时长、净/毛比特率）

if nargin < 3 || isempty(waveform)
    waveform = resolve_waveform_cfg(struct());
end
if nargin < 4
    opts = struct();
end

txWave = txWave(:);
Fs = local_sample_rate_hz(waveform);
Rs = local_symbol_rate_hz(waveform);

if isempty(txWave)
    psd = NaN;
    f = NaN;
    bw99 = NaN;
    eta = NaN;
    info = local_make_info(Fs, Rs, NaN, NaN, NaN, NaN, NaN);
    return;
end

nfft = max(256, 2^nextpow2(min(numel(txWave), 4096)));
winLen = min(numel(txWave), nfft);
[psd, f] = pwelch(txWave, winLen, [], nfft, Fs, "centered");
try
    [bwTmp, flo, ~] = obw(txWave, Fs); % 默认是99%占用带宽
    % 对于实值基带，obw()报告单边带宽；转换为双边。
    if isreal(txWave) && flo >= 0
        bw99 = 2 * bwTmp;
    else
        bw99 = bwTmp;
    end
catch
    bw99 = NaN;
end

burstDurationSec = numel(txWave) / max(Fs, eps);
grossInfoBitRateBps = Rs * modInfo.bitsPerSymbol * modInfo.codeRate;
payloadBitRateBps = NaN;
if isfield(opts, "payloadBits") && ~isempty(opts.payloadBits)
    payloadBitRateBps = double(opts.payloadBits) / max(burstDurationSec, eps);
end

eta = NaN;
if isfinite(bw99) && bw99 > 0
    if isfinite(payloadBitRateBps)
        eta = payloadBitRateBps / bw99;
    else
        eta = grossInfoBitRateBps / bw99;
    end
end

info = local_make_info(Fs, Rs, burstDurationSec, grossInfoBitRateBps, payloadBitRateBps, bw99, eta);
end

function Fs = local_sample_rate_hz(waveform)
if isfield(waveform, "sampleRateHz") && isfinite(double(waveform.sampleRateHz)) && double(waveform.sampleRateHz) > 0
    Fs = double(waveform.sampleRateHz);
    return;
end

Rs = local_symbol_rate_hz(waveform);
sps = 1;
if isfield(waveform, "sps") && isfinite(double(waveform.sps)) && double(waveform.sps) > 0
    sps = max(1, round(double(waveform.sps)));
end
Fs = Rs * sps;
end

function Rs = local_symbol_rate_hz(waveform)
Rs = 10e3;
if isfield(waveform, "symbolRateHz") && isfinite(double(waveform.symbolRateHz)) && double(waveform.symbolRateHz) > 0
    Rs = double(waveform.symbolRateHz);
end
end

function info = local_make_info(Fs, Rs, burstDurationSec, grossInfoBitRateBps, payloadBitRateBps, bw99, eta)
info = struct( ...
    "sampleRateHz", Fs, ...
    "symbolRateHz", Rs, ...
    "burstDurationSec", burstDurationSec, ...
    "grossInfoBitRateBps", grossInfoBitRateBps, ...
    "payloadBitRateBps", payloadBitRateBps, ...
    "bw99Hz", bw99, ...
    "etaBpsHz", eta);
end

