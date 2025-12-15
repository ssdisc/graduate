%% demo_ml_impulse_mitigation.m
% Demo script showing ML-based impulse mitigation with soft decoding.
%
% This demonstrates:
%   1. Training CNN/GRU impulse detectors
%   2. Comparing different mitigation methods
%   3. Soft reliability weighting for Viterbi decoder

clear; clc; close all;
addpath(genpath('src'));

fprintf('==============================================\n');
fprintf('ML-Based Impulse Mitigation Demo\n');
fprintf('==============================================\n\n');

%% Setup parameters
p = default_params();

% Reduce simulation size for quick demo
p.sim.ebN0dBList = 0:3:12;
p.sim.nFramesPerPoint = 2;
p.source.resizeTo = [64 64];  % Smaller image for speed

% Focus on comparing methods
p.mitigation.methods = ["none", "blanking", "ml_blanking", "ml_cnn", "ml_gru"];

%% Quick training of ML models
fprintf('Step 1: Training ML models (quick mode)...\n');
fprintf('----------------------------------------\n');

% Train CNN (reduced for demo)
[p.mitigation.mlCnn, cnnReport] = ml_train_cnn_impulse(p, ...
    'nBlocks', 100, 'blockLen', 1024, 'epochs', 15, 'verbose', true);

fprintf('\n');

% Train GRU (reduced for demo)
[p.mitigation.mlGru, gruReport] = ml_train_gru_impulse(p, ...
    'nBlocks', 80, 'blockLen', 256, 'epochs', 10, 'verbose', true);

%% Run simulation
fprintf('\n');
fprintf('Step 2: Running link simulation...\n');
fprintf('----------------------------------------\n');

results = simulate(p);

%% Display results
fprintf('\n');
fprintf('Step 3: Results Summary\n');
fprintf('----------------------------------------\n');
fprintf('\nBit Error Rate (BER) at each Eb/N0:\n');
fprintf('%-12s', 'Eb/N0 (dB)');
for m = 1:numel(results.methods)
    fprintf('%-15s', results.methods(m));
end
fprintf('\n');

for ie = 1:numel(results.ebN0dB)
    fprintf('%-12.1f', results.ebN0dB(ie));
    for m = 1:numel(results.methods)
        if results.ber(m, ie) < 1e-6
            fprintf('%-15s', '<1e-6');
        else
            fprintf('%-15.2e', results.ber(m, ie));
        end
    end
    fprintf('\n');
end

fprintf('\nPSNR (dB) at each Eb/N0:\n');
fprintf('%-12s', 'Eb/N0 (dB)');
for m = 1:numel(results.methods)
    fprintf('%-15s', results.methods(m));
end
fprintf('\n');

for ie = 1:numel(results.ebN0dB)
    fprintf('%-12.1f', results.ebN0dB(ie));
    for m = 1:numel(results.methods)
        if isnan(results.psnr(m, ie))
            fprintf('%-15s', 'N/A');
        else
            fprintf('%-15.1f', results.psnr(m, ie));
        end
    end
    fprintf('\n');
end

%% Plot results
figure('Position', [100, 100, 1200, 500]);

% BER plot
subplot(1, 2, 1);
colors = lines(numel(results.methods));
markers = {'o', 's', 'd', '^', 'v'};
for m = 1:numel(results.methods)
    semilogy(results.ebN0dB, results.ber(m, :), ...
        ['-' markers{mod(m-1,5)+1}], 'Color', colors(m,:), ...
        'LineWidth', 1.5, 'MarkerSize', 8, 'DisplayName', results.methods(m));
    hold on;
end
grid on;
xlabel('Eb/N0 (dB)');
ylabel('Bit Error Rate');
title('BER Comparison');
legend('Location', 'southwest');
ylim([1e-5, 1]);

% PSNR plot
subplot(1, 2, 2);
for m = 1:numel(results.methods)
    plot(results.ebN0dB, results.psnr(m, :), ...
        ['-' markers{mod(m-1,5)+1}], 'Color', colors(m,:), ...
        'LineWidth', 1.5, 'MarkerSize', 8, 'DisplayName', results.methods(m));
    hold on;
end
grid on;
xlabel('Eb/N0 (dB)');
ylabel('PSNR (dB)');
title('Image Quality Comparison');
legend('Location', 'southeast');

sgtitle('ML-Based Impulse Mitigation Performance');

fprintf('\n');
fprintf('Demo complete! Check the figure for BER and PSNR comparison.\n');
fprintf('\nKey observations:\n');
fprintf('  - ML methods (CNN, GRU) should outperform simple blanking\n');
fprintf('  - Soft reliability weighting improves decoder performance\n');
fprintf('  - CNN is faster, GRU captures temporal patterns better\n');
