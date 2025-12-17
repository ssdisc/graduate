function [model, report] = ml_train_image_denoise(p, varargin)
%ML_TRAIN_IMAGE_DENOISE  训练图像降噪DnCNN模型。
%
% 用法:
%   [model, report] = ml_train_image_denoise(p)
%   [model, report] = ml_train_image_denoise(p, 'epochs', 50, 'nImages', 100)
%
% 输入:
%   p - 链路参数结构体（用于生成训练数据）
%
% 可选参数:
%   epochs      - 训练轮数，默认30
%   nImages     - 训练图像数量，默认50
%   depth       - 网络深度，默认17
%   filters     - 滤波器数量，默认64
%   patchSize   - 训练patch大小，默认64
%   batchSize   - 批大小，默认32
%   lr          - 学习率，默认1e-3
%   verbose     - 是否显示进度，默认true
%
% 输出:
%   model  - 训练好的模型
%   report - 训练报告

ip = inputParser;
addParameter(ip, 'epochs', 30, @isnumeric);
addParameter(ip, 'nImages', 50, @isnumeric);
addParameter(ip, 'depth', 17, @isnumeric);
addParameter(ip, 'filters', 64, @isnumeric);
addParameter(ip, 'patchSize', 64, @isnumeric);
addParameter(ip, 'batchSize', 32, @isnumeric);
addParameter(ip, 'lr', 1e-3, @isnumeric);
addParameter(ip, 'verbose', true, @islogical);
addParameter(ip, 'useGPU', true, @islogical);  % 是否使用GPU
parse(ip, varargin{:});

opts = ip.Results;

% 检查GPU可用性
useGPU = opts.useGPU && canUseGPU();
if opts.verbose
    fprintf('=== 训练图像降噪DnCNN模型 ===\n');
    if useGPU
        fprintf('使用GPU加速训练\n');
        gpuInfo = gpuDevice;
        fprintf('GPU: %s (%.1f GB)\n', gpuInfo.Name, gpuInfo.TotalMemory/1e9);
    else
        fprintf('使用CPU训练\n');
    end
end

% 创建模型
model = ml_image_denoise_model('depth', opts.depth, 'filters', opts.filters);
model.patchSize = opts.patchSize;
model.batchSize = opts.batchSize;
model.learningRate = opts.lr;

% 生成训练数据
if opts.verbose
    fprintf('生成训练数据...\n');
end

[cleanPatches, noisyPatches] = generate_training_data(p, opts);

nPatches = size(cleanPatches, 4);
if opts.verbose
    fprintf('生成了 %d 个训练patch\n', nPatches);
end

% 计算残差标签（噪声）
residualPatches = noisyPatches - cleanPatches;

% 转换为dlarray
XTrain = dlarray(single(noisyPatches), 'SSCB');
YTrain = single(residualPatches);

% 如果使用GPU，将数据和网络移到GPU
if useGPU
    XTrain = gpuArray(XTrain);
    YTrain = gpuArray(YTrain);
    model.net = dlupdate(@gpuArray, model.net);
end

% 训练参数
numEpochs = opts.epochs;
miniBatchSize = opts.batchSize;
learnRate = opts.lr;

% 初始化Adam优化器状态
avgGrad = [];
avgSqGrad = [];

% 训练循环
numIterationsPerEpoch = floor(nPatches / miniBatchSize);
lossHistory = zeros(numEpochs, 1);

if opts.verbose
    fprintf('开始训练，共 %d 轮...\n', numEpochs);
end

for epoch = 1:numEpochs
    % 打乱数据
    idx = randperm(nPatches);

    epochLoss = 0;

    for iter = 1:numIterationsPerEpoch
        % 获取mini-batch
        batchIdx = idx((iter-1)*miniBatchSize+1 : iter*miniBatchSize);
        XBatch = XTrain(:,:,:,batchIdx);
        YBatch = YTrain(:,:,:,batchIdx);

        % 计算梯度和损失
        [loss, gradients] = dlfeval(@modelLoss, model.net, XBatch, YBatch);

        % 更新网络参数（Adam）
        [model.net, avgGrad, avgSqGrad] = adamupdate(model.net, gradients, ...
            avgGrad, avgSqGrad, (epoch-1)*numIterationsPerEpoch + iter, learnRate);

        epochLoss = epochLoss + double(extractdata(loss));
    end

    lossHistory(epoch) = epochLoss / numIterationsPerEpoch;

    if opts.verbose && (mod(epoch, 5) == 0 || epoch == 1)
        fprintf('Epoch %3d/%d, Loss: %.6f\n', epoch, numEpochs, lossHistory(epoch));
    end

    % 学习率衰减
    if mod(epoch, 10) == 0
        learnRate = learnRate * 0.5;
    end
end

model.trained = true;

% 如果使用了GPU，将网络移回CPU以便保存
if useGPU
    model.net = dlupdate(@gather, model.net);
end

% 生成报告
report = struct();
report.epochs = numEpochs;
report.finalLoss = lossHistory(end);
report.lossHistory = lossHistory;
report.nPatches = nPatches;
report.patchSize = opts.patchSize;
report.useGPU = useGPU;

if opts.verbose
    fprintf('训练完成！最终损失: %.6f\n', report.finalLoss);
end

end

%% 损失函数
function [loss, gradients] = modelLoss(net, X, Y)
% 前向传播
YPred = forward(net, X);

% MSE损失
loss = mean((YPred - dlarray(Y, 'SSCB')).^2, 'all');

% 计算梯度
gradients = dlgradient(loss, net.Learnables);
end

%% 生成训练数据
function [cleanPatches, noisyPatches] = generate_training_data(p, opts)
%GENERATE_TRAINING_DATA  使用合成噪声生成训练数据对。
%
% 使用高斯噪声 + 椒盐噪声模拟通信链路中的噪声和脉冲干扰误码。

patchSize = opts.patchSize;
nImages = opts.nImages;

% 预分配
patchesPerImage = 16;  % 每张图像提取的patch数
totalPatches = nImages * patchesPerImage;
cleanPatches = zeros(patchSize, patchSize, 1, totalPatches, 'single');
noisyPatches = zeros(patchSize, patchSize, 1, totalPatches, 'single');

patchIdx = 0;

% 噪声级别范围
gaussianSigmaRange = [0.01, 0.15];  % 高斯噪声标准差范围
saltPepperRange = [0.001, 0.05];     % 椒盐噪声密度范围

for imgIdx = 1:nImages
    % 加载源图像
    imgTx = load_source_image(p.source);

    % 转换为double [0,1]
    if isa(imgTx, 'uint8')
        imgClean = double(imgTx) / 255;
    else
        imgClean = double(imgTx);
    end

    % 确保是灰度图
    if ndims(imgClean) == 3
        imgClean = rgb2gray(imgClean);
    end

    % 随机选择噪声级别
    gaussianSigma = gaussianSigmaRange(1) + rand() * (gaussianSigmaRange(2) - gaussianSigmaRange(1));
    saltPepperDensity = saltPepperRange(1) + rand() * (saltPepperRange(2) - saltPepperRange(1));

    % 添加合成噪声
    imgNoisy = add_synthetic_noise(imgClean, gaussianSigma, saltPepperDensity);

    % 提取随机patch
    [H, W] = size(imgClean);
    for k = 1:patchesPerImage
        % 随机位置
        i = randi(max(1, H - patchSize + 1));
        j = randi(max(1, W - patchSize + 1));

        patchIdx = patchIdx + 1;
        cleanPatches(:,:,1,patchIdx) = imgClean(i:i+patchSize-1, j:j+patchSize-1);
        noisyPatches(:,:,1,patchIdx) = imgNoisy(i:i+patchSize-1, j:j+patchSize-1);
    end

    if opts.verbose && mod(imgIdx, 10) == 0
        fprintf('  处理图像 %d/%d\n', imgIdx, nImages);
    end
end

% 裁剪到实际使用的patch数
cleanPatches = cleanPatches(:,:,:,1:patchIdx);
noisyPatches = noisyPatches(:,:,:,1:patchIdx);

end

%% 添加合成噪声
function imgNoisy = add_synthetic_noise(imgClean, gaussianSigma, saltPepperDensity)
%ADD_SYNTHETIC_NOISE  添加高斯噪声和椒盐噪声模拟通信链路噪声。

% 1. 添加高斯噪声（模拟AWGN信道）
imgNoisy = imgClean + gaussianSigma * randn(size(imgClean));

% 2. 添加椒盐噪声（模拟脉冲干扰导致的误码）
mask = rand(size(imgClean));
imgNoisy(mask < saltPepperDensity/2) = 0;  % 椒噪声（黑点）
imgNoisy(mask > 1 - saltPepperDensity/2) = 1;  % 盐噪声（白点）

% 3. 裁剪到[0,1]范围
imgNoisy = max(0, min(1, imgNoisy));

end

%% 通过链路传输图像
function imgRx = transmit_image_through_link(imgTx, p, ebN0dB)
%TRANSMIT_IMAGE_THROUGH_LINK  模拟图像通过通信链路传输。

% 转换为uint8用于传输
if max(imgTx(:)) <= 1
    imgTxU8 = uint8(imgTx * 255);
else
    imgTxU8 = uint8(imgTx);
end

% 图像转比特
[payloadBits, meta] = image_to_payload_bits(imgTxU8, p.payload);

% 构建帧头
[headerBits, ~] = build_header_bits(meta, p.frame.magic16);

% 组装数据
dataBitsTx = [headerBits; payloadBits];

% 扰码
dataBitsTxScr = scramble_bits(dataBitsTx, p.scramble);

% FEC编码
codedBits = fec_encode(dataBitsTxScr, p.fec);

% 交织
[codedBitsInt, intState] = interleave_bits(codedBits, p.interleaver);

% 调制
[dataSymTx, modInfo] = modulate_bits(codedBitsInt, p.mod);

% 计算噪声功率
% 码率1/2，BPSK每符号1比特
codeRate = 0.5;
bitsPerSym = 1;
EbN0 = 10^(ebN0dB/10);
N0 = ebn0_to_n0(EbN0, codeRate, bitsPerSym, 1.0);

% 通过信道
[rxSym, ~] = channel_bg_impulsive(dataSymTx, N0, p.channel);

% 脉冲抑制（使用默认方法）
[rMit, reliability] = mitigate_impulses(rxSym, "blanking", p.mitigation);

% 软解调
demodSoft = demodulate_to_softbits(rMit, p.mod, p.fec, p.softMetric, reliability);

% FEC解码
decodedBits = fec_decode(demodSoft, p.fec);

% 解交织（实际上解码后不需要，这里简化处理）
% 解扰码
dataBitsRxScr = decodedBits;
dataBitsRx = descramble_bits(dataBitsRxScr, p.scramble);

% 解析帧
[payloadBitsRx, parsedMeta, okHeader] = parse_frame_bits(dataBitsRx, p.frame.magic16);

% 重建图像
if okHeader && numel(payloadBitsRx) >= double(meta.rows) * double(meta.cols) * 8
    imgRxU8 = payload_bits_to_image(payloadBitsRx, meta);
    imgRx = double(imgRxU8) / 255;
else
    % 解析失败，添加随机噪声模拟
    imgRx = imgTx + 0.1 * randn(size(imgTx));
    imgRx = max(0, min(1, imgRx));
end

end
