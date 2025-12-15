function [mask, reliability, cleanSym, pImpulse] = ml_cnn_impulse_detect(rIn, model)
%ML_CNN_IMPULSE_DETECT  Detect impulses using 1D CNN and output soft info.
%
% Inputs:
%   rIn   - Complex received symbols (N x 1)
%   model - Trained CNN model from ml_train_cnn_impulse
%
% Outputs:
%   mask       - Binary impulse mask (logical, N x 1)
%   reliability- Soft reliability weights for decoder (0-1, N x 1)
%   cleanSym   - Denoised symbol estimates (complex, N x 1)
%   pImpulse   - Raw impulse probability (N x 1)

r = rIn(:);
N = numel(r);

% Extract input features
X = ml_cnn_features(r);  % [N x inputChannels]

% Normalize
Xn = (X - model.inputMean) ./ (model.inputStd + 1e-8);

% Calculate padding to maintain output size after convolutions
K1 = model.conv1KernelSize;
K2 = model.conv2KernelSize;
totalKernelLoss = (K1 - 1) + (K2 - 1);
padLen = ceil(totalKernelLoss / 2) + model.halfWin;

% Pad input
Xpad = [repmat(Xn(1,:), padLen, 1); Xn; repmat(Xn(end,:), padLen, 1)];

% Forward pass
% Conv1 + ReLU
h1 = conv1d_forward(Xpad, model.W1, model.b1);
h1 = max(h1, 0);  % ReLU

% Conv2 + ReLU
h2 = conv1d_forward(h1, model.W2, model.b2);
h2 = max(h2, 0);  % ReLU

% Trim to original length
h2Len = size(h2, 1);
trimStart = max(1, floor((h2Len - N) / 2) + 1);
trimEnd = min(h2Len, trimStart + N - 1);
h2 = h2(trimStart:trimEnd, :);

% Handle length mismatch
actualN = size(h2, 1);

% Output layer (dense)
out = h2 * model.Wo + model.bo;  % [actualN x 4]

% Parse outputs
pImpulse = sigmoid(out(:, 1));           % Impulse probability
reliability = sigmoid(out(:, 2));         % Reliability weight (0-1)
cleanReal = out(:, 3);                    % Cleaned real part
cleanImag = out(:, 4);                    % Cleaned imaginary part

% Pad or trim outputs to match input length
if actualN < N
    % Pad with default values
    pImpulse = [pImpulse; 0.5 * ones(N - actualN, 1)];
    reliability = [reliability; ones(N - actualN, 1)];
    cleanReal = [cleanReal; zeros(N - actualN, 1)];
    cleanImag = [cleanImag; zeros(N - actualN, 1)];
elseif actualN > N
    pImpulse = pImpulse(1:N);
    reliability = reliability(1:N);
    cleanReal = cleanReal(1:N);
    cleanImag = cleanImag(1:N);
end

% Apply threshold for hard mask
mask = pImpulse >= model.threshold;

% Construct cleaned symbols
cleanSym = complex(cleanReal, cleanImag);

% For samples detected as impulses, reduce reliability
reliability(mask) = reliability(mask) .* (1 - pImpulse(mask));

end

function y = conv1d_forward(x, W, b)
%CONV1D_FORWARD  1D convolution (valid mode).
% x: [T x Cin], W: [K x Cin x Cout], b: [1 x Cout]
% y: [T-K+1 x Cout]

[T, Cin] = size(x);
[K, ~, Cout] = size(W);
Tout = T - K + 1;

y = zeros(Tout, Cout);
for co = 1:Cout
    for ci = 1:Cin
        kernel = W(:, ci, co);
        % Flip kernel for convolution (not correlation)
        y(:, co) = y(:, co) + conv(x(:, ci), flipud(kernel), 'valid');
    end
    y(:, co) = y(:, co) + b(co);
end
end

function y = sigmoid(x)
y = 1 ./ (1 + exp(-max(min(x, 30), -30)));
end
