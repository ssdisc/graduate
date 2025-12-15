%% demo_ml_impulse_mitigation.m
% 演示脚本：展示基于ML的脉冲抑制与软判决译码。
%
% 本脚本演示：
%   1. 训练CNN/GRU脉冲检测器
%   2. 比较不同抑制方法
%   3. 软可靠性加权用于Viterbi译码器

clear; clc; close all;
addpath(genpath('src'));

fprintf('==============================================\n');
fprintf('基于ML的脉冲抑制演示\n');
fprintf('==============================================\n\n');

%% 设置参数
p = default_params();

% 减小仿真规模以加快演示速度
p.sim.ebN0dBList = 0:3:12;
p.sim.nFramesPerPoint = 2;
p.source.resizeTo = [64 64];  % 使用较小图像以提高速度

% 聚焦于比较不同方法
p.mitigation.methods = ["none", "blanking", "ml_blanking", "ml_cnn", "ml_gru"];

%% 快速训练ML模型
fprintf('步骤1：训练ML模型（快速模式）...\n');
fprintf('----------------------------------------\n');

% 训练CNN（演示用精简版）
[p.mitigation.mlCnn, cnnReport] = ml_train_cnn_impulse(p, ...
    'nBlocks', 100, 'blockLen', 1024, 'epochs', 15, 'verbose', true);

fprintf('\n');

% 训练GRU（演示用精简版）
[p.mitigation.mlGru, gruReport] = ml_train_gru_impulse(p, ...
    'nBlocks', 80, 'blockLen', 256, 'epochs', 10, 'verbose', true);

%% 运行仿真
fprintf('\n');
fprintf('步骤2：运行链路仿真...\n');
fprintf('----------------------------------------\n');

results = simulate(p);

%% 显示结果
fprintf('\n');
fprintf('步骤3：结果摘要\n');
fprintf('----------------------------------------\n');
fprintf('\n各Eb/N0下的误码率（BER）：\n');
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

fprintf('\n各Eb/N0下的PSNR（dB）：\n');
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

%% 绘制结果
figure('Position', [100, 100, 1200, 500]);

% BER曲线
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
ylabel('误码率');
title('BER比较');
legend('Location', 'southwest');
ylim([1e-5, 1]);

% PSNR曲线
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
title('图像质量比较');
legend('Location', 'southeast');

sgtitle('基于ML的脉冲抑制性能');

fprintf('\n');
fprintf('演示完成！请查看图形以比较BER和PSNR。\n');
fprintf('\n主要观察结果：\n');
fprintf('  - ML方法（CNN、GRU）应优于简单置零\n');
fprintf('  - 软可靠性加权改善译码器性能\n');
fprintf('  - CNN更快，GRU更好地捕捉时序模式\n');
