function [txClean, rxInput, impMask, impScore, runtimeProfile] = ml_simulate_training_chain(payloadBits, p, N0, targetLen, opts)
%ML_SIMULATE_TRAINING_CHAIN  Generate paired raw-sample training windows on the new RX architecture.
%
% 输出:
%   txClean - 不含脉冲的“干净”复基带样本窗口（保留同一次随机噪声/干扰/信道实现）
%   rxInput - 含脉冲的接收复基带样本窗口
%   impMask - 样本级脉冲真值掩码
%   impScore- 样本级连续得分（当前直接等于 double(impMask)）

arguments
    payloadBits (:,1)
    p (1,1) struct
    N0 (1,1) double {mustBeNonnegative}
    targetLen (1,1) double {mustBeInteger, mustBePositive}
    opts.impulsePowerMode (1,1) string {mustBeMember(opts.impulsePowerMode, ["direct_ratio" "jsr_calibrated"])} = "direct_ratio"
    opts.jsrDb (1,1) double = NaN
    opts.prebuiltTraining = []
end

payloadBits = uint8(payloadBits(:) ~= 0);
targetLen = round(double(targetLen));

waveform = resolve_waveform_cfg(p);
channelSample = adapt_channel_for_sps(p.channel, waveform, p.fh);
training = local_resolve_training_burst_local(p, payloadBits, waveform, opts.prebuiltTraining);
txSample = training.txBurstForChannel(:);
burstReport = local_resolve_burst_report_local(training, txSample, waveform);

runtimeProfile = struct( ...
    "impulsePowerMode", string(opts.impulsePowerMode), ...
    "jsrDb", NaN, ...
    "txBaseAveragePowerLin", double(burstReport.averagePowerLin), ...
    "impulseProbSample", double(channelSample.impulseProb), ...
    "impulseToBgRatio", double(channelSample.impulseToBgRatio));

switch string(opts.impulsePowerMode)
    case "direct_ratio"
        if ~(isfield(channelSample, "impulseToBgRatio") && isfinite(double(channelSample.impulseToBgRatio)) ...
                && double(channelSample.impulseToBgRatio) >= 0)
            error("Direct-ratio impulse training requires a finite nonnegative channel.impulseToBgRatio.");
        end
    case "jsr_calibrated"
        if double(channelSample.impulseProb) > 0
            if ~(isfinite(double(opts.jsrDb)) && isscalar(opts.jsrDb))
                error("JSR-calibrated impulse training requires a finite scalar jsrDb when impulseProb > 0.");
            end
            impulseProbSample = local_required_impulse_probability_local(channelSample);
            jsrLin = 10^(double(opts.jsrDb) / 10);
            targetImpulsePower = double(burstReport.averagePowerLin) * jsrLin;
            channelSample.impulseToBgRatio = targetImpulsePower / max(impulseProbSample * N0, eps);
            runtimeProfile.jsrDb = double(opts.jsrDb);
            runtimeProfile.impulseToBgRatio = double(channelSample.impulseToBgRatio);
        else
            channelSample.impulseToBgRatio = 0;
            runtimeProfile.impulseToBgRatio = 0;
        end
    otherwise
        error("Unsupported impulsePowerMode: %s", char(opts.impulsePowerMode));
end

cleanChannel = channelSample;
cleanChannel.impulseProb = 0;

rngState = rng;
[rxInputFull, impMaskFull] = channel_bg_impulsive(txSample, N0, channelSample);
rng(rngState);
[txCleanFull, ~] = channel_bg_impulsive(txSample, N0, cleanChannel);
impScoreFull = abs(rxInputFull - txCleanFull) / sqrt(max(N0, eps));

[txClean, rxInput, impMask, impScore] = local_crop_training_window( ...
    txCleanFull, rxInputFull, logical(impMaskFull(:)), impScoreFull(:), waveform, targetLen);
end

function training = local_resolve_training_burst_local(p, payloadBits, waveform, prebuiltTraining)
if isempty(prebuiltTraining)
    training = ml_build_training_tx_burst(p, payloadBits, waveform);
    return;
end

training = prebuiltTraining;
requiredFields = ["payloadBitsLen" "txBurstForChannel"];
for idx = 1:numel(requiredFields)
    fieldName = requiredFields(idx);
    if ~isfield(training, fieldName)
        error("Prebuilt training burst is missing field %s.", char(fieldName));
    end
end

payloadBitsLen = max(numel(payloadBits), 8);
payloadBitsLen = 8 * ceil(double(payloadBitsLen) / 8);
if double(training.payloadBitsLen) ~= payloadBitsLen
    error("Prebuilt training burst payloadBitsLen=%d does not match requested length=%d.", ...
        double(training.payloadBitsLen), payloadBitsLen);
end
end

function burstReport = local_resolve_burst_report_local(training, txSample, waveform)
if isfield(training, "burstReport") && isstruct(training.burstReport) ...
        && isfield(training.burstReport, "averagePowerLin") ...
        && isfield(training.burstReport, "burstDurationSec")
    burstReport = training.burstReport;
    return;
end
burstReport = measure_tx_burst(txSample, waveform);
end

function impulseProbSample = local_required_impulse_probability_local(channelCfg)
if ~(isfield(channelCfg, "impulseProb") && isfinite(double(channelCfg.impulseProb)))
    error("JSR-calibrated impulse training requires a finite sample-domain channel.impulseProb.");
end
impulseProbSample = double(channelCfg.impulseProb);
if ~(isscalar(impulseProbSample) && impulseProbSample > 0 && impulseProbSample <= 1)
    error("JSR-calibrated impulse training requires sample-domain channel.impulseProb in (0, 1].");
end
end

function [txClean, rxInput, impMask, impScore] = local_crop_training_window(txCleanFull, rxInputFull, impMaskFull, impScoreFull, waveform, targetLen)
txCleanFull = txCleanFull(:);
rxInputFull = rxInputFull(:);
impMaskFull = logical(impMaskFull(:));
impScoreFull = double(impScoreFull(:));
if ~(numel(txCleanFull) == numel(rxInputFull) ...
        && numel(rxInputFull) == numel(impMaskFull) ...
        && numel(impMaskFull) == numel(impScoreFull))
    error("训练链输出长度不一致，无法裁剪统一窗口。");
end

guard = 0;
if isstruct(waveform) && isfield(waveform, "enable") && waveform.enable ...
        && isfield(waveform, "groupDelaySamples")
    guard = max(0, round(double(waveform.groupDelaySamples)));
end

startMin = 1 + guard;
startMax = numel(rxInputFull) - guard - targetLen + 1;
if startMax < startMin
    error("训练窗口长度 %d 超出可用采样长度 %d（guard=%d）。请增大训练符号数或减小 blockLen。", ...
        targetLen, numel(rxInputFull), guard);
end

if startMax == startMin
    startIdx = startMin;
else
    startIdx = randi([startMin, startMax], 1, 1);
end
stopIdx = startIdx + targetLen - 1;

txClean = txCleanFull(startIdx:stopIdx);
rxInput = rxInputFull(startIdx:stopIdx);
impMask = impMaskFull(startIdx:stopIdx);
impScore = impScoreFull(startIdx:stopIdx);
end
