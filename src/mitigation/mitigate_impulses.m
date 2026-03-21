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

    case "adaptive_notch"
        cfg = struct();
        if isfield(mit, "adaptiveNotch") && isstruct(mit.adaptiveNotch)
            cfg = mit.adaptiveNotch;
        end
        [rOut, ~] = adaptive_notch_filter(r, cfg);

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
        [mask, rel, cleanSym, pImp] = ml_cnn_impulse_detect(r, model);

        % 对检测到的脉冲使用清洁符号，否则使用原始符号
        rOut = r;
        if model.trained
            % 使用由threshold门控后的软权重，避免低于阈值的样本也被过度修正。
            blendWeight = local_threshold_gate_probability(pImp, model.threshold);
            rOut = (1 - blendWeight) .* r + blendWeight .* cleanSym;
        else
            % 未训练：退回到置零
            rOut(mask) = 0;
        end
        % 确保double精度和CPU数组（vitdec需要）
        rOut = double(gather(rOut));
        reliability = double(gather(rel));

    case "ml_cnn_hard"
        % 1D CNN硬置零（用于比较）
        if isfield(mit, "mlCnn") && ~isempty(mit.mlCnn)
            model = mit.mlCnn;
        else
            model = ml_cnn_impulse_model();
        end
        local_require_trained_dl_model(model, "ml_cnn_hard", mit);
        [mask, rel, ~, ~] = ml_cnn_impulse_detect(r, model);
        rOut = r;
        rOut(mask) = 0;
        reliability = double(rel);
        reliability(mask) = 0;

    case "ml_gru"
        % GRU带软输出
        if isfield(mit, "mlGru") && ~isempty(mit.mlGru)
            model = mit.mlGru;
        else
            model = ml_gru_impulse_model();
        end
        local_require_trained_dl_model(model, "ml_gru", mit);
        [mask, rel, cleanSym, pImp] = ml_gru_impulse_detect(r, model);

        rOut = r;
        if model.trained
            blendWeight = local_threshold_gate_probability(pImp, model.threshold);
            rOut = (1 - blendWeight) .* r + blendWeight .* cleanSym;
        else
            rOut(mask) = 0;
        end
        % 确保double精度和CPU数组（vitdec需要）
        rOut = double(gather(rOut));
        reliability = double(gather(rel));

    case "ml_gru_hard"
        % GRU硬置零
        if isfield(mit, "mlGru") && ~isempty(mit.mlGru)
            model = mit.mlGru;
        else
            model = ml_gru_impulse_model();
        end
        local_require_trained_dl_model(model, "ml_gru_hard", mit);
        [mask, rel, ~, ~] = ml_gru_impulse_detect(r, model);
        rOut = r;
        rOut(mask) = 0;
        reliability = double(rel);
        reliability(mask) = 0;

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

function w = local_threshold_gate_probability(p, threshold)
p = double(gather(p(:)));
threshold = double(gather(threshold));
if isempty(threshold) || ~isfinite(threshold)
    error("ML模型threshold无效，无法计算软门控权重。");
end
threshold = min(max(threshold(1), 0), 0.999);
w = zeros(size(p));
if threshold >= 0.999
    return;
end
active = p >= threshold;
w(active) = (p(active) - threshold) / max(1 - threshold, eps);
w = max(min(w, 1), 0);
end
