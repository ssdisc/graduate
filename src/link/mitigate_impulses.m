function [rOut, reliability] = mitigate_impulses(rIn, method, mit)
%MITIGATE_IMPULSES  脉冲抑制，可选软可靠性输出。
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
        [mask, rel, cleanSym, pImp] = ml_cnn_impulse_detect(r, model);

        % 对检测到的脉冲使用清洁符号，否则使用原始符号
        rOut = r;
        if model.trained
            % 混合：使用脉冲概率加权的清洁估计
            rOut = (1 - pImp) .* r + pImp .* cleanSym;
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
        [mask, rel, cleanSym, pImp] = ml_gru_impulse_detect(r, model);

        rOut = r;
        if model.trained
            rOut = (1 - pImp) .* r + pImp .* cleanSym;
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
        [mask, rel, ~, ~] = ml_gru_impulse_detect(r, model);
        rOut = r;
        rOut(mask) = 0;
        reliability = double(rel);
        reliability(mask) = 0;

    otherwise
        error("未知的抑制方法: %s", method);
end
end
