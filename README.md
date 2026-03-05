# 第四届"凌特杯"赛道一 - 抗脉冲干扰无线图像传输系统

## 项目概述

本项目为第四届"凌特杯"赛道一（初赛）提供一个**可直接运行**的MATLAB端到端基线链路，实现：

- 随机脉冲干扰（Bernoulli-Gaussian）下的BER曲线
- 基于机器学习的脉冲检测与抑制（CNN/GRU/逻辑回归）
- 接收端图像重建与MSE/PSNR/SSIM质量评估
- 频谱分析（PSD）与99%占用带宽（OBW）
- KL散度隐蔽性指标（信号与背景噪声统计差异）
- 窃听者（Eve）截获分析与监视者（Warden）检测仿真

---

## 快速开始

### 运行仿真

```matlab
% 在MATLAB中进入仓库根目录后执行
addpath(genpath('src'));
run_demo
```

### 输出结果

运行结束后在 `results/matlab_yyyyMMdd_HHmmss/` 下生成：

| 文件 | 说明 |
|------|------|
| `results.mat` | 全部仿真结果与参数 |
| `ber.png` | BER-Eb/N0曲线 |
| `mse.png` | MSE-Eb/N0曲线 |
| `psnr.png` | PSNR-Eb/N0曲线 |
| `kl.png` | KL散度-Eb/N0曲线 |
| `psd.png` | 功率谱密度图 |
| `images.png` | 发送/接收图像对比 |
| `ber_eve.png` | Eve的BER曲线（启用时） |
| `mse_eve.png` | Eve的MSE曲线（启用时） |
| `psnr_eve.png` | Eve的PSNR曲线（启用时） |
| `intercept.png` | Bob与Eve图像对比（启用时） |
| `warden.png` | 监视者检测性能（启用时） |

---

## 系统架构

### 链路流程图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              发送端 (TX)                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   图像源 ──→ 载荷提取 ──→ 帧头构建 ──→ PN扰码 ──→ 卷积编码              │
│   (灰度图)   (RAW字节)    (Magic+尺寸)  (白化/加密)  (码率1/2)            │
│                                              │                          │
│                                              ▼                          │
│              块交织 ──→ BPSK/QPSK调制 ──→ ★跳频调制★ ──→ 添加前导      │
│               (抗突发)                  (可选,PN序列)   (PN序列)         │
│                                              │                          │
│                                              ▼                          │
│                                         发送符号                         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    伯努利-高斯脉冲噪声信道                                │
│                                                                         │
│              y = x + n_AWGN + I·n_impulse                               │
│              I ~ Bernoulli(p), n_impulse ~ N(0, κ·N0)                   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              接收端 (RX)                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   接收符号 ──→ 帧同步 ──→ 数据提取 ──→ ★跳频解调★                       │
│               (PN相关)               (需要正确的跳频序列)                │
│                                              │                          │
│                                              ▼                          │
│   ┌────────────────────────────────────────┐                           │
│   │      ML脉冲抑制模块                     │                           │
│   │                                        │                           │
│   │  输入: 接收符号 r                       │                           │
│   │  输出: 1. 清洁符号估计 r_clean          │                           │
│   │        2. 软可靠性权重 w ∈ [0,1]        │                           │
│   │                                        │                           │
│   │  方法: none / blanking / clipping      │                           │
│   │        ml_blanking / ml_cnn / ml_gru   │                           │
│   └────────────────────────────────────────┘                           │
│                    │                                                    │
│                    ▼                                                    │
│   软解调 ──→ 解交织 ──→ Viterbi软判决译码 ──→ 解扰码 ──→ 帧解析          │
│  (带可靠性加权)                                                          │
│                    │                                                    │
│                    ▼                                                    │
│              图像重建 ──→ 质量评估(PSNR/SSIM)                            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 已实现功能

### 1. 信源处理

| 功能 | 文件 | 说明 |
|------|------|------|
| 图像加载 | `load_source_image.m` | 支持内置图像或自定义路径，可配置灰度转换和缩放 |
| 载荷提取 | `image_to_payload_bits.m` | 将图像转为原始字节流 |
| 图像重建 | `payload_bits_to_image.m` | 从比特流恢复图像 |
| 质量评估 | `image_quality.m` | 计算PSNR和SSIM |

### 2. 成帧与同步

| 功能 | 文件 | 说明 |
|------|------|------|
| 前导生成 | `make_preamble.m` | PN序列前导，用于帧同步 |
| 帧头构建 | `build_header_bits.m` | Magic字(0xA55A) + 图像尺寸 + 载荷长度 |
| 帧同步 | `frame_sync.m` | 基于前导相关的粗同步 |
| 帧解析 | `parse_frame_bits.m` | 提取帧头信息和载荷 |

### 3. 信道编码与交织

| 功能 | 文件 | 说明 |
|------|------|------|
| 卷积编码 | `fec_encode.m` | 码率1/2，生成多项式[171,133] |
| Viterbi译码 | `fec_decode.m` | 支持硬判决/软判决(3bit量化) |
| 块交织 | `interleave_bits.m` | 抗突发脉冲，可配置深度 |
| 解交织 | `deinterleave_bits.m` | 恢复原始比特顺序 |

### 4. 扰码（轻量加密）

| 功能 | 文件 | 说明 |
|------|------|------|
| 扰码 | `scramble_bits.m` | PN序列异或，实现白化和轻量加密 |
| 解扰 | `descramble_bits.m` | 使用相同密钥恢复原始比特 |

### 5. 调制解调

| 功能 | 文件 | 说明 |
|------|------|------|
| BPSK/QPSK调制 | `modulate_bits.m` | BPSK: 0→+1,1→-1；QPSK: Gray映射，单位功率归一化 |
| 软解调 | `demodulate_to_softbits.m` | 输出LLR软信息，支持可靠性加权 |

### 6. 跳频扩频（Frequency Hopping）

| 功能 | 文件 | 说明 |
|------|------|------|
| 跳频序列生成 | `fh_generate_sequence.m` | 基于PN序列的伪随机跳频序列 |
| 跳频调制 | `fh_modulate.m` | 对数据符号进行频率跳变 |
| 跳频解调 | `fh_demodulate.m` | 接收端去除频率偏移 |

#### 跳频原理

```
发送端：每个hop周期内的符号乘以 exp(j·2π·f_k·n)
接收端：乘以共轭 exp(-j·2π·f_k·n) 恢复基带
```

#### 跳频参数

```matlab
p.fh.enable = true;           % 启用跳频
p.fh.nFreqs = 8;              % 跳频频点数量
p.fh.symbolsPerHop = 64;      % 每跳符号数（跳频速率）
p.fh.sequenceType = 'pn';     % 序列类型：'pn' | 'chaos' | 'linear' | 'random'
p.fh.freqSet = linspace(-0.35, 0.35, 8);  % 归一化频率集合
```

#### 跳频优势

1. **抗窄带干扰**：干扰只影响部分跳频周期
2. **低截获概率**：信号能量分散在多个频点
3. **抗频率选择性衰落**：不同频点独立衰落
4. **隐蔽性增强**：Eve不知道跳频序列则无法解调

#### Eve的跳频知识假设

```matlab
p.eve.fhAssumption = "none";     % Eve不知道跳频序列
p.eve.fhAssumption = "known";    % Eve知道跳频序列（最坏情况）
p.eve.fhAssumption = "partial";  % Eve使用错误的序列
```

### 7. 信道模型

| 功能 | 文件 | 说明 |
|------|------|------|
| BG脉冲信道 | `channel_bg_impulsive.m` | AWGN + 伯努利-高斯脉冲噪声 |

信道模型参数：
- `impulseProb`: 脉冲发生概率（默认1%）
- `impulseToBgRatio`: 脉冲功率与背景噪声功率比（默认50倍）

### 8. 脉冲抑制（核心创新点）

| 方法 | 说明 | 软可靠性输出 |
|------|------|-------------|
| `none` | 不处理 | 否 |
| `blanking` | 幅度阈值置零 | 否 |
| `clipping` | 幅度阈值削波 | 否 |
| `ml_blanking` | 逻辑回归检测+置零 | 否 |
| `ml_cnn` | 1D CNN检测+软抑制 | **是** |
| `ml_gru` | GRU检测+软抑制 | **是** |

#### ML模型架构

**1D CNN模型** (`ml_cnn_impulse_model.m`):
```
输入(4特征) → Conv1D(16滤波器,k=5) → ReLU → Conv1D(32滤波器,k=3) → ReLU → FC(4输出)
                                                                              ↓
                                                        [脉冲概率, 可靠性, cleanReal, cleanImag]
```

**GRU模型** (`ml_gru_impulse_model.m`):
```
输入(4特征) → GRU(hiddenSize=32) → FC(4输出)
                                      ↓
                   [脉冲概率, 可靠性, cleanReal, cleanImag]
```

**输入特征** (`ml_cnn_features.m`):
1. `|r|` - 接收符号幅度
2. `|r|/median(|r|)` - 归一化幅度
3. `||r_i| - |r_{i-1}||` - 幅度差分
4. `angle(r)` - 相位

#### 训练ML模型

```matlab
% 训练LR/CNN/GRU模型
addpath(genpath('src'));
p = default_params();

% 训练逻辑回归
[lrModel, lrReport] = ml_train_impulse_lr(p, 'nBlocks', 200, 'epochs', 25);

% 训练CNN
[cnnModel, cnnReport] = ml_train_cnn_impulse(p, 'nBlocks', 300, 'epochs', 30);

% 训练GRU
[gruModel, gruReport] = ml_train_gru_impulse(p, 'nBlocks', 200, 'epochs', 20);

% 在仿真中使用
p.mitigation.ml = lrModel;
p.mitigation.mlCnn = cnnModel;
p.mitigation.mlGru = gruModel;
results = simulate(p);
```

或直接运行主脚本（首次会自动训练并保存模型到 `models/`）：
```matlab
run_demo
```

### 9. 隐蔽性分析

| 功能 | 文件 | 说明 |
|------|------|------|
| 窃听者仿真 | `simulate.m` | Eve以不同SNR和扰码假设尝试截获 |
| 监视者检测 | `warden_energy_detector.m` | 能量检测器估计Pd/Pfa/Pe |

Eve扰码假设模式：
- `known`: Eve知道扰码密钥（最佳截获）
- `none`: Eve不解扰
- `wrong_key`: Eve使用错误密钥（图像乱码）

### 10. 频谱分析

| 功能 | 文件 | 说明 |
|------|------|------|
| 频谱估计 | `estimate_spectrum.m` | PSD、99%占用带宽、频谱效率 |

---

## 关键参数配置

在 `src/default_params.m` 中配置：

### 仿真参数
```matlab
p.sim.ebN0dBList = 0:2:10;      % Eb/N0扫描范围(dB)
p.sim.nFramesPerPoint = 1;       % 每个SNR点的帧数
```

### 信道参数
```matlab
p.channel.impulseProb = 0.01;    % 脉冲概率(1%)
p.channel.impulseToBgRatio = 50; % 脉冲功率比(50倍)
```

### 分包参数
```matlab
p.packet.enable = true;                 % 启用分包
p.packet.payloadBitsPerPacket = 2048;   % 每包载荷比特数（8比特对齐）
p.packet.concealLostPackets = true;     % 丢包后图像/块域补偿（仅影响图像重建）
p.packet.concealMode = "nearest";       % "nearest" | "blend"
```

### 混沌加密参数
```matlab
p.chaosEncrypt.packetIndependent = true; % dct载荷时先分包，再逐包独立加密
```

### 波形成型参数
```matlab
p.waveform.enable = true;          % 启用RRC成型+匹配滤波
p.waveform.sps = 4;                % 过采样倍数
p.waveform.rolloff = 0.25;         % 滚降系数
p.waveform.spanSymbols = 10;       % 滤波器跨度（符号）
p.waveform.rxMatchedFilter = true; % 接收端匹配滤波
```

### 抑制方法
```matlab
p.mitigation.methods = ["none" "blanking" "ml_cnn" "ml_gru"];
p.mitigation.thresholdAlpha = 4.0;  % blanking阈值系数
```

### 交织深度
```matlab
p.interleaver.nRows = 64;  % 越深越抗突发，但时延增加
```

### 调制方式
```matlab
p.mod.type = 'BPSK';  % 默认
% p.mod.type = 'QPSK'; % Gray映射: [bI,bQ] -> ((1-2*bI)+1j*(1-2*bQ))/sqrt(2)
```

### 隐蔽性配置
```matlab
p.eve.enable = true;
p.eve.ebN0dBOffset = -6;           % Eve比Bob差6dB
p.eve.scrambleAssumption = "wrong_key";

p.covert.warden.enable = true;
p.covert.warden.pfaTarget = 0.01;  % 监视者虚警率目标
```

---

## 代码结构

```
graduate/
├── README.md
├── run_demo.m                     # 主演示入口
├── src/
│   ├── default_params.m           # 默认参数配置
│   ├── simulate.m                 # 端到端仿真主函数
│   ├── tx/                        # 发送端链路装配（分包->编码->调制->波形成型）
│   ├── frame/                     # 前导、帧头、CRC与帧解析
│   ├── payload/                   # 载荷格式辅助
│   ├── source/                    # 图像信源编码/重建与质量评估
│   ├── recovery/                  # 丢包图像域补偿/修复
│   ├── security/                  # 混沌加密/解密
│   ├── coding/                    # 扰码/FEC/交织/比特工具
│   ├── modem/                     # 调制解调
│   ├── fh/                        # 跳频
│   ├── sync/                      # 帧同步与载波跟踪
│   ├── channel/                   # 信道与噪声参数换算
│   ├── mitigation/                # 脉冲抑制
│   │   └── ml/                    # ML检测与训练
│   ├── covert/                    # 监视者检测
│   ├── analysis/                  # 频谱估计与结果汇总
│   ├── util/                      # simulate辅助通用工具
│   └── io/                        # 结果目录与图像保存
├── models/                        # 训练好的ML模型
├── results/                       # 仿真结果输出
└── docs/                          # 其他文档
```

---

## 赛道报告与毕设两用建议

### 复用策略

本项目可同时用于：
1. **赛道一参赛报告**：偏工程交付，强调完整性和性能
2. **毕业设计论文**：偏学术论证，强调原理和创新

### 赛道报告重点

- 技术完整性：端到端模块齐全
- 抗干扰性能：BER/PSNR对比曲线
- 资源约束：带宽占用、频谱效率
- 可执行性：参数表+关键截图

### 毕设论文重点

- 系统的文献综述
- 关键模块的数学建模
- 参数敏感性分析
- ML模型的设计与训练细节

### eLabRadio平台迁移

1. **MATLAB作为参考模型**：算法验证、参数扫描、产出基准曲线
2. **eLabRadio作为参赛实现**：按赛题要求搭建同等链路
3. **一致性验证**：用相同输入对比两平台输出

迁移步骤：
1. 定义接口（bit/symbol/IQ三层）
2. 在MATLAB产出金标向量
3. 在eLabRadio喂入同样输入
4. 逐段对比验证

---

## 下一步改进方向

1. **Header加CRC校验**：消除头部误判
2. **更强FEC**：LDPC/Polar/RS+卷积
3. **更复杂脉冲模型**：Middleton Class-A、突发脉冲
4. **自适应跳频**：根据信道检测结果动态调整跳频图案
5. **自适应阈值**：根据信道状态动态调整脉冲检测阈值
6. **真实数据训练**：用实际测量数据提升ML模型泛化能力
7. **载波同步和定时同步**：更精确的接收端同步

---

## 许可证

本项目仅用于学术研究和竞赛用途。
