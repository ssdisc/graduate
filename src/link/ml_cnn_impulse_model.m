function model = ml_cnn_impulse_model()
%ML_CNN_IMPULSE_MODEL  Return default (untrained) 1D CNN impulse detector.
%
% This provides a lightweight 1D CNN for impulse detection that outputs:
%   - Impulse probability per sample
%   - Reliability weight for soft decoding
%   - Cleaned/denoised symbol estimate
%
% The model uses causal convolutions to avoid lookahead.

model = struct();
model.name = "impulse_cnn_1d";
model.type = "cnn";

% Architecture: Input -> Conv1D -> ReLU -> Conv1D -> Sigmoid
% Window size = 2*halfWin + 1 (context around each sample)
model.halfWin = 4;  % look at 4 samples before and after (9 total)

% Layer 1: Conv1D (input: 2 channels [real, imag] or [abs, phase])
model.inputChannels = 4;  % [real, imag, abs, abs_diff]
model.conv1Filters = 16;
model.conv1KernelSize = 5;

% Layer 2: Conv1D
model.conv2Filters = 8;
model.conv2KernelSize = 3;

% Output layer: 3 outputs per sample
%   1. p_impulse: probability this sample is corrupted
%   2. reliability: soft weight for decoder (0=ignore, 1=trust)
%   3. clean_real, clean_imag: denoised symbol estimate
model.outputSize = 4;  % [p_impulse, reliability, clean_real, clean_imag]

% Initialize weights (will be overwritten by training)
model.trained = false;

% Conv1 weights: [kernelSize, inputChannels, nFilters]
rng(42);
scale1 = sqrt(2 / (model.conv1KernelSize * model.inputChannels));
model.W1 = scale1 * randn(model.conv1KernelSize, model.inputChannels, model.conv1Filters);
model.b1 = zeros(1, model.conv1Filters);

% Conv2 weights
scale2 = sqrt(2 / (model.conv2KernelSize * model.conv1Filters));
model.W2 = scale2 * randn(model.conv2KernelSize, model.conv1Filters, model.conv2Filters);
model.b2 = zeros(1, model.conv2Filters);

% Output layer (dense from conv2 output)
model.Wo = 0.1 * randn(model.conv2Filters, model.outputSize);
model.bo = zeros(1, model.outputSize);
model.bo(2) = 1.0;  % bias reliability toward 1 (trust by default)

% Detection threshold
model.threshold = 0.5;

% Normalization stats (computed during training)
model.inputMean = zeros(1, model.inputChannels);
model.inputStd = ones(1, model.inputChannels);

end
