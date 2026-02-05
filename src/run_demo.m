function run_demo()
%RUN_DEMO  赛道一（初赛）基准MATLAB仿真。
%
% 用法（从仓库根目录）：
%   addpath(genpath('src'));
%   run_demo

addpath(genpath(fullfile(fileparts(mfilename('fullpath')), 'link')));

p = default_params();

% 快速演示设置（按需修改）
p.sim.ebN0dBList = 0:2:10;
p.sim.nFramesPerPoint = 1;
p.sim.saveFigures = true;

%% 训练ML模型（可选，设为false跳过以加快速度）
trainML = false;

if trainML
    fprintf('========================================\n');
    fprintf('训练ML脉冲检测模型...\n');
    fprintf('========================================\n\n');

    % 训练CNN（快速模式）
    fprintf('训练CNN模型...\n');
    [p.mitigation.mlCnn, ~] = ml_train_cnn_impulse(p, ...
        'nBlocks', 150, 'blockLen', 1024, 'epochs', 20, 'verbose', true);
    fprintf('\n');

    % 训练GRU（快速模式）
    fprintf('训练GRU模型...\n');
    [p.mitigation.mlGru, ~] = ml_train_gru_impulse(p, ...
        'nBlocks', 100, 'blockLen', 256, 'epochs', 15, 'verbose', true);
    fprintf('\n');

    % 训练图像降噪DnCNN模型
    fprintf('训练图像降噪DnCNN模型...\n');
    [denoiseModel, ~] = ml_train_image_denoise(p, ...
        'epochs', 20, 'nImages', 30, 'useGPU', true, 'verbose', true);
    p.denoise.enable = true;
    p.denoise.model = denoiseModel;
    fprintf('\n');
else
    % 不训练时，从方法列表中移除未训练的ML模型
    p.mitigation.methods = ["none", "blanking", "clipping", "ml_blanking"];
    fprintf('跳过ML模型训练，仅使用传统方法\n\n');
end

%% 运行仿真
fprintf('========================================\n');
fprintf('运行链路仿真...\n');
fprintf('========================================\n\n');

results = simulate(p);

disp(results.summary);

%% 显示降噪效果
if isfield(results, 'denoise') && results.denoise.enabled
    fprintf('\n========================================\n');
    fprintf('图像降噪效果（按抑制方法）\n');
    fprintf('========================================\n');

    methods = p.mitigation.methods;
    nMethods = numel(methods);
    nEbN0 = numel(p.sim.ebN0dBList);

    % 显示每种方法的降噪增益
    for m = 1:nMethods
        methodName = methods(m);
        psnrOrig = results.psnr(m, :);
        psnrDen = results.denoise.psnr(m, :);
        psnrGain = results.denoise.psnrGain(m, :);

        % 只显示有效数据
        validIdx = ~isnan(psnrGain) & ~isinf(psnrGain);
        if any(validIdx)
            avgGain = mean(psnrGain(validIdx));
            fprintf('%s: 平均PSNR增益 %+.2f dB\n', methodName, avgGain);
        end
    end
end
end
