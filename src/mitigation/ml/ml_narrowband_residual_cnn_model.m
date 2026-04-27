function model = ml_narrowband_residual_cnn_model()
%ML_NARROWBAND_RESIDUAL_CNN_MODEL Lightweight CNN residual reconstructor for narrowband RX.

model = struct();
model.name = "narrowband_residual_cnn_v1";
model.type = "narrowband_residual_cnn";
model.trained = false;
model.featureVersion = 1;
model.trainingLogicVersion = 1;
model.rxProfile = "narrowband";
model.rxFrontend = "narrowband_subband_excision_residual_v1";
model.featureNames = ["real_over_scale" "imag_over_scale" "abs_over_scale" ...
    "dreal_over_scale" "dimag_over_scale" "local_abs_over_scale"];
model.inputChannels = numel(model.featureNames);
model.outputSize = 2;
model.maxResidualNorm = 1.25;
model.applyGain = 0.50;

layers = [
    sequenceInputLayer(model.inputChannels, "Name", "input", "Normalization", "none")
    convolution1dLayer(7, 12, "Padding", "same", "Name", "conv_context")
    reluLayer("Name", "relu1")
    convolution1dLayer(5, 16, "Padding", "same", "Name", "conv_mid")
    reluLayer("Name", "relu2")
    convolution1dLayer(3, 12, "Padding", "same", "Name", "conv_refine")
    reluLayer("Name", "relu3")
    convolution1dLayer(1, model.outputSize, "Padding", "same", "Name", "conv_out")
    ];

model.net = dlnetwork(layers);
model.inputMean = zeros(1, model.inputChannels);
model.inputStd = ones(1, model.inputChannels);
end
