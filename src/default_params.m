function p = default_params(opts)
%DEFAULT_PARAMS  赛道一基准链路的默认参数集（仿真控制置前，其余按链路顺序）。

arguments
    opts.strictModelLoad (1,1) logical = true
    opts.requireTrainedMlModels (1,1) logical = true
    opts.allowBatchModelFallback (1,1) logical = true
end

p = struct();

% 全局随机种子
p.rngSeed = 1;

%% 仿真控制
p.sim = struct();
p.sim.ebN0dBList = -2:2:16;
p.sim.nFramesPerPoint = 5;
p.sim.saveFigures = true;
p.sim.resultsDir = fullfile(pwd, "results");
p.sim.exampleEbN0dB = inf; % 示例图默认取最高Eb/N0；设为具体值时取最近点
% 并行加速（主链路）：需要 Parallel Computing Toolbox
p.sim.useParallel = true;
p.sim.nWorkers = 16;
p.sim.parallelMode = "methods"; % "methods"(按抑制方法并行) | "frames"(按帧并行)

%% 发送端（TX）
% 1) 图像源
p.source = struct();
p.source.useBuiltinImage = false;
p.source.imagePath = "images/maodie.png"; % useBuiltinImage=false时使用
p.source.resizeTo = []; % [行 列]，[]保持原始尺寸
p.source.grayscale = true; % 开题报告任务1：默认灰度化后再编码

% 2) 混沌加密（图像层面的置乱+扩散加密）
p.chaosEncrypt = struct();
p.chaosEncrypt.enable = true;          % 是否启用混沌加密
p.chaosEncrypt.arnoldIter = 5;         % Arnold置乱迭代次数
p.chaosEncrypt.chaosMethod = 'logistic'; % 混沌映射: 'logistic', 'henon', 'tent'
p.chaosEncrypt.diffusionRounds = 2;    % 扩散轮数
p.chaosEncrypt.packetIndependent = true; % dct比特载荷: 先分包、再逐包独立加密
% 混沌参数（密钥）- Logistic映射
p.chaosEncrypt.chaosParams = struct();
p.chaosEncrypt.chaosParams.mu = 3.9999;              % Logistic参数 (3.57 < mu <= 4)
p.chaosEncrypt.chaosParams.x0 = 0.1234567890123456;  % 初值（密钥的一部分）

% 3) 载荷格式（图像的原始字节）
p.payload = struct();
p.payload.bitsPerPixel = 8;
p.payload.codec = "dct"; % 'raw' | 'dct'
p.payload.dct = struct();
p.payload.dct.blockSize = 8;
p.payload.dct.keepRows = 4;
p.payload.dct.keepCols = 4;
p.payload.dct.quantStep = 16;

% 3.5) 分包传输（最小版本）
p.packet = struct();
p.packet.enable = true;                % 启用图像分包
p.packet.payloadBitsPerPacket = 1024; % 每包载荷比特数（需为8的整数倍）
p.packet.concealLostPackets = true;    % 丢包后图像/块域补偿（仅影响重建图像）
p.packet.concealMode = "blend";      % "nearest" | "blend"

% 4) 前导/帧（默认保留PN前导，优先保证同步稳定性）
p.frame = struct();
p.frame.preambleLength = 127; % 比特（BPSK）
p.frame.preambleType = "pn"; % "pn" | "chaos"
p.frame.preamblePnPolynomial = [1 0 0 0 1 0 0 1]; % x^7 + x^3 + 1（m序列，周期127）
p.frame.preamblePnInit = [0 0 0 0 0 0 1];
p.frame.preambleChaosMethod = "logistic";
p.frame.preambleChaosParams = struct("mu", 3.9999, "x0", 0.2718281828459045);
p.frame.packetSyncLength = 31; % 后续分包短同步字长度（比特/BPSK）
p.frame.packetSyncType = "pn";
p.frame.packetSyncPnPolynomial = [1 0 0 1 0 1]; % x^5 + x^2 + 1（m序列，周期31）
p.frame.packetSyncPnInit = [0 0 0 0 1];
p.frame.packetSyncChaosMethod = "logistic";
p.frame.packetSyncChaosParams = struct("mu", 3.9999, "x0", 0.1414213562373095);
p.frame.resyncIntervalPackets = 1; % 当前主线每包都用长PN前导；短同步字在现接收链路下仅保留为实验选项
p.frame.sessionHeaderMode = "preshared";   % "preshared" | "inline"
p.frame.repeatSessionHeaderOnResync = false; % 即便所有包都用长前导，默认仍只在首包发送会话头以降低开销
p.frame.magic16 = hex2dec('A55A');
p.frame.phyHeaderMode = "compact_fec";   % "compact_fec" | "legacy_repeat"
p.frame.phyMagic16 = hex2dec('3AC5');      % legacy模式使用16bit魔术字；compact_fec默认复用其低8位
p.frame.sessionMagic16 = hex2dec('C7E1');  % inline模式下的会话头魔术字
p.frame.phyHeaderRepeat = 3;               % legacy_repeat模式下的PHY小头每比特重复次数（BPSK）
p.frame.phyHeaderRepeatCompact =2;        % compact_fec模式下的PHY小头编码后重复次数
p.frame.phyHeaderSoftBits = 5;             % compact_fec模式下的PHY小头软判决量化位数
p.frame.phyHeaderPilotLength = 0;          % 默认关闭；当前这版pilot补偿会拉低PHY头成功率
p.frame.phyHeaderPilotPolynomial = [1 0 0 1 1]; % x^4 + x + 1
p.frame.phyHeaderPilotInit = [0 0 0 1];

if ~p.packet.enable
    % compact_fec不携带packetDataBytes，关闭分包时无法从PHY头恢复整图受保护长度。
    p.frame.phyHeaderMode = "legacy_repeat";
end


% 5) 扰码（用作白化/轻量加密）
p.scramble = struct();
p.scramble.enable = true;
p.scramble.pnPolynomial = [1 0 0 0 0 0 0 0 0 1 0 1]; % x^11 + x^2 + 1
p.scramble.pnInit = [0 0 0 0 0 0 0 0 0 0 1];         % 非零初始值

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
p.mod.type = 'BPSK'; % 'BPSK' | 'QPSK' | 'MSK'（默认BPSK）

% 9) 跳频（Frequency Hopping，默认采用混沌跳频）
p.fh = struct();
p.fh.enable = true;              % 是否启用跳频
p.fh.nFreqs = 8;                 % 跳频频点数量
p.fh.symbolsPerHop = 64;         % 每跳的符号数（跳频速率 = 符号率/symbolsPerHop）
p.fh.sequenceType = 'chaos';     % 'pn' | 'chaos' | 'linear' | 'random'
p.fh.pnPolynomial = [1 0 0 0 0 0 0 0 0 1 0 1]; % x^11 + x^2 + 1
p.fh.pnInit = [0 0 0 0 0 0 0 0 0 1 1];         % 跳频PN序列初始状态
% 混沌跳频参数（sequenceType='chaos'时使用）
p.fh.chaosMethod = 'logistic';   % 'logistic' | 'henon' | 'tent'
p.fh.chaosParams = struct();
p.fh.chaosParams.mu = 3.9999;                % logistic/tent参数
p.fh.chaosParams.x0 = 0.3141592653589793;    % 初值（密钥）
p.fh.chaosParams.a = 1.4;                    % henon参数a
p.fh.chaosParams.b = 0.3;                    % henon参数b
p.fh.chaosParams.y0 = 0.123456789;           % henon初值y0
% 频率集合（归一化频率，相对于符号率）
% 例如：8个频点均匀分布在 [-0.35, 0.35]
p.fh.freqSet = linspace(-0.35, 0.35, p.fh.nFreqs);

% 9.5) 波形成型与过采样（复基带）
p.waveform = struct();
p.waveform.enable = true;        % 启用Tx/Rx根升余弦成型与匹配滤波
p.waveform.symbolRateHz = 10e3;  % 符号率（Hz），用于真实采样率/频谱/OBW统计
p.waveform.sps = 4;              % 每符号采样数
p.waveform.rolloff = 0.25;       % RRC滚降系数
p.waveform.spanSymbols = 10;     % RRC滤波器长度（单位：符号）
p.waveform.rxMatchedFilter = true; % 接收端匹配滤波

%% 信道
% 对外配置口径：
% - 时延/周期类参数按“符号”配置
% - 频率类参数按“Hz”配置
% 进入采样级信道前再统一换算到样点/归一化频率。
% AWGN + 伯努利-高斯脉冲噪声（可选叠加更多干扰/同步失配）
p.channel = struct();
p.channel.maxDelaySymbols = 200; % 随机前导零用于测试帧同步
p.channel.impulseProb = 0.01;    % 每个符号产生脉冲的概率
p.channel.impulseToBgRatio = 50; % 脉冲方差 = 比值 * 背景方差
% 可选：单音干扰（窄带强干扰）
p.channel.singleTone = struct();
p.channel.singleTone.enable = false;
p.channel.singleTone.powerMode = "absolute"; % "absolute" | "relative_to_bg"(兼容旧口径)
p.channel.singleTone.power = 0.01;      % 单音固定接收功率（线性值）
p.channel.singleTone.freqHz = 800;      % 单音频率（Hz）
p.channel.singleTone.randomPhase = true;
% 可选：窄带噪声干扰
p.channel.narrowband = struct();
p.channel.narrowband.enable = false;
p.channel.narrowband.powerMode = "absolute"; % "absolute" | "relative_to_bg"(兼容旧口径)
p.channel.narrowband.power = 0.01;       % 窄带噪声固定接收功率（线性值）
p.channel.narrowband.centerHz = 1200;   % 窄带噪声中心频率（Hz）
p.channel.narrowband.bandwidthHz = 800; % 窄带噪声双边带宽（Hz）
% 可选：扫频干扰（线性chirp）
p.channel.sweep = struct();
p.channel.sweep.enable = false;
p.channel.sweep.powerMode = "absolute"; % "absolute" | "relative_to_bg"(兼容旧口径)
p.channel.sweep.power = 0.01;            % 扫频干扰固定接收功率（线性值）
p.channel.sweep.startHz = -2000;        % 起始频率（Hz）
p.channel.sweep.stopHz = 2000;          % 终止频率（Hz）
p.channel.sweep.periodSymbols = 256;    % 单次扫频周期（符号数）
p.channel.sweep.randomPhase = true;
% 可选：同步失配（用于验证“完整同步链路”）
p.channel.syncImpairment = struct();
p.channel.syncImpairment.enable = false;
p.channel.syncImpairment.timingOffsetSymbols = 0.0; % 分数符号偏移（单位：symbol）
p.channel.syncImpairment.phaseOffsetRad = 0.0;    % 初始相位偏移（rad）
% 可选：多径抽头信道（整数抽头时延，复基带等效）
p.channel.multipath = struct();
p.channel.multipath.enable = false;
p.channel.multipath.pathDelaysSymbols = [0 1 2];   % 各径时延（单位：symbol）
p.channel.multipath.pathGainsDb = [0 -12 -18]; % 各径平均增益(dB)
p.channel.multipath.rayleigh = false;        % 启用瑞利衰落（各径独立复高斯系数，每帧随机）

%% 接收端（RX）
% 10) 脉冲抑制
p.mitigation = struct();
p.mitigation.methods = ["none" "fft_notch" "adaptive_notch" "blanking" "clipping" "ml_blanking" "ml_cnn" "ml_gru"]; % 运行并比较
p.mitigation.thresholdStrategy = "median"; % "median" | "fixed"
p.mitigation.thresholdAlpha = 4.0; % T = alpha * median(abs(r))
p.mitigation.thresholdFixed = 3.0; % thresholdStrategy="fixed"时使用
p.mitigation.fftNotch = struct();
p.mitigation.fftNotch.peakRatio = 10.0;   % 峰值/噪声底比阈值
p.mitigation.fftNotch.maxNotches = 2;     % 最大陷波个数
p.mitigation.fftNotch.notchHalfWidth = 1; % 每个陷波半宽(bin)
p.mitigation.fftNotch.minFreqAbs = 0.01;  % 忽略近DC分量
p.mitigation.adaptiveNotch = struct();
p.mitigation.adaptiveNotch.peakRatio = 8.0;
p.mitigation.adaptiveNotch.radius = 0.97;     % 极点半径，越接近1越窄
p.mitigation.adaptiveNotch.minFreqAbs = 0.01;
p.mitigation.adaptiveNotch.stages = 1;
p.mitigation.thresholdCalibration = struct();
p.mitigation.thresholdCalibration.enable = true;
p.mitigation.thresholdCalibration.methods = ["ml_blanking" "ml_cnn" "ml_gru" "ml_cnn_hard" "ml_gru_hard"];
p.mitigation.thresholdCalibration.targetCleanPfa = 0.01; % 目标：在“可信干净”样本上维持的虚警率
p.mitigation.thresholdCalibration.thresholdMinScale = 0.85; % 在线阈值下限 = 基线阈值 * scale
p.mitigation.thresholdCalibration.thresholdMaxScale = 1.35; % 在线阈值上限 = 基线阈值 * scale
p.mitigation.thresholdCalibration.minThresholdAbs = 0.05;
p.mitigation.thresholdCalibration.maxThresholdAbs = 0.995;
p.mitigation.thresholdCalibration.bufferMaxSamples = 4096; % 最近可信样本分数缓冲长度
p.mitigation.thresholdCalibration.minBufferSamples = 48;   % 达到该样本数后才开始更新阈值
p.mitigation.thresholdCalibration.minPreambleTrustedSamples = 16;
p.mitigation.thresholdCalibration.minPacketTrustedSamples = 64;
p.mitigation.thresholdCalibration.preambleUpdateAlpha = 0.45; % 前导校准步长
p.mitigation.thresholdCalibration.packetUpdateAlpha = 0.18;   % 高置信包校准步长
p.mitigation.thresholdCalibration.preambleResidualAlpha = 2.5; % 以前导对齐残差筛可信样本
p.mitigation.thresholdCalibration.packetResidualAlpha = 2.0;   % 以重构残差筛可信样本
p.mitigation.strictModelLoad = opts.strictModelLoad;
p.mitigation.requireTrainedModels = opts.requireTrainedMlModels;

modelDir = fullfile(pwd, "models");
if ~exist(modelDir, 'dir')
    repoRoot = fileparts(fileparts(mfilename('fullpath')));
    altModelDir = fullfile(repoRoot, "models");
    if exist(altModelDir, 'dir')
        modelDir = altModelDir;
    end
end

p.mitigation.ml = load_pretrained_model( ...
    fullfile(modelDir, "impulse_lr_model.mat"), @ml_impulse_lr_model, ...
    "strict", opts.strictModelLoad, ...
    "requireTrained", opts.requireTrainedMlModels, ...
    "allowBatchFallback", opts.allowBatchModelFallback);
p.mitigation.mlCnn = load_pretrained_model( ...
    fullfile(modelDir, "impulse_cnn_model.mat"), @ml_cnn_impulse_model, ...
    "strict", opts.strictModelLoad, ...
    "requireTrained", opts.requireTrainedMlModels, ...
    "allowBatchFallback", opts.allowBatchModelFallback);
p.mitigation.mlGru = load_pretrained_model( ...
    fullfile(modelDir, "impulse_gru_model.mat"), @ml_gru_impulse_model, ...
    "strict", opts.strictModelLoad, ...
    "requireTrained", opts.requireTrainedMlModels, ...
    "allowBatchFallback", opts.allowBatchModelFallback);

% 11) 软量化（用于vitdec 'soft'）
p.softMetric = struct();
p.softMetric.clipA = 4.0; % 量化前将每比特度量裁剪到[-A, A]

% 12) 接收同步（细同步+载波补偿）
p.rxSync = struct();
p.rxSync.fineSearchRadius = 2;     % 整数符号级细搜索窗口半径
p.rxSync.compensateCarrier = true; % 使用前导估计并补偿载波相位/复增益
p.rxSync.equalizeAmplitude = true; % true: 复增益均衡；false: 仅相位补偿
p.rxSync.enableFractionalTiming = true; % 分数符号定时估计
p.rxSync.fractionalRange = 0.5;         % 分数搜索范围（sample）
p.rxSync.fractionalStep = 0.05;         % 分数搜索步长（sample）
p.rxSync.estimateCfo = true;            % 用前导估计残余CFO并前馈补偿
p.rxSync.minCorrPeakToMedian = 0;       % 默认关闭；当前链路需先标定分布后再启用
p.rxSync.minCorrPeakToSecond = 0;       % 默认关闭；当前链路需先标定分布后再启用
p.rxSync.corrExclusionRadius = 4;       % 计算次峰时忽略主峰附近的相关窗口半径
p.rxSync.maxShortSyncMisses = 2;        % 连续短同步失配阈值，超限后切回长前导搜索
% 多径信道估计与均衡（仅在channel.multipath.enable=true时生效）
p.rxSync.multipathEq = struct();
p.rxSync.multipathEq.enable = true;
p.rxSync.multipathEq.method = "mmse";      % "mmse" | "zf"
p.rxSync.multipathEq.nTaps = 9;            % 线性FFE长度（符号数）
p.rxSync.multipathEq.lambdaFactor = 1.0;   % MMSE正则: lambda=lambdaFactor*N0
% 决策导向载波PLL（用于残余频偏/相位跟踪）
p.rxSync.carrierPll = struct();
p.rxSync.carrierPll.enable = true;
p.rxSync.carrierPll.alpha = 0.02;   % 相位环比例增益
p.rxSync.carrierPll.beta = 3e-4;    % 频率环积分增益
p.rxSync.carrierPll.maxFreq = 0.1;  % 归一化角频率上限（rad/sample）
% 早迟门DLL（用于维持符号定时对齐）
p.rxSync.timingDll = struct();
p.rxSync.timingDll.enable = false;
p.rxSync.timingDll.earlyLateSpacing = 0.45;
p.rxSync.timingDll.alpha = 0.03;
p.rxSync.timingDll.beta = 5e-4;
p.rxSync.timingDll.maxOffset = 0.75;
p.rxSync.timingDll.decisionDirected = true;

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
% 三层隐蔽评估:
%   1) energyNp           : 固定P_FA目标的工程检测层
%   2) energyOpt          : 文献常用的最优阈值xi*层
%   3) energyOptUncertain : 独立Warden链路 + 噪声/时延不确定性的更实际层
p.covert.warden.pfaTarget = 0.01;
p.covert.warden.nObs = 4096;   % 观测窗口（采样点）
p.covert.warden.nTrials = 2000; % 蒙特卡洛试验次数
p.covert.warden.useParallel = true; % 是否使用并行池加速Warden蒙特卡洛
p.covert.warden.nWorkers = 16;      % 并行worker数（useParallel=true时）
p.covert.warden.referenceLink = "independent"; % "bob" | "eve" | "independent"
p.covert.warden.ebN0dBOffset = -10; % referenceLink="independent"时，Warden相对Bob的Eb/N0偏移(dB)
p.covert.warden.primaryLayer = "energyOptUncertain"; % 摘要/主判据默认采用的Warden层
p.covert.warden.noiseUncertaintyDb = 1.0; % 第三层：Warden噪声不确定性半宽（±dB）
p.covert.warden.extraDelaySamples = 4096; % 第三层：额外起始时刻不确定性窗口（采样点）
% 层4：跳频窄带Warden（模拟不知跳频序列的实际威胁）
p.covert.warden.fhNarrowband = struct();
p.covert.warden.fhNarrowband.enable = true;   % 启用窄带Warden层
p.covert.warden.fhNarrowband.nFreqs = p.fh.nFreqs; % 跳频频点数（由fh.nFreqs自动同步）
p.covert.warden.fhNarrowband.scanAllBins = true;    % true=扫描所有频点取最大（最强Warden）
% 层5：循环平稳检测器（利用符号率处的循环自相关特征）
p.covert.warden.cyclostationary = struct();
p.covert.warden.cyclostationary.enable = true;  % 启用循环平稳层
p.covert.warden.cyclostationary.sps = p.waveform.sps; % 每符号采样数（由waveform.sps自动同步）

end
