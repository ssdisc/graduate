function [rOut, reliability] = mitigate_impulses(rIn, method, mit)
%MITIGATE_IMPULSES  脉冲抑制，可选软可靠性输出。
%
% 输入:
%   rIn    - 接收符号序列
%   method - 抑制方法名称
%   mit    - 抑制参数结构体
%            .thresholdStrategy - 'median' 或 'fixed'
%            .thresholdAlpha    - 中值阈值系数（median策略）
%            .thresholdFixed    - 固定阈值（fixed策略）
%            .fftNotch          - FFT变换域陷波参数（可选）
%            .adaptiveNotch     - 自适应陷波参数（可选）
%            .ml, .mlCnn, .mlGru- 对应ML模型（可选）
%
% 输出:
%   rOut       - 抑制后的符号（与rIn大小相同）
%   reliability- 软可靠性权重（0-1），用于加权软译码器输入
%                传统方法默认全为1（完全可靠）。

r = rIn(:);
N = numel(r);

% 默认可靠性：所有样本完全可靠
reliability = ones(N, 1);

switch string(mit.thresholdStrategy)
    case "median"
        T = mit.thresholdAlpha * median(abs(r));
    case "fixed"
        T = mit.thresholdFixed;
    otherwise
        error("未知的阈值策略: %s", mit.thresholdStrategy);
end

switch lower(string(method))
    case "none"
        rOut = r;

    case "fft_notch"
        cfg = struct();
        if isfield(mit, "fftNotch") && isstruct(mit.fftNotch)
            cfg = mit.fftNotch;
        end
        [rOut, ~] = fft_domain_notch_filter(r, cfg);

    case "fft_bandstop"
        cfg = struct();
        if isfield(mit, "fftBandstop") && isstruct(mit.fftBandstop)
            cfg = mit.fftBandstop;
        end
        [rOut, ~] = fft_bandstop_filter(r, cfg);

    case "adaptive_notch"
        cfg = struct();
        if isfield(mit, "adaptiveNotch") && isstruct(mit.adaptiveNotch)
            cfg = mit.adaptiveNotch;
        end
        [rOut, ~] = adaptive_notch_filter(r, cfg);

    case "stft_notch"
        cfg = struct();
        if isfield(mit, "stftNotch") && isstruct(mit.stftNotch)
            cfg = mit.stftNotch;
        end
        [rOut, ~] = stft_notch_filter(r, cfg);

    case "blanking"
        rOut = r;
        mask = abs(r) > T;
        rOut(mask) = 0;
        % 置零样本可靠性为零
        reliability(mask) = 0;

    case "clipping"
        mag = abs(r);
        scale = ones(size(r));
        over = mag > T;
        scale(over) = T ./ mag(over);
        rOut = r .* scale;
        % 削波样本的可靠性与削波程度成比例降低
        reliability(over) = scale(over);

    case "ml_blanking"
        % 传统逻辑回归置零
        if isfield(mit, "ml") && ~isempty(mit.ml)
            model = mit.ml;
        else
            model = ml_impulse_lr_model();
        end
        local_require_trained_dl_model(model, "ml_blanking", mit);
        [mask, p] = ml_impulse_detect(r, model);
        rOut = r;
        rOut(mask) = 0;
        % 可靠性 = 1 - p(脉冲)
        reliability = 1 - p;
        reliability(mask) = 0;

    case "ml_cnn"
        % 1D CNN带软输出
        if isfield(mit, "mlCnn") && ~isempty(mit.mlCnn)
            model = mit.mlCnn;
        else
            model = ml_cnn_impulse_model();
        end
        local_require_trained_dl_model(model, "ml_cnn", mit);
        [mask, suppressWeight, cleanSym, pImp] = ml_cnn_impulse_detect(r, model);

        rOut = r;
        if model.trained
            [rOut, reliability] = impulse_ml_runtime_apply( ...
                r, cleanSym, suppressWeight, pImp, model.threshold, model.cleanOutputMode, false);
        else
            rOut(mask) = 0;
            reliability(mask) = 0;
        end

    case "ml_cnn_hard"
        % 1D CNN硬置零（用于比较）
        if isfield(mit, "mlCnn") && ~isempty(mit.mlCnn)
            model = mit.mlCnn;
        else
            model = ml_cnn_impulse_model();
        end
        local_require_trained_dl_model(model, "ml_cnn_hard", mit);
        [~, suppressWeight, cleanSym, pImp] = ml_cnn_impulse_detect(r, model);
        [rOut, reliability] = impulse_ml_runtime_apply( ...
            r, cleanSym, suppressWeight, pImp, model.threshold, model.cleanOutputMode, true);

    case "ml_gru"
        % GRU带软输出
        if isfield(mit, "mlGru") && ~isempty(mit.mlGru)
            model = mit.mlGru;
        else
            model = ml_gru_impulse_model();
        end
        local_require_trained_dl_model(model, "ml_gru", mit);
        [mask, suppressWeight, cleanSym, pImp] = ml_gru_impulse_detect(r, model);

        rOut = r;
        if model.trained
            [rOut, reliability] = impulse_ml_runtime_apply( ...
                r, cleanSym, suppressWeight, pImp, model.threshold, model.cleanOutputMode, false);
        else
            rOut(mask) = 0;
            reliability(mask) = 0;
        end

    case "ml_gru_hard"
        % GRU硬置零
        if isfield(mit, "mlGru") && ~isempty(mit.mlGru)
            model = mit.mlGru;
        else
            model = ml_gru_impulse_model();
        end
        local_require_trained_dl_model(model, "ml_gru_hard", mit);
        [~, suppressWeight, cleanSym, pImp] = ml_gru_impulse_detect(r, model);
        [rOut, reliability] = impulse_ml_runtime_apply( ...
            r, cleanSym, suppressWeight, pImp, model.threshold, model.cleanOutputMode, true);

    case "ml_narrowband"
        if isfield(mit, "mlNarrowband") && ~isempty(mit.mlNarrowband)
            model = mit.mlNarrowband;
        else
            model = ml_narrowband_action_model();
        end
        local_require_trained_dl_model(model, "ml_narrowband", mit);
        bandstopCfg = local_require_fft_bandstop_cfg(mit);
        [featureRow, featureInfo] = ml_extract_narrowband_features(r, bandstopCfg);
        [shouldBandstop, ~] = ml_predict_narrowband_action(featureRow, model);
        if ~shouldBandstop
            rOut = r;
            return;
        end
        if ~(isfield(featureInfo, "probeInfo") && isstruct(featureInfo.probeInfo) ...
                && isfield(featureInfo.probeInfo, "applied") && featureInfo.probeInfo.applied ...
                && isfield(featureInfo.probeInfo, "selectedFreqBounds") && ~isempty(featureInfo.probeInfo.selectedFreqBounds))
            rOut = r;
            return;
        end
        bandstopCfg.forcedFreqBounds = double(featureInfo.probeInfo.selectedFreqBounds);
        [rOut, ~] = fft_bandstop_filter(r, bandstopCfg);

    case "adaptive_ml_frontend"
        error("adaptive_ml_frontend is orchestrated at the packet front-end level and must not be sent to mitigate_impulses directly.");

    otherwise
        error("未知的抑制方法: %s", method);
end
end

function local_require_trained_dl_model(model, methodName, mit)
requireTrained = isfield(mit, "requireTrainedModels") && logical(mit.requireTrainedModels);
if requireTrained && ~(isfield(model, "trained") && logical(model.trained))
    error("mitigate_impulses:MissingTrainedModel", ...
        "Method %s requires a trained ML model, but the loaded model is not trained.", char(methodName));
end
end

function cfg = local_require_fft_bandstop_cfg(mit)
if ~(isfield(mit, "fftBandstop") && isstruct(mit.fftBandstop))
    error("mitigate_impulses:MissingFftBandstopCfg", ...
        "Method ml_narrowband requires mitigation.fftBandstop.");
end
cfg = mit.fftBandstop;
end

