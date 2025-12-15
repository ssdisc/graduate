function model = ml_gru_impulse_model()
%ML_GRU_IMPULSE_MODEL  Return default (untrained) GRU impulse detector.
%
% GRU (Gated Recurrent Unit) is effective for sequential data where
% temporal context matters for impulse detection.

model = struct();
model.name = "impulse_gru";
model.type = "gru";

% Architecture
model.inputSize = 4;     % [real, imag, abs, abs_diff]
model.hiddenSize = 16;   % GRU hidden state size
model.outputSize = 4;    % [p_impulse, reliability, clean_real, clean_imag]

% Initialize GRU weights
% GRU has 3 gates: reset (r), update (z), and candidate (h~)
% Each gate has weights for input (W) and hidden (U)
rng(42);
hs = model.hiddenSize;
is = model.inputSize;

% Xavier initialization
scaleW = sqrt(2 / (is + hs));
scaleU = sqrt(2 / (hs + hs));

% Reset gate
model.Wr = scaleW * randn(is, hs);
model.Ur = scaleU * randn(hs, hs);
model.br = zeros(1, hs);

% Update gate
model.Wz = scaleW * randn(is, hs);
model.Uz = scaleU * randn(hs, hs);
model.bz = zeros(1, hs);

% Candidate hidden state
model.Wh = scaleW * randn(is, hs);
model.Uh = scaleU * randn(hs, hs);
model.bh = zeros(1, hs);

% Output layer
model.Wo = 0.1 * randn(hs, model.outputSize);
model.bo = [0, 1, 0, 0];  % bias reliability toward 1

% Detection threshold
model.threshold = 0.5;

% Normalization
model.inputMean = zeros(1, is);
model.inputStd = ones(1, is);

model.trained = false;

end
