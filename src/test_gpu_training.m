%% test_gpu_training.m - 测试GPU训练功能
%
% 此脚本测试重写后的CNN和GRU模型是否能正确使用GPU训练
%
% 运行方式（从仓库根目录）：
%   addpath(genpath('src'));
%   test_gpu_training

fprintf('========================================\n');
fprintf('测试Deep Learning Toolbox GPU训练\n');
fprintf('========================================\n\n');

%% 检查GPU可用性
fprintf('检查GPU可用性...\n');
if canUseGPU()
    gpuInfo = gpuDevice();
    fprintf('  GPU可用: %s\n', gpuInfo.Name);
    fprintf('  计算能力: %.1f\n', gpuInfo.ComputeCapability);
    fprintf('  显存: %.1f GB\n', gpuInfo.TotalMemory/1e9);
else
    fprintf('  警告: GPU不可用，将使用CPU训练\n');
end
fprintf('\n');

%% 初始化参数
addpath(genpath(fullfile(fileparts(mfilename('fullpath')), 'link')));
p = default_params();

%% 测试CNN模型创建
fprintf('测试CNN模型创建...\n');
try
    cnnModel = ml_cnn_impulse_model();
    fprintf('  模型名称: %s\n', cnnModel.name);
    fprintf('  模型类型: %s\n', cnnModel.type);
    fprintf('  输入通道: %d\n', cnnModel.inputChannels);
    fprintf('  输出大小: %d\n', cnnModel.outputSize);
    fprintf('  网络层数: %d\n', numel(cnnModel.net.Layers));
    fprintf('  CNN模型创建成功\n');
catch ME
    fprintf('  CNN模型创建失败: %s\n', ME.message);
end
fprintf('\n');

%% 测试GRU模型创建
fprintf('测试GRU模型创建...\n');
try
    gruModel = ml_gru_impulse_model();
    fprintf('  模型名称: %s\n', gruModel.name);
    fprintf('  模型类型: %s\n', gruModel.type);
    fprintf('  隐藏层大小: %d\n', gruModel.hiddenSize);
    fprintf('  输出大小: %d\n', gruModel.outputSize);
    fprintf('  网络层数: %d\n', numel(gruModel.net.Layers));
    fprintf('  GRU模型创建成功\n');
catch ME
    fprintf('  GRU模型创建失败: %s\n', ME.message);
end
fprintf('\n');

%% 测试CNN训练（小规模）
fprintf('测试CNN训练（小规模）...\n');
try
    tic;
    [cnnTrained, cnnReport] = ml_train_cnn_impulse(p, ...
        'nBlocks', 20, 'blockLen', 256, 'epochs', 3, ...
        'batchSize', 8, 'verbose', true);
    trainTime = toc;
    fprintf('  训练环境: %s\n', cnnReport.executionEnvironment);
    fprintf('  训练时间: %.1f 秒\n', trainTime);
    fprintf('  最终损失: %.4f\n', cnnReport.finalLoss);
    fprintf('  检测率(Pd): %.3f\n', cnnReport.pdEst);
    fprintf('  虚警率(Pfa): %.3f\n', cnnReport.pfaEst);
    fprintf('  CNN训练成功\n');
catch ME
    fprintf('  CNN训练失败: %s\n', ME.message);
    disp(getReport(ME));
end
fprintf('\n');

%% 测试GRU训练（小规模）
fprintf('测试GRU训练（小规模）...\n');
try
    tic;
    [gruTrained, gruReport] = ml_train_gru_impulse(p, ...
        'nBlocks', 15, 'blockLen', 128, 'epochs', 3, ...
        'batchSize', 8, 'verbose', true);
    trainTime = toc;
    fprintf('  训练环境: %s\n', gruReport.executionEnvironment);
    fprintf('  训练时间: %.1f 秒\n', trainTime);
    fprintf('  最终损失: %.4f\n', gruReport.finalLoss);
    fprintf('  检测率(Pd): %.3f\n', gruReport.pdEst);
    fprintf('  虚警率(Pfa): %.3f\n', gruReport.pfaEst);
    fprintf('  GRU训练成功\n');
catch ME
    fprintf('  GRU训练失败: %s\n', ME.message);
    disp(getReport(ME));
end
fprintf('\n');

%% 测试推理
fprintf('测试模型推理...\n');
try
    % 生成测试数据
    testLen = 100;
    testSym = randn(testLen, 1) + 1j*randn(testLen, 1);

    % CNN推理
    [maskCnn, relCnn, cleanCnn, pCnn] = ml_cnn_impulse_detect(testSym, cnnTrained);
    fprintf('  CNN推理成功，检测到 %d/%d 脉冲\n', sum(maskCnn), testLen);

    % GRU推理
    [maskGru, relGru, cleanGru, pGru] = ml_gru_impulse_detect(testSym, gruTrained);
    fprintf('  GRU推理成功，检测到 %d/%d 脉冲\n', sum(maskGru), testLen);
catch ME
    fprintf('  推理失败: %s\n', ME.message);
end
fprintf('\n');

%% 总结
fprintf('========================================\n');
fprintf('测试完成\n');
fprintf('========================================\n');
