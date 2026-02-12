function p = default_params()
%DEFAULT_PARAMS  赛道一基准链路的默认参数集（仿真控制置前，其余按链路顺序）。

p = struct();

% 全局随机种子
p.rngSeed = 1;

%% 仿真控制
p.sim = struct();
p.sim.ebN0dBList = 0:2:10;
p.sim.nFramesPerPoint = 1;
p.sim.saveFigures = true;
p.sim.resultsDir = fullfile(pwd, "results");
p.sim.exampleEbN0dB = inf; % 示例图默认取最高Eb/N0；设为具体值时取最近点

%% 发送端（TX）
% 1) 图像源
p.source = struct();
p.source.useBuiltinImage = false;
p.source.imagePath = "images/maodie.png"; % useBuiltinImage=false时使用
p.source.resizeTo = []; % [行 列]，[]保持原始尺寸
p.source.grayscale = false;

% 2) 混沌加密（图像层面的置乱+扩散加密）
p.chaosEncrypt = struct();
p.chaosEncrypt.enable = true;          % 是否启用混沌加密
p.chaosEncrypt.arnoldIter = 5;         % Arnold置乱迭代次数
p.chaosEncrypt.chaosMethod = 'logistic'; % 混沌映射: 'logistic', 'henon', 'tent'
p.chaosEncrypt.diffusionRounds = 2;    % 扩散轮数
% 混沌参数（密钥）- Logistic映射
p.chaosEncrypt.chaosParams = struct();
p.chaosEncrypt.chaosParams.mu = 3.9999;              % Logistic参数 (3.57 < mu <= 4)
p.chaosEncrypt.chaosParams.x0 = 0.1234567890123456;  % 初值（密钥的一部分）

% 3) 载荷格式（图像的原始字节）
p.payload = struct();
p.payload.bitsPerPixel = 8;

% 4) 前导/帧
p.frame = struct();
p.frame.preambleLength = 127; % 比特（BPSK），PN序列
p.frame.magic16 = hex2dec('A55A');

% 5) 扰码（用作白化/轻量加密）
p.scramble = struct();
p.scramble.enable = true;
p.scramble.pnPolynomial = [1 0 0 1 1]; % x^4 + x + 1
p.scramble.pnInit = [0 0 0 1];         % 非零初始值

% 6) 信道编码（卷积码，码率1/2）
p.fec = struct();
p.fec.trellis = poly2trellis(7, [171 133]);
p.fec.tracebackDepth = 34;
p.fec.opmode = 'trunc'; % 'trunc'简化处理
p.fec.decisionType = 'soft'; % 'hard' | 'soft'
p.fec.softBits = 3; % vitdec中的nsdec(1..13)，decisionType='soft'时使用

% 7) 交织（块交织器）
p.interleaver = struct();
p.interleaver.enable = true;
p.interleaver.nRows = 64;

% 8) 调制
p.mod = struct();
p.mod.type = 'BPSK'; % 'BPSK' | 'QPSK'（默认BPSK）

% 9) 跳频（Frequency Hopping）
p.fh = struct();
p.fh.enable = true;              % 是否启用跳频
p.fh.nFreqs = 8;                 % 跳频频点数量
p.fh.symbolsPerHop = 64;         % 每跳的符号数（跳频速率 = 符号率/symbolsPerHop）
p.fh.sequenceType = 'pn';        % 'pn' | 'linear' | 'random'
p.fh.pnPolynomial = [1 0 0 1 1]; % 跳频PN序列多项式 (x^4 + x + 1)
p.fh.pnInit = [1 0 0 1];         % 跳频PN序列初始状态
% 频率集合（归一化频率，相对于符号率）
% 例如：8个频点均匀分布在 [-0.35, 0.35]
p.fh.freqSet = linspace(-0.35, 0.35, p.fh.nFreqs);

%% 信道
% AWGN + 伯努利-高斯脉冲噪声
p.channel = struct();
p.channel.maxDelaySymbols = 200; % 随机前导零用于测试帧同步
p.channel.impulseProb = 0.01;    % 每个符号产生脉冲的概率
p.channel.impulseToBgRatio = 50; % 脉冲方差 = 比值 * 背景方差

%% 接收端（RX）
% 10) 脉冲抑制
p.mitigation = struct();
p.mitigation.methods = ["none" "blanking" "clipping" "ml_blanking" "ml_cnn" "ml_gru"]; % 运行并比较
p.mitigation.thresholdStrategy = "median"; % "median" | "fixed"
p.mitigation.thresholdAlpha = 4.0; % T = alpha * median(abs(r))
p.mitigation.thresholdFixed = 3.0; % thresholdStrategy="fixed"时使用

modelDir = fullfile(pwd, "models");
if ~exist(modelDir, 'dir')
    repoRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    altModelDir = fullfile(repoRoot, "models");
    if exist(altModelDir, 'dir')
        modelDir = altModelDir;
    end
end

p.mitigation.ml = load_pretrained_model(fullfile(modelDir, "impulse_lr_model.mat"), @ml_impulse_lr_model);
p.mitigation.mlCnn = load_pretrained_model(fullfile(modelDir, "impulse_cnn_model.mat"), @ml_cnn_impulse_model);
p.mitigation.mlGru = load_pretrained_model(fullfile(modelDir, "impulse_gru_model.mat"), @ml_gru_impulse_model);

% 11) 软量化（用于vitdec 'soft'）
p.softMetric = struct();
p.softMetric.clipA = 4.0; % 量化前将每比特度量裁剪到[-A, A]

%% 截获/隐蔽分析
% 窃听者/截获者（Eve）
p.eve = struct();
p.eve.enable = true;
% Eve Eb/N0 = Bob Eb/N0 + 偏移(dB)。负值表示Eve信道更差。
p.eve.ebN0dBOffset = -6;
% Eve接收机知识模型：
%   "known"     : 知道扰码密钥（最佳截获情况）
%   "none"      : 忽略扰码（不解扰）
%   "wrong_key" : 使用错误的扰码密钥（显示乱码图像）
p.eve.scrambleAssumption = "wrong_key";
% Eve对跳频序列的知识：
%   "known"     : 知道跳频序列（能正确解跳）
%   "none"      : 不知道跳频（不解跳，信号严重失真）
%   "partial"   : 部分知道（使用错误的初始状态）
p.eve.fhAssumption = "none";
% Eve对混沌加密的知识：
%   "known"     : 知道混沌密钥（能正确解密）
%   "none"      : 不知道混沌加密（看到加密图像）
%   "wrong_key" : 使用错误的混沌密钥（解密失败）
p.eve.chaosAssumption = "none";

% 隐蔽/低截获概率支持（监视者检测）
p.covert = struct();
p.covert.enable = true;
p.covert.warden = struct();
p.covert.warden.enable = true;
% 敌方的能量检测器（辐射计）设置
p.covert.warden.pfaTarget = 0.01;
p.covert.warden.nObs = 4096;   % 观测窗口（符号数）
p.covert.warden.nTrials = 200; % 蒙特卡洛试验次数用于估计Pd/Pfa

end

function model = load_pretrained_model(modelPath, defaultFactory)
if ~exist(modelPath, 'file')
    [modelDir, baseName, ~] = fileparts(modelPath);
    candidates = dir(fullfile(modelDir, [baseName, "_*.mat"]));
    if ~isempty(candidates)
        [~, idx] = max([candidates.datenum]);
        modelPath = fullfile(modelDir, candidates(idx).name);
    end
end
if exist(modelPath, 'file')
    s = load(modelPath, 'model');
    if isfield(s, 'model') && ~isempty(s.model)
        model = s.model;
        return;
    end
end
model = defaultFactory();
end
