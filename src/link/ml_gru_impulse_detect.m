function [mask, reliability, cleanSym, pImpulse] = ml_gru_impulse_detect(rIn, model)
%ML_GRU_IMPULSE_DETECT  Detect impulses using GRU and output soft info.
%
% Inputs:
%   rIn   - Complex received symbols (N x 1)
%   model - Trained GRU model from ml_train_gru_impulse
%
% Outputs:
%   mask       - Binary impulse mask (logical, N x 1)
%   reliability- Soft reliability weights for decoder (0-1, N x 1)
%   cleanSym   - Denoised symbol estimates (complex, N x 1)
%   pImpulse   - Raw impulse probability (N x 1)

r = rIn(:);
N = numel(r);

% Extract input features
X = ml_cnn_features(r);  % Reuse same feature extraction

% Normalize
Xn = (X - model.inputMean) ./ (model.inputStd + 1e-8);

% GRU forward pass
hs = model.hiddenSize;
h = zeros(1, hs);  % Initial hidden state

outputs = zeros(N, model.outputSize);

for t = 1:N
    xt = Xn(t, :);

    % Reset gate
    rt = sigmoid(xt * model.Wr + h * model.Ur + model.br);

    % Update gate
    zt = sigmoid(xt * model.Wz + h * model.Uz + model.bz);

    % Candidate hidden state
    h_tilde = tanh(xt * model.Wh + (rt .* h) * model.Uh + model.bh);

    % New hidden state
    h = (1 - zt) .* h + zt .* h_tilde;

    % Output
    outputs(t, :) = h * model.Wo + model.bo;
end

% Parse outputs
pImpulse = sigmoid(outputs(:, 1));
reliability = sigmoid(outputs(:, 2));
cleanReal = outputs(:, 3);
cleanImag = outputs(:, 4);

% Apply threshold
mask = pImpulse >= model.threshold;

% Construct cleaned symbols
cleanSym = complex(cleanReal, cleanImag);

% Reduce reliability for detected impulses
reliability(mask) = reliability(mask) .* (1 - pImpulse(mask));

end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-max(min(x, 30), -30)));
end
