function [rOut, reliability] = mitigate_impulses(rIn, method, mit)
%MITIGATE_IMPULSES  Impulse mitigation with optional soft reliability output.
%
% Outputs:
%   rOut       - Mitigated symbols (same size as rIn)
%   reliability- Soft reliability weights (0-1), for weighting soft decoder input
%                Default is all ones (fully reliable) for traditional methods.

r = rIn(:);
N = numel(r);

% Default reliability: all samples fully reliable
reliability = ones(N, 1);

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
        mask = abs(r) > T;
        rOut(mask) = 0;
        % Blanked samples have zero reliability
        reliability(mask) = 0;

    case "clipping"
        mag = abs(r);
        scale = ones(size(r));
        over = mag > T;
        scale(over) = T ./ mag(over);
        rOut = r .* scale;
        % Clipped samples have reduced reliability proportional to clipping
        reliability(over) = scale(over);

    case "ml_blanking"
        % Legacy logistic regression blanking
        if isfield(mit, "ml") && ~isempty(mit.ml)
            model = mit.ml;
        else
            model = ml_impulse_lr_model();
        end
        [mask, p] = ml_impulse_detect(r, model);
        rOut = r;
        rOut(mask) = 0;
        % Reliability = 1 - p(impulse)
        reliability = 1 - p;
        reliability(mask) = 0;

    case "ml_cnn"
        % 1D CNN with soft outputs
        if isfield(mit, "mlCnn") && ~isempty(mit.mlCnn)
            model = mit.mlCnn;
        else
            model = ml_cnn_impulse_model();
        end
        [mask, rel, cleanSym, pImp] = ml_cnn_impulse_detect(r, model);

        % Use cleaned symbols for detected impulses, original otherwise
        rOut = r;
        if model.trained
            % Blend: use cleaned estimate weighted by impulse probability
            rOut = (1 - pImp) .* r + pImp .* cleanSym;
        else
            % Untrained: fall back to blanking
            rOut(mask) = 0;
        end
        reliability = rel;

    case "ml_cnn_hard"
        % 1D CNN with hard blanking (for comparison)
        if isfield(mit, "mlCnn") && ~isempty(mit.mlCnn)
            model = mit.mlCnn;
        else
            model = ml_cnn_impulse_model();
        end
        [mask, rel, ~, ~] = ml_cnn_impulse_detect(r, model);
        rOut = r;
        rOut(mask) = 0;
        reliability = rel;
        reliability(mask) = 0;

    case "ml_gru"
        % GRU with soft outputs
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
        reliability = rel;

    case "ml_gru_hard"
        % GRU with hard blanking
        if isfield(mit, "mlGru") && ~isempty(mit.mlGru)
            model = mit.mlGru;
        else
            model = ml_gru_impulse_model();
        end
        [mask, rel, ~, ~] = ml_gru_impulse_detect(r, model);
        rOut = r;
        rOut(mask) = 0;
        reliability = rel;
        reliability(mask) = 0;

    otherwise
        error("Unknown mitigation method: %s", method);
end
end
