function p = default_params(opts)
%DEFAULT_PARAMS  赛道一基准链路的默认参数集（仿真控制置前，其余按链路顺序）。

arguments
    opts.strictModelLoad (1,1) logical = true
    opts.requireTrainedMlModels (1,1) logical = true
    opts.allowBatchModelFallback (1,1) logical = true
    opts.loadMlModels string = ["lr" "cnn" "gru" "selector" "narrowband" "fh_erasure"]
end

p = struct();

% 全局随机种子
p.rngSeed = 1;

%% 仿真控制
p.sim = struct();
p.sim.nFramesPerPoint = 5;
p.sim.saveFigures = true;
p.sim.resultsDir = fullfile(pwd, "results");
% 并行加速（主链路）：需要 Parallel Computing Toolbox
p.sim.useParallel = true;
p.sim.nWorkers = 16;
p.sim.parallelMode = "frames"; % "methods"(按抑制方法并行) | "frames"(按帧并行)
p.sim.commonRandomFramesAcrossPoints = true; % 同一frameIdx在全Eb/N0/JSR网格复用同一组随机实现，降低曲线抖动

% 发射端记录/评估口径
p.tx = struct();
p.tx.reportLabel = "derived_from_ebn0_jsr_grid";

% 链路预算 / 扫描轴（纯仿真口径）
p.linkBudget = struct();
% 接收端背景噪声功率谱密度（线性值，纯仿真归一化口径）。
p.linkBudget.noisePsdLin = 1.0;
% 主扫描轴1：Bob端目标 Eb/N0（dB）
p.linkBudget.ebN0dBList = 4:2:10;
% 主扫描轴2：目标 J/S（dB），在每个Eb/N0点下缩放已启用干扰的平均总功率
p.linkBudget.jsrDbList = [0];

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
p.packet.payloadBitsPerPacket = 7200; % 每包载荷比特数（需为8的整数倍）
p.packet.concealLostPackets = true;    % 丢包后图像/块域补偿（仅影响重建图像）
p.packet.concealMode = "blend";      % "nearest" | "blend"

% 3.6) 跨包Reed-Solomon外码（按包做系统码，面向整包丢失/擦除恢复）
p.outerRs = struct();
p.outerRs.enable = true;
p.outerRs.dataPacketsPerBlock = 12;    % 每个RS块保护的数据包数 K
p.outerRs.parityPacketsPerBlock = 4;   % 每个RS块附加的校验包数 P

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
p.frame.sessionHeaderMode = "session_frame_repeat";   % "preshared" | "embedded_each_frame" | "session_frame_repeat" | "session_frame_strong"
p.frame.sessionFrameRepeatCount = 3; % dedicated会话帧连续突发次数，仅session_frame_repeat有效，取值3~5
p.frame.sessionStrongRepeat = 8; % strong会话帧：卷积码后逐比特重复次数，等效极低码率FEC
p.frame.magic16 = hex2dec('A55A');
p.frame.phyHeaderMode = "compact_fec";   % "compact_fec" | "legacy_repeat"
p.frame.phyMagic16 = hex2dec('3AC5');      % legacy模式使用16bit魔术字；compact_fec默认复用其低8位
p.frame.sessionMagic16 = hex2dec('C7E1');  % 会话头魔术字（内嵌模式与dedicated会话帧共用）
p.frame.phyHeaderRepeat = 3;               % legacy_repeat模式下的PHY小头每比特重复次数（BPSK）
p.frame.phyHeaderRepeatCompact = 2;        % compact_fec模式下的PHY小头编码后交织重复次数
p.frame.phyHeaderSoftBits = 5;             % compact_fec模式下的PHY小头软判决量化位数
p.frame.phyHeaderSpreadFactor = 1;         % PHY小头DSSS扩频因子；1=关闭
p.frame.phyHeaderSpreadSequenceType = 'pn';
p.frame.phyHeaderSpreadPolynomial = [1 0 0 0 0 0 0 0 0 1 0 1];
p.frame.phyHeaderSpreadInit = [0 0 0 0 0 0 0 0 0 1 1];
p.frame.phyHeaderDiversity = struct();
p.frame.phyHeaderDiversity.enable = true;  % 发送多份完整PHY头，在不同频点逐份解码，抗窄带/瑞利擦除
p.frame.phyHeaderDiversity.copies = 3;
p.frame.phyHeaderFhEnable = true;          % PHY小头固定已知跳频，仅作用于头部
p.frame.phyHeaderFhMode = 'slow';          % 'slow' | 'fast'
p.frame.phyHeaderFhHopsPerSymbol = 2;      % fast模式保留参数；默认禁用
p.frame.phyHeaderFhSymbolsPerHop = 4;      % 占位值；后续会按“单份头部至多扫完一遍频点集”自动重算
p.frame.phyHeaderFhSequenceType = 'linear';
p.frame.phyHeaderFhFreqSet = [];
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

% 6) 信道编码（payload默认卷积码，可切换LDPC；PHY头/会话帧仍使用卷积码）
p.fec = struct();
p.fec.kind = "ldpc";            % "conv" | "ldpc"
p.fec.trellis = poly2trellis(7, [171 133]);
p.fec.tracebackDepth = 34;
p.fec.opmode = 'trunc'; % 'trunc'简化处理
p.fec.decisionType = 'soft'; % 'hard' | 'soft'
p.fec.softBits = 3; % vitdec中的nsdec(1..13)，decisionType='soft'时使用
p.fec.ldpc = struct();
p.fec.ldpc.rate = "1/2";        % DVB-S2/S2X LDPC名义码率
p.fec.ldpc.frameType = "short"; % "short" | "normal" | "medium"
p.fec.ldpc.softBits = 6;        % payload-LDPC软判决量化位数
p.fec.ldpc.maxIterations = 20;
p.fec.ldpc.minSumScalingFactor = 0.75;
p.fec.ldpc.minSumOffset = 0.5;
p.fec.ldpc.termination = "early"; % "early" | "max"
p.fec.ldpc.multithreaded = false;

% 7) 交织（块交织器）
p.interleaver = struct();
p.interleaver.enable = true;
p.interleaver.nRows = 128; % 与当前64符号/跳、QPSK两比特/符号匹配：一跳约128 coded bits
% p.interleaver.nRows = 64;


% 8) 调制
p.mod = struct();
p.mod.type = 'QPSK'; % 'BPSK' | 'QPSK' | 'MSK'（默认QPSK）

% 8.5) 直扩（DSSS，仅作用于payload数据段；PHY头/会话帧保持原样）
p.dsss = struct();
p.dsss.enable = false;
p.dsss.spreadFactor = 4;        % 每个调制符号展开为多少个chip
p.dsss.sequenceType = 'pn';     % 当前仅支持 'pn'
p.dsss.pnPolynomial = [1 0 0 0 0 0 0 0 0 1 0 1]; % x^11 + x^2 + 1
p.dsss.pnInit = [0 0 0 0 0 0 0 0 0 1 1];         % 非零初始状态

% 9) 跳频（Frequency Hopping，默认采用混沌跳频）
p.fh = struct();
p.fh.enable = true;              % 是否启用跳频
p.fh.nFreqs = 8;                 % payload跳频频点数量
p.fh.mode = 'slow';              % 'slow' | 'fast'
p.fh.hopsPerSymbol = 2;          % fast模式保留参数；默认回到慢跳频
p.fh.symbolsPerHop = 64;         % 旧慢跳频基线：每跳64个符号
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
% 默认取“在当前波形成型下互不重叠”的8频点集合。
p.fh.freqSet = [];

% 9.2) payload 单载波块传输：每个慢跳频hop内部加入 CP + 导频，用于 SC-FDE
p.scFde = struct();
p.scFde.enable = true;              % payload按每跳做单载波频域均衡块
p.scFde.cpLenSymbols = 8;           % 吸收成型滤波跳频瞬态(5)+多径扩展(2)
p.scFde.pilotLength = 8;            % 加长导频提升瑞利深衰落下的MSE估计稳定性
p.scFde.pilotPolynomial = [1 0 0 0 1 0 0 1]; % x^7 + x^3 + 1
p.scFde.pilotInit = [0 0 0 0 0 0 1];
p.scFde.lambdaFactor = 1.0;         % FDE MMSE正则: lambda=lambdaFactor*N0
p.scFde.pilotMinAbsGain = 0.05;     % 导频残余标量增益过小时不做除法放大
p.scFde.pilotMseReference = 0.35;   % 导频残差映射软可靠度的参考MSE
p.scFde.fdePilotMseThreshold = 5.00; % 瑞利衰落跳易现高MSE，极大放宽回退阈值
p.scFde.fdePilotMseMargin = 5.00;   % 防止深衰落跳被误判回退到全包线性FFE
p.scFde.minReliability = 0.05;      % 单跳导频很差时的最低软可靠度

% 9.5) 波形成型与过采样（复基带）
p.waveform = struct();
p.waveform.enable = true;        % 启用Tx/Rx根升余弦成型与匹配滤波
p.waveform.sampleRateHz = 100e3; % 显式采样率（Hz）
p.waveform.sps = 10;              % 每符号采样数
p.waveform.symbolRateHz = p.waveform.sampleRateHz / p.waveform.sps; % 由采样率与sps推导
p.waveform.rolloff = 0.25;       % RRC滚降系数
p.waveform.spanSymbols = 10;     % RRC滤波器长度（单位：符号）
p.waveform.rxMatchedFilter = true; % 接收端匹配滤波

fhDefaultWaveform = resolve_waveform_cfg(p);
fhNonOverlapFreqSet = fh_nonoverlap_freq_set(fhDefaultWaveform, p.fh.nFreqs);
p.fh.freqSet = fhNonOverlapFreqSet;
p.frame.phyHeaderFhFreqSet = p.fh.freqSet;
p.frame.phyHeaderFhSymbolsPerHop = phy_header_nondiverse_min_symbols_per_hop(p.frame, p.fh, p.fec);

%% 信道
% 对外配置口径：
% - 时延/周期类参数按“符号”配置
% - 单音/扫频频率按“Hz”配置
% - 窄带噪声按“payload跳频频点间隔个数”配置
% 进入采样级信道前再统一换算到样点/归一化频率。
% AWGN + 伯努利-高斯脉冲噪声（可选叠加更多干扰/同步失配）
p.channel = struct();
p.channel.maxDelaySymbols = 200; % 随机前导零用于测试帧同步
p.channel.impulseProb = 0.03;    % 每个符号触发脉冲的概率；当前默认取中等稀疏度，进入采样级前会换算为每采样概率
p.channel.impulseToBgRatio = 50; % 非JSR重标定时，单次脉冲噪声方差相对背景噪声方差的倍数
p.channel.impulseWeight =1;   % JSR总干扰功率分配权重；weight>0且impulseProb>0时纳入干扰预算
% 可选：单音干扰（窄带强干扰）
p.channel.singleTone = struct();
p.channel.singleTone.enable = false;
p.channel.singleTone.weight = 1;      % JSR总干扰功率分配权重；enable=false时忽略
p.channel.singleTone.freqHz = 1500;      % 单音频率（Hz），默认避开近DC区域并保持在当前训练覆盖范围内
p.channel.singleTone.randomPhase = true;
% 可选：窄带噪声干扰
p.channel.narrowband = struct();
p.channel.narrowband.enable = true;
p.channel.narrowband.weight = 1;      % JSR总干扰功率分配权重；enable=false时忽略
p.channel.narrowband.centerFreqPoints = 1; % 对齐旧基线：约1500 Hz中心频率
p.channel.narrowband.bandwidthFreqPoints = 1; % 对齐旧基线：约1000 Hz双边带宽
% 可选：扫频干扰（线性chirp）
p.channel.sweep = struct();
p.channel.sweep.enable = false;
p.channel.sweep.weight = 1;            % JSR总干扰功率分配权重；enable=false时忽略
p.channel.sweep.startHz = -2000;        % 起始频率（Hz）
p.channel.sweep.stopHz = 2000;          % 终止频率（Hz）
p.channel.sweep.periodSymbols = 256;    % 单次扫频周期（符号数），默认取当前训练范围内的中等值
p.channel.sweep.randomPhase = true;
% 可选：同步失配（用于验证“完整同步链路”）
p.channel.syncImpairment = struct();
p.channel.syncImpairment.enable = false;
p.channel.syncImpairment.timingOffsetSymbols = 0.0; % 分数符号偏移（单位：symbol）
p.channel.syncImpairment.phaseOffsetRad = 0.0;    % 初始相位偏移（rad）
% 可选：多径抽头信道（整数抽头时延，复基带等效）
p.channel.multipath = struct();
p.channel.multipath.enable = true;
p.channel.multipath.pathDelaysSymbols = [0 1 2];   % 各径时延（单位：symbol）
p.channel.multipath.pathGainsDb = [0 -12 -18]; % 各径平均增益(dB)
p.channel.multipath.rayleigh = true;        % 启用瑞利衰落（各径独立复高斯系数，每帧随机）

%% 接收端（RX）
% 10) 接收端抑制/软擦除
p.mitigation = struct();
p.mitigation.methods = ["none" "fh_erasure" "ml_fh_erasure" "fft_notch" "fft_bandstop" "adaptive_notch" "stft_notch" ...
    "blanking" "clipping" "ml_blanking" "ml_cnn" "ml_gru" "ml_cnn_hard" "ml_gru_hard" "ml_narrowband" "adaptive_ml_frontend"]; % 运行并比较
% p.mitigation.methods = ["none"]; % 运行并比较
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
p.mitigation.fftBandstop = struct();
p.mitigation.fftBandstop.peakRatio = 6.0;
p.mitigation.fftBandstop.edgeRatio = 2.5;
p.mitigation.fftBandstop.maxBands = 1;
p.mitigation.fftBandstop.mergeGapBins = 2;
p.mitigation.fftBandstop.padBins = 1;
p.mitigation.fftBandstop.minBandBins = 3;
p.mitigation.fftBandstop.smoothSpanBins = 7;
p.mitigation.fftBandstop.fftOversample = 4;
p.mitigation.fftBandstop.maxBandwidthFrac = 0.22;
p.mitigation.fftBandstop.minFreqAbs = 0.01;
p.mitigation.fftBandstop.suppressToFloor = false;
p.mitigation.fftBandstop.forcedFreqBounds = zeros(0, 2);
p.mitigation.fhErasure = struct();
p.mitigation.fhErasure.freqPowerRatioThreshold = 1.8; % 频点平均能量超过全频点中位数时视为窄带命中
p.mitigation.fhErasure.hopPowerRatioThreshold = 2.6;  % 单跳异常能量门限，用于补充频点级检测
p.mitigation.fhErasure.minReliability = 0.02;         % 被判定命中的符号软擦除可靠度
p.mitigation.fhErasure.softSlope = 4.0;               % 超过门限后的软降权斜率
p.mitigation.fhErasure.maxErasedFreqFraction = 0.35;  % 避免低SNR下把过多频点误擦除
p.mitigation.fhErasure.edgeGuardSymbols = 2;          % hop边界受RRC过渡影响，统计能量时略过边缘
p.mitigation.fhErasure.attenuateSymbols = true;       % 擦除hop同步衰减，避免PLL被坏hop牵引
p.mitigation.fhErasure.lowPowerFadeEnable = true;     % 瑞利深衰落常表现为低功率/低置信hop
p.mitigation.fhErasure.lowFreqPowerRatioThreshold = 0.55;
p.mitigation.fhErasure.lowHopPowerRatioThreshold = 0.45;
p.mitigation.fhErasure.lowPowerSoftSlope = 2.5;
p.mitigation.fhErasure.constellationMseEnable = true;
p.mitigation.fhErasure.constellationMseThreshold = 0.42;
p.mitigation.fhErasure.constellationMseSoftSlope = 3.0;
p.mitigation.fhErasure.mlFreqProbabilityThreshold = 0.65; % ML频点级坏频点概率超过该值才整频点补充擦除
p.mitigation.fhErasure.mlMaxErasedFreqFraction = 0.25;    % ML补充擦除最多约2个/8个频点，避免强窄带下过擦
p.mitigation.fhErasure.mlProbabilitySlope = 120.0;        % pBad超过门限后的擦除斜率，强窄带快速压到近似擦除
p.mitigation.fhErasure.mlRequirePowerEvidence = true;     % 纯多径下不让窄带训练的ML模型凭空擦除
p.mitigation.fhErasure.multipathFadeEnable = true;        % 使用均衡器噪声增强/残余ISI识别瑞利深衰落hop
p.mitigation.fhErasure.multipathNoiseGainRatioThreshold = 1.6;
p.mitigation.fhErasure.multipathSinrDropDbThreshold = 2.5;
p.mitigation.fhErasure.multipathSoftSlope = 2.0;
p.mitigation.stftNotch = struct();
p.mitigation.stftNotch.windowLength = 128;
p.mitigation.stftNotch.hopLength = 32;
p.mitigation.stftNotch.peakRatio = 8.0;
p.mitigation.stftNotch.maxBins = 2;
p.mitigation.stftNotch.halfWidth = 1;
p.mitigation.stftNotch.minFreqAbs = 0.01;
p.mitigation.adaptiveFrontend = struct();
p.mitigation.adaptiveFrontend.bootstrapSyncChain = ["raw" "adaptive_notch" "blanking"];
p.mitigation.adaptiveFrontend.classNames = ml_interference_selector_class_names();
p.mitigation.adaptiveFrontend.stages = struct();
p.mitigation.adaptiveFrontend.stages.sample = struct( ...
    "evidenceClasses", ["impulse"], ...
    "candidates", ["none" "ml_gru" "ml_cnn" "blanking"], ...
    "candidateClasses", ["clean" "impulse" "impulse" "impulse"], ...
    "enableThreshold", 0.30);
p.mitigation.adaptiveFrontend.stages.symbol = struct( ...
    "evidenceClasses", ["tone" "narrowband" "sweep"], ...
    "candidates", ["none" "adaptive_notch" "fft_bandstop" "stft_notch" "fh_erasure" "ml_narrowband"], ...
    "candidateClasses", ["clean" "tone" "narrowband" "sweep" "narrowband" "narrowband"], ...
    "enableThreshold", 0.15, ...
    "evmEarlyExitProbability", 0.80, ...
    "evmTopK", 2);
p.mitigation.adaptiveFrontend.diagnostics = true;
p.mitigation.adaptiveFrontend.trainingDomain = struct();
p.mitigation.adaptiveFrontend.trainingDomain.classNames = ml_interference_selector_class_names();
p.mitigation.adaptiveFrontend.trainingDomain.auxiliaryClassNames = ["impulse" "tone" "narrowband" "sweep" "multipath"];
p.mitigation.adaptiveFrontend.trainingDomain.mixingProbability = 0.85;
p.mitigation.adaptiveFrontend.trainingDomain.auxiliaryClassProbability = 0.60;
p.mitigation.adaptiveFrontend.trainingDomain.impulse = struct( ...
    "enable", true, ...
    "probRange", [0.004 0.05], ...
    "toBgRatioRange", [12 80]);
p.mitigation.adaptiveFrontend.trainingDomain.tone = struct( ...
    "enable", true, ...
    "powerRange", [0.004 0.10], ...
    "freqHzRange", [-4000 4000]);
p.mitigation.adaptiveFrontend.trainingDomain.narrowband = struct( ...
    "enable", true, ...
    "powerRange", [0.004 0.10], ...
    "bandwidthFreqPointsRange", [0.2 1.6]);
p.mitigation.adaptiveFrontend.trainingDomain.sweep = struct( ...
    "enable", true, ...
    "powerRange", [0.004 0.08], ...
    "startHzRange", [-4000 1000], ...
    "stopHzRange", [-1000 4000], ...
    "periodSymbolsRange", [64 384]);
p.mitigation.adaptiveFrontend.trainingDomain.multipath = struct( ...
    "enable", true, ...
    "pathDelaysSymbols", [0 1 2], ...
    "pathGainsDb", [0 -8 -14], ...
    "pathGainJitterDb", 3.0, ...
    "rayleighProbability", 0.70);
p.mitigation.headerBandstop = struct();
p.mitigation.headerBandstop.enable = true;
p.mitigation.headerBandstop.observationSymbols = 512;
p.mitigation.headerBandstop.minObservationSymbols = 192;
p.mitigation.headerBandstop.suppressToFloor = true;
p.mitigation.headerBandstop.padBins = 0;
p.mitigation.headerDecodeDiversity = struct();
p.mitigation.headerDecodeDiversity.enable = true;
p.mitigation.headerDecodeDiversity.actions = ["none" "fft_bandstop" "adaptive_notch"];
p.mitigation.binding = struct();
p.mitigation.binding.enable = true;
p.mitigation.binding.impulseMethods = ["none" "blanking" "clipping" "ml_blanking" "ml_cnn" "ml_gru" "adaptive_ml_frontend"];
p.mitigation.binding.singleToneMethods = ["none" "fft_notch" "adaptive_notch" "adaptive_ml_frontend"];
p.mitigation.binding.narrowbandMethods = ["none" "fh_erasure" "ml_fh_erasure" "ml_cnn" "ml_gru" "adaptive_ml_frontend"];
p.mitigation.binding.sweepMethods = ["none" "stft_notch" "adaptive_ml_frontend"];
p.mitigation.binding.multipathMethods = ["none"];
p.mitigation.binding.mixedMethods = ["none" "adaptive_ml_frontend"];
p.mitigation.thresholdCalibration = struct();
p.mitigation.thresholdCalibration.enable = false;
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

requestedMlModels = lower(string(opts.loadMlModels(:).'));
invalidMlModels = setdiff(requestedMlModels, ["lr" "cnn" "gru" "selector" "narrowband" "fh_erasure" "multipath_eq"]);
if ~isempty(invalidMlModels)
    error("default_params:UnknownMlModelKind", ...
        "Unknown loadMlModels entry: %s", strjoin(cellstr(invalidMlModels), ", "));
end

% 11) 软量化（用于vitdec 'soft'）
p.softMetric = struct();
p.softMetric.clipA = 4.0; % 量化前将每比特度量裁剪到[-A, A]

% 12) 接收同步（细同步+载波补偿）
p.rxSync = struct();
p.rxSync.fineSearchRadius = 2;     % 整数符号级细搜索窗口半径
p.rxSync.compensateCarrier = true; % 使用前导估计并补偿载波相位/复增益
p.rxSync.equalizeAmplitude = true; % true: 复增益均衡；false: 仅相位补偿
p.rxSync.enableFractionalTiming = true; % 2 sps同步级上的分数符号定时估计
p.rxSync.fractionalRange = 0.5;         % 分数搜索范围（symbol）
p.rxSync.fractionalStep = 0.05;         % 分数搜索步长（symbol）
p.rxSync.estimateCfo = true;            % 用前导估计残余CFO并前馈补偿
p.rxSync.minCorrPeakToMedian = 0;       % 默认关闭；当前链路需先标定分布后再启用
p.rxSync.minCorrPeakToSecond = 0;       % 默认关闭；当前链路需先标定分布后再启用
p.rxSync.corrExclusionRadius = 4;       % 计算次峰时忽略主峰附近的相关窗口半径
p.rxSync.maxShortSyncMisses = 2;        % 连续短同步失配阈值，超限后切回长前导搜索
% 多径信道估计与均衡（仅在channel.multipath.enable=true时生效）
% 当前接收机按跳频频点合成频率相关信道并逐符号选择FFE，避免旧版静态均衡器跨hop失配。
p.rxSync.multipathEq = struct();
p.rxSync.multipathEq.enable = true;
p.rxSync.multipathEq.method = "mmse";      % "mmse" | "zf" | "ml_ridge" | "ml_mlp" | "sc_fde_mmse"
p.rxSync.multipathEq.nTaps = 9;            % 线性FFE长度（符号数）
p.rxSync.multipathEq.lambdaFactor = 1.0;   % MMSE正则: lambda=lambdaFactor*N0
p.rxSync.multipathEq.headerDecodeMethods = ["configured" "mmse" "zf" "none"]; % PHY头先试一小组线性均衡分支，再进入payload均衡链
p.rxSync.multipathEq.compareEnable = true;     % 多径启用时直接在主链路展开 none/mmse/zf/ml_ridge 接收分支
p.rxSync.multipathEq.compareMethods = ["sc_fde_mmse"];
p.rxSync.multipathEq.mitigationCompareEqualizers = "mmse"; % 仅保留多径均衡器对比；符号级抑制不再参与纯多径分支
p.rxSync.multipathEq.mlRidge = struct();
p.rxSync.multipathEq.mlRidge.lambdaFactor = 0.05; % 在线监督岭回归均衡正则: lambda=lambdaFactor*N0+ridgeFloor
p.rxSync.multipathEq.mlRidge.ridgeFloor = 1e-4;
p.rxSync.multipathEq.mlMlp = ml_multipath_equalizer_model(); % 离线训练残差式ML均衡器；训练/加载后可加入compareMethods
% 决策导向载波PLL（用于残余频偏/相位跟踪）
p.rxSync.carrierPll = struct();
p.rxSync.carrierPll.enable = true;
p.rxSync.carrierPll.alpha = 0.02;   % 相位环比例增益
p.rxSync.carrierPll.beta = 3e-4;    % 频率环积分增益
p.rxSync.carrierPll.maxFreq = 0.1;  % 归一化角频率上限（rad/sample）
% 早迟门DLL（在2 sps -> 1 sps抽样后做细跟踪；默认关闭，需单独调参）
p.rxSync.timingDll = struct();
p.rxSync.timingDll.enable = false;
p.rxSync.timingDll.earlyLateSpacing = 0.45;
p.rxSync.timingDll.alpha = 0.03;
p.rxSync.timingDll.beta = 5e-4;
p.rxSync.timingDll.maxOffset = 0.75;
p.rxSync.timingDll.decisionDirected = true;

% 接收分集（SIMO）
% 默认保持单接收支路；启用后可设置 nRx=2 做 1Tx-2Rx。
p.rxDiversity = struct();
p.rxDiversity.enable = true;
p.rxDiversity.nRx = 2;
p.rxDiversity.combineMethod = "mrc";

expectedReloadContext = ml_capture_reload_context(p);
expectedSelectorReloadContext = ml_capture_selector_reload_context(p);

if any(requestedMlModels == "lr")
    p.mitigation.ml = load_pretrained_model( ...
        fullfile(modelDir, "impulse_lr_model.mat"), @ml_impulse_lr_model, ...
        "strict", opts.strictModelLoad, ...
        "requireTrained", opts.requireTrainedMlModels, ...
        "allowBatchFallback", opts.allowBatchModelFallback, ...
        "expectedContext", expectedReloadContext);
else
    p.mitigation.ml = ml_impulse_lr_model();
end

if any(requestedMlModels == "cnn")
    p.mitigation.mlCnn = load_pretrained_model( ...
        fullfile(modelDir, "impulse_cnn_model.mat"), @ml_cnn_impulse_model, ...
        "strict", opts.strictModelLoad, ...
        "requireTrained", opts.requireTrainedMlModels, ...
        "allowBatchFallback", opts.allowBatchModelFallback, ...
        "expectedContext", expectedReloadContext);
else
    p.mitigation.mlCnn = ml_cnn_impulse_model();
end

if any(requestedMlModels == "gru")
    p.mitigation.mlGru = load_pretrained_model( ...
        fullfile(modelDir, "impulse_gru_model.mat"), @ml_gru_impulse_model, ...
        "strict", opts.strictModelLoad, ...
        "requireTrained", opts.requireTrainedMlModels, ...
        "allowBatchFallback", opts.allowBatchModelFallback, ...
        "expectedContext", expectedReloadContext);
else
    p.mitigation.mlGru = ml_gru_impulse_model();
end

if any(requestedMlModels == "selector")
    p.mitigation.selector = load_pretrained_model( ...
        fullfile(modelDir, "interference_selector_model.mat"), @ml_interference_selector_model, ...
        "strict", opts.strictModelLoad, ...
        "requireTrained", opts.requireTrainedMlModels, ...
        "allowBatchFallback", opts.allowBatchModelFallback, ...
        "expectedContext", expectedSelectorReloadContext);
else
    p.mitigation.selector = ml_interference_selector_model();
end

expectedNarrowbandContext = ml_capture_narrowband_reload_context(p);
expectedFhErasureContext = ml_capture_fh_erasure_reload_context(p);

if any(requestedMlModels == "narrowband")
    p.mitigation.mlNarrowband = load_pretrained_model( ...
        fullfile(modelDir, "narrowband_action_model.mat"), @ml_narrowband_action_model, ...
        "strict", opts.strictModelLoad, ...
        "requireTrained", opts.requireTrainedMlModels, ...
        "allowBatchFallback", opts.allowBatchModelFallback, ...
        "expectedContext", expectedNarrowbandContext);
else
    p.mitigation.mlNarrowband = ml_narrowband_action_model();
end

if any(requestedMlModels == "fh_erasure")
    p.mitigation.mlFhErasure = load_pretrained_model( ...
        fullfile(modelDir, "fh_erasure_model.mat"), @ml_fh_erasure_model, ...
        "strict", opts.strictModelLoad, ...
        "requireTrained", opts.requireTrainedMlModels, ...
        "allowBatchFallback", opts.allowBatchModelFallback, ...
        "expectedContext", expectedFhErasureContext);
else
    p.mitigation.mlFhErasure = ml_fh_erasure_model();
end

expectedMultipathEqContext = ml_capture_multipath_equalizer_reload_context(p);
if any(requestedMlModels == "multipath_eq")
    p.rxSync.multipathEq.mlMlp = load_pretrained_model( ...
        fullfile(modelDir, "multipath_equalizer_model.mat"), @ml_multipath_equalizer_model, ...
        "strict", opts.strictModelLoad, ...
        "requireTrained", opts.requireTrainedMlModels, ...
        "allowBatchFallback", opts.allowBatchModelFallback, ...
        "expectedContext", expectedMultipathEqContext);
end

%% 截获/隐蔽分析
% 窃听者/截获者（Eve）
p.eve = struct();
p.eve.enable = false;
% Eve链路增益 = Bob链路增益 + 偏移(dB)。负值表示Eve接收更差。
p.eve.linkGainOffsetDb = -6;
% Eve接收机知识模型：
%   "known"     : 知道扰码密钥（最佳截获情况）
%   "none"      : 忽略扰码（不解扰）
%   "wrong_key" : 使用错误的扰码密钥（显示乱码图像）
p.eve.scrambleAssumption = "known";
% Eve对跳频序列的知识：
%   "known"     : 知道跳频序列（能正确解跳）
%   "none"      : 不知道跳频（不解跳，信号严重失真）
%   "partial"   : 部分知道（使用错误的初始状态）
p.eve.fhAssumption = "partial";
% Eve对混沌加密的知识：
%   "known"     : 知道混沌密钥（能正确解密）
%   "approximate": 只知道混沌初值的近似值（用于展示初值敏感性）
%   "none"      : 不知道混沌加密（看到加密图像）
%   "wrong_key" : 使用错误的混沌密钥（解密失败）
p.eve.chaosAssumption = "known";
% 当chaosAssumption="approximate"时，Eve对混沌初值施加的固定偏差量。
p.eve.chaosApproxDelta = 1e-10;
% Eve使用独立接收机配置；默认复制Bob主链路配置，后续可单独修改。
p.eve.rxSync = p.rxSync;
p.eve.rxDiversity = p.rxDiversity;
p.eve.mitigation = p.mitigation;
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
p.covert.warden.nWorkers = 8;      % 并行worker数（useParallel=true时）
p.covert.warden.referenceLink = "independent"; % "bob" | "eve" | "independent"
p.covert.warden.linkGainOffsetDb = -10; % referenceLink="independent"时，Warden相对Bob的链路增益偏移(dB)
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
