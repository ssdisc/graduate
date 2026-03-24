# 第四届"凌特杯"赛道一 - 抗脉冲干扰无线图像传输系统

## 项目概述

本仓库提供一个基于 MATLAB 的端到端参考链路，当前代码主线已经从“单次整图传输基线”演进为“分包传输 + 逐包成帧 + 连续状态重建 + Eve/Warden 联合评估”版本，重点覆盖以下内容：

- 图像到比特流的完整发送与接收链路
- Bernoulli-Gaussian 脉冲噪声下的 BER、MSE、PSNR、SSIM 评估
- FFT/IIR/阈值法与 ML 法的脉冲检测和抑制
- 混沌跳频、混沌加密、扰码白化的联合保密链路
- Eve 截获仿真：可分别配置扰码、跳频、混沌知识模型
- Warden 检测仿真：能量检测、跳频窄带扫描、循环平稳检测

当前默认链路以 `src/default_params.m` 为准，不再以 README 中的旧示意为准。

## 当前默认链路

| 模块 | 当前默认实现 |
|------|---------------|
| 信源 | 灰度图，默认 `images/maodie.png` |
| 载荷编码 | `DCT` 压缩载荷，`8x8` 块、保留 `4x4` 系数、量化步长 `16` |
| 分包 | 启用，默认每包 `1024` bit 载荷 |
| 混沌加密 | 启用；`DCT` 载荷默认“先分包，再逐包独立混沌加密” |
| 扰码 | 启用，连续 PN 扰码 |
| FEC | 卷积码 `[171 133]`，码率 `1/2`，软判决 Viterbi |
| 交织 | 启用，块交织 `64` 行 |
| 调制 | `QPSK` |
| 跳频 | 启用，默认 `chaos` 序列，`8` 个频点，每跳 `64` 符号 |
| 波形成型 | 启用 `RRC`，`sps=4`，`rolloff=0.25` |
| 同步 | 默认每个分包成帧时都使用长 `PN` 前导重同步 |
| PHY头 | 默认 `compact_fec` |
| Session 元数据 | 默认 `session_frame_repeat`，即先发送 3 次 dedicated session frame，再发送数据帧 |
| Eve | 默认启用，`Eb/N0` 比 Bob 低 `6 dB`，默认场景是 `scramble=known`、`fh=partial`、`chaos=known` |
| Warden | 默认启用，主判据为 `energyOptUncertain` |

## 术语约定

- `分包`：将图像载荷按固定长度切分为多个 `packet`
- `成帧`：每个分包在发送前封装为一个物理层数据帧，默认结构为 `[同步头 | PHY头 | 受保护数据域]`
- `仿真帧`：`p.sim.nFramesPerPoint` 中用于 Monte Carlo 统计的重复仿真次数，不等同于上面的分包或物理层数据帧

## 链路流程

### 发送端

```text
图像
 -> DCT载荷
 -> 分包
 -> 逐包混沌加密（默认DCT载荷开启）
 -> 扰码
 -> 卷积编码
 -> 块交织
 -> QPSK
 -> 混沌跳频
 -> RRC成型
 -> 逐包成帧并发送 [同步头 | PHY头 | 受保护数据域]
```

### 信道

```text
AWGN
+ Bernoulli-Gaussian 脉冲噪声
+ 可选单音/窄带噪声/扫频干扰
+ 可选多径
+ 可选定时偏移和相位偏移
```

### Bob 接收端

```text
匹配滤波
 -> 帧同步 / 分数定时 / CFO补偿 / 可选多径均衡
 -> PHY头译码
 -> 根据 packetIndex 重建连续扰码与跳频状态
 -> 解跳
 -> 载波PLL
 -> 脉冲抑制
 -> 软解调
 -> 解交织
 -> Viterbi译码
 -> 解扰
 -> 包CRC校验 / 会话恢复
 -> 图像重组
 -> 丢包补偿（可选）
 -> 图像质量评估
```

### Eve 与 Warden

- Eve 走一条独立接收机链路，拥有独立的 `rxSync` 和 `mitigation` 配置。
- Eve 可分别假设自己是否知道扰码密钥、跳频序列、混沌密钥。
- Warden 默认同时评估多层检测器，不只是一条简单能量检测曲线。

## 当前支持的脉冲抑制方法

| 方法 | 说明 | 是否输出软可靠性 |
|------|------|------------------|
| `none` | 不做抑制 | 否 |
| `fft_notch` | FFT 频域峰值检测加陷波 | 否 |
| `adaptive_notch` | 自适应 IIR 陷波 | 否 |
| `blanking` | 幅度门限置零 | 否 |
| `clipping` | 幅度门限削波 | 否 |
| `ml_blanking` | 逻辑回归检测后置零 | 否 |
| `ml_cnn` | 1D CNN 检测加软抑制 | 是 |
| `ml_gru` | GRU 检测加软抑制 | 是 |

默认比较方法集合为：

```matlab
p.mitigation.methods = ["none" "fft_notch" "adaptive_notch" "blanking" ...
    "clipping" "ml_blanking" "ml_cnn" "ml_gru"];
```

## 快速开始

### 1. 推荐入口：`run_demo`

```matlab
addpath(genpath('src'));
run_demo
```

`run_demo` 会：

- 优先从 `models/` 加载 LR/CNN/GRU 模型
- 如缺失则自动训练并保存
- 然后运行完整主链路仿真

如果你要做中期答辩现场演示，建议直接跑：

```matlab
addpath(genpath('src'));
run_demo("midterm")
```

`"midterm"` 预设会关闭 Eve / Warden、关闭并行池、缩成单个 `Eb/N0` 点和单帧演示，并只保留 `none + blanking + ml_blanking` 三种方法；同时只导出 `results.mat`、一张 BER 快图和一张图像对比图，优先保证现场启动和出结果速度。

### 2. 直接调用 `simulate`

```matlab
addpath(genpath('src'));
p = default_params();
results = simulate(p);
disp(results.summary);
```

注意：

- `default_params()` 默认要求 `models/` 中已有训练好的 ML 模型。
- 如果模型不存在，当前代码会直接报错，不做静默降级。
- 如果你只想先跑非 ML 方法，可以手动去掉 ML 方法。

示例：

```matlab
addpath(genpath('src'));
p = default_params("strictModelLoad", false, "requireTrainedMlModels", false);
p.mitigation.methods = ["none" "fft_notch" "adaptive_notch" "blanking" "clipping"];
results = simulate(p);
disp(results.summary);
```

### 3. 手动训练 ML 模型

如果你想单独训练再用于仿真，可以直接调用训练入口：

```matlab
addpath(genpath('src'));
p = default_params("strictModelLoad", false, "requireTrainedMlModels", false);

[lrModel, lrReport] = ml_train_impulse_lr(p, 'nBlocks', 1000, 'epochs', 100);
[cnnModel, cnnReport] = ml_train_cnn_impulse(p, 'nBlocks', 1000, 'epochs', 100);
[gruModel, gruReport] = ml_train_gru_impulse(p, 'nBlocks', 1000, 'epochs', 100);

p.mitigation.ml = lrModel;
p.mitigation.mlCnn = cnnModel;
p.mitigation.mlGru = gruModel;
results = simulate(p);
```

## 协议层次、元信息与成帧设计

### 逻辑层次视图

当前实现更适合按“项目内部逻辑层次”理解，而不是直接套用标准 MAC/PHY 分层。可以近似看成：

```text
预共享配置层（不走空口）
    -> 会话层（可预共享，也可空口发送）
        -> 数据帧层（每个分包对应一个物理层数据帧）
            -> 受保护数据域（会话头/分包payload）
```

其中：

- `预共享配置层` 负责双方事先约定的链路参数和元信息获取方式
- `会话层` 负责整张图像级别的元信息，如尺寸、总载荷长度、总分包数
- `数据帧层` 负责每个分包的同步头、PHY头和逐包传输
- `受保护数据域` 是真正进入扰码、FEC、交织、调制、跳频的数据部分

### 元信息来源与作用

| 层次 | 典型字段 | 是否上空口 | 当前默认 | 作用 |
|------|----------|------------|----------|------|
| 预共享配置层 | `payload.codec`、`packet.payloadBitsPerPacket`、`frame.phyHeaderMode`、`mod.type`、`fh.*`、`scramble.*` | 否 | 预共享 | 决定收发两端如何解释帧结构、恢复状态和译码 |
| 会话层 | `rows`、`cols`、`channels`、`bitsPerPixel`、`totalPayloadBytes`、`totalPackets` | 可预共享，也可上空口 | `session_frame_repeat` | 告诉接收端如何把所有分包重新拼成整张图像 |
| 数据帧层 | `packetIndex`、`packetDataCrc16`、可选 `packetDataBytes` | 是 | 每包都有 | 告诉接收端当前收到的是第几包，以及这包受保护数据是否完整 |
| 受保护数据域 | 可选 `sessionHeaderBits` + 当前分包 payload | 是 | 默认仅发当前分包 payload | 承载真正业务数据，并进入扰码/FEC/调制链路 |

### 1. 预共享配置层

这一层不走空口，主要来自 `src/default_params.m`。它至少包含三类信息：

- 静态链路配置：如调制方式、卷积码、交织器、跳频参数、同步参数、PHY 头模式
- 分包规则：如 `packet.enable`、`payloadBitsPerPacket`
- 会话元信息获取方式：如 `frame.sessionHeaderMode = "preshared"`、`"embedded_each_frame"`、`"session_frame_repeat"`、`"session_frame_strong"`

当前默认模式下，接收端在开始恢复第一包之前，就已经通过本地配置知道链路骨架信息：

- 每个分包的名义载荷长度
- PHY头采用 `compact_fec`
- 会话层默认通过 dedicated session frame 上空口，接收端需先恢复会话上下文再解数据帧

换句话说，默认配置下真正仍然预共享的是“链路配置”，而图像尺寸、总载荷长度、总分包数等会话级元信息需要通过空口会话头恢复。

### 2. 会话层

会话层描述的是“这一整次图像传输”的元信息，而不是某一包独有的信息。当前实现支持四种显式模式：

- `preshared`
- `embedded_each_frame`
- `session_frame_repeat`
- `session_frame_strong`

四种模式共用同一个固定长度会话头结构：

```text
magic16 | rows16 | cols16 | channels8 | bitsPerPixel8 |
totalPayloadBytes32 | totalPackets16 | headerCrc16
```

它的特点是：

- 总长度固定为 `128 bit`
- 接收端在会话已知时还会做兼容性检查，防止收到与当前会话不一致的头

#### `preshared`

```matlab
p.frame.sessionHeaderMode = "preshared";
```

此时会话层元信息不走空口，接收端在本地直接建立会话上下文。也就是说，Bob 在译码各个分包之前，已经知道：

- 图像行列数
- 通道数
- 每像素比特数
- 总载荷字节数
- 总分包数

#### `embedded_each_frame`

```matlab
p.frame.sessionHeaderMode = "embedded_each_frame";
```

此时每一个数据帧的受保护数据域都携带一次 `sessionHeaderBits`，结构变为：

```text
[sessionHeader | payload]
```

它的特点是：

- 不需要额外独立会话帧
- 任意一个成功解出的数据帧都能单独建立会话上下文
- 代价是每个数据帧都增加固定 `128 bit` 会话开销

#### `session_frame_repeat`

当前默认模式为：

```matlab
p.frame.sessionHeaderMode = "session_frame_repeat";
p.frame.sessionFrameRepeatCount = 3;  % 允许 3~5
```

此时发送端会先连续发送若干个 dedicated session frame，再发送普通数据帧。每个 dedicated session frame 采用：

```text
[长同步头 | sessionHeader编码域]
```

它的特点是：

- 会话层真正独立占用空口，层次更清晰
- 数据帧本身不再携带会话头，受保护数据域只放 payload
- 接收端会先逐个尝试恢复 dedicated session frame；若单帧失败，还会对多次突发做合并恢复

#### `session_frame_strong`

```matlab
p.frame.sessionHeaderMode = "session_frame_strong";
p.frame.sessionStrongRepeat = 8;
```

此时只发送一次 dedicated session frame，但会把会话头改为“终止卷积码 + 逐比特重复 + BPSK”的强保护模式。它的特点是：

- 会话层只占用一次空口时隙
- 调制固定为 `BPSK`
- 通过极低等效码率换取更强的抗干扰能力

### 3. 数据帧层

图像载荷会先被切成多个分包；每个分包随后封装为一个物理层数据帧。当前数据帧层真正对应的，是“逐包上空口”的单元。

对于任一分包，空口帧可分为三段：

```text
[同步头][PHY头][受保护数据域]
```

其中：

- `同步头` 负责帧捕获、定时和载波补偿
- `PHY头` 负责给出当前分包的最小必要控制信息
- `受保护数据域` 负责承载会话头和 payload

#### 长同步帧与短同步帧

根据 `packetIndex` 和 `frame.resyncIntervalPackets`，每个分包会被封装成两类帧之一：

```text
长同步帧: [长同步头(长PN前导)][PHY头][受保护数据域]
短同步帧: [短同步头(短同步字)][PHY头][受保护数据域]
```

默认配置为：

```matlab
p.frame.resyncIntervalPackets = 1;
```

因此当前主线实际上是“每个分包都使用长前导独立成帧”的方案。代码里虽然保留了短同步字，但默认主路径并不使用它。

#### 同步头

当前同步头有以下特点：

- 长前导默认长度为 `127 bit`
- 短同步字默认长度为 `31 bit`
- 两者都可配置为 `pn` 或 `chaos`
- 当前默认都采用 `PN` 序列
- 当前实现中，同步头符号按 `BPSK` 方式生成和处理，和数据段调制解耦

因此，即使数据段默认已经切换到 `QPSK`，长前导和短同步字仍然构成独立的 `BPSK` 同步头。

### 4. PHY头

PHY头是“每个分包必带”的逐包控制块，用来告诉接收端这是第几包，以及如何校验后面的受保护数据。

当前支持两种模式：

- `compact_fec`
- `legacy_repeat`

#### `compact_fec`

当前默认模式为：

```matlab
p.frame.phyHeaderMode = "compact_fec";
```

字段为：

```text
magic8 | packetIndex16 | packetDataCrc16 | headerCrc16
```

其特点是：

- 只发送最小必要字段，尽量压缩空口开销
- 不显式发送 `packetDataBytes`
- 接收端依赖 `packetIndex`、分包配置和会话状态推导当前包的受保护数据长度
- PHY头本身使用独立于数据段的卷积码终止编码和重复发送
- 当前实现中 PHY头也是按 `BPSK` 符号发送和译码

这也是为什么 `compact_fec` 只适用于 `packet.enable = true`：因为只有在分包长度规则已知时，接收端才能在不显式发送 `packetDataBytes` 的情况下恢复长度。

#### `legacy_repeat`

字段为：

```text
magic16 | flags8 | packetIndex16 | packetDataBytes16 | packetDataCrc16 | headerCrc16
```

它的特点是：

- 头更长
- 显式携带 `packetDataBytes`
- `flags8` 中可携带 `hasSessionHeader`
- 更适合非分包或需要显式长度字段的场景

因此，如果关闭分包，必须切换到 `legacy_repeat`，否则接收端无法从 PHY头恢复整图受保护长度。

### 5. 受保护数据域

PHY头之后的部分就是受保护数据域。它在进入扰码、FEC、交织和调制之前，逻辑上有两种组成形式：

```text
preshared/session_frame_repeat/session_frame_strong: [payload]
embedded_each_frame:                           [sessionHeader | payload]
```

需要注意的是：

- 会话头虽然属于会话层，但在 `embedded_each_frame` 模式下它是嵌入在每一个数据帧受保护数据域中的
- 在 `session_frame_repeat` 和 `session_frame_strong` 模式下，会话头不进入数据帧的受保护数据域，而是进入前置 dedicated session frame
- `packetDataCrc16` 校验的是整个受保护数据域，而不仅仅是 payload
- 在 `compact_fec` 模式下，为了让接收端能通过 `packetIndex` 推导长度，当前实现会把受保护数据域按名义分包长度对齐；最后一包如不足，会在空口按固定长度发送，再在重组阶段裁回真实长度

### 6. 连续状态重建

当前主线不是把每个分包当成完全独立的小链路，而是把整次图像传输视作“一条连续的会话数据流”。这体现在两个连续状态上：

- PN 扰码状态
- 跳频 hop 偏移

发送端会按整段会话连续推进这些状态；接收端则依据 `packetIndex` 调用 `derive_packet_state_offsets(...)` 在本地恢复：

- 当前分包起点对应的累计扰码比特偏移
- 当前分包起点对应的累计 hop 偏移

如果某个分包携带了会话头，状态恢复时也会把该会话头长度计入累计偏移；如果采用 dedicated session frame，则 dedicated session frame 不参与数据帧扰码/跳频连续偏移。这样做的好处是：

- 不需要每包显式发送完整状态
- 收端只要拿到 `packetIndex`，就能恢复该包的数据域起始状态
- 分包之间虽然独立成帧，但在扰码和跳频上仍共享一条连续会话语义

### 7. 接收端同步与恢复流程

当前接收端对每个分包的大致处理流程如下：

1. 根据 `packetIndex` 和 `resyncIntervalPackets` 判断当前应搜索长前导还是短同步字。
2. 在同步头上完成粗同步、细同步、分数定时和可选 CFO/复增益补偿。
3. 按 `BPSK` 方式提取前导和 PHY头；如启用多径均衡，优先利用前导估计信道以“先救 PHY头”。
4. 译码并解析 PHY头，得到 `packetIndex`、`packetDataCrc16` 以及当前数据帧是否内嵌会话头等信息。
5. 根据 `packetIndex` 和当前配置恢复该包的扰码偏移、跳频偏移和数据符号长度。
6. 按 `p.mod.type` 提取数据段符号，随后进行解跳、载波 PLL、脉冲抑制、软解调、解交织和 Viterbi 译码。
7. 对受保护数据域做 CRC 校验；如果本包携带会话头，则进一步解析并更新会话上下文。
8. 根据 `packetIndex` 和会话层元信息，把当前分包 payload 映射回整图中的正确比特区间。

从这个角度看，当前项目中真正负责“逐包寻址和恢复上下文”的，不是一个独立 MAC 层，而是：

- 同步头
- PHY头
- 会话层元信息
- `packetIndex` 驱动的连续状态重建

## Eve / Warden 说明

### Eve 当前支持的知识模型

扰码知识：

- `known`
- `none`
- `wrong_key`

跳频知识：

- `known`
- `none`
- `partial`

混沌知识：

- `known`
- `approximate`
- `none`
- `wrong_key`

其中：

- `approximate` 只用于混沌加密，不用于扰码。
- 跳频如果采用混沌序列，`fhAssumption = "partial"` 已经对应“初始状态不准确”的情形。
- Eve 现在有独立的 `p.eve.rxSync` 和 `p.eve.mitigation`，不再强制复用 Bob 的接收机配置。

### 默认 Eve 场景

`src/default_params.m` 当前默认是：

```matlab
p.eve.ebN0dBOffset = -6;
p.eve.scrambleAssumption = "known";
p.eve.fhAssumption = "partial";
p.eve.chaosAssumption = "known";
p.eve.chaosApproxDelta = 1e-10;
```

这个默认场景主要在展示“Eve 只部分知道跳频序列”时的截获失败。

### 默认 Warden 场景

Warden 默认启用以下层：

- `energyNp`
- `energyOpt`
- `energyOptUncertain`
- `energyFhNarrow`
- `cyclostationaryOpt`

摘要里默认显示的主判据是：

```matlab
p.covert.warden.primaryLayer = "energyOptUncertain";
```

## 常用实验场景

### 1. 展示混沌初值敏感性

如果你想强调“Eve 只差一个很小的混沌初值偏差就无法恢复图像”，建议这样设置：

```matlab
p.eve.scrambleAssumption = "known";
p.eve.fhAssumption = "known";
p.eve.chaosAssumption = "approximate";
p.eve.chaosApproxDelta = 1e-10;
```

### 2. 展示跳频保密性

如果你想强调“Eve 解跳失败”，建议这样设置：

```matlab
p.eve.scrambleAssumption = "known";
p.eve.fhAssumption = "partial";
p.eve.chaosAssumption = "known";
```

### 3. 避免丢包补偿掩盖失败

如果你要更直接地观察原始截获失败，而不希望灰块补偿把 `PSNR/SSIM` 抬高，可以关闭丢包补偿：

```matlab
p.packet.concealLostPackets = false;
```

### 4. 切换会话层上空口方式

如果你想比较不同会话层传输策略，可以直接切换：

```matlab
% 方案1：每个数据帧都内嵌会话头
p.frame.sessionHeaderMode = "embedded_each_frame";

% 方案2：先发送 dedicated session frame，并连续突发 3~5 次
p.frame.sessionHeaderMode = "session_frame_repeat";
p.frame.sessionFrameRepeatCount = 5;

% 方案3：只发送一次，但使用极低码率FEC + BPSK 强保护
p.frame.sessionHeaderMode = "session_frame_strong";
p.frame.sessionStrongRepeat = 8;
```

## 关键参数入口

当前主要从 `src/default_params.m` 修改参数。比较常用的入口有：

| 参数 | 作用 |
|------|------|
| `p.sim.ebN0dBList` | Bob 的 Eb/N0 扫描范围 |
| `p.sim.nFramesPerPoint` | 每个 Eb/N0 点的帧数 |
| `p.sim.useParallel` | 主链路是否并行 |
| `p.source.*` | 图像路径、缩放、灰度化 |
| `p.payload.*` | `raw` / `dct` 载荷格式 |
| `p.packet.*` | 分包长度、丢包补偿 |
| `p.chaosEncrypt.*` | 图像或载荷混沌加密 |
| `p.frame.*` | 成帧相关配置：前导、短同步字、PHY头、session头模式 |
| `p.scramble.*` | PN 扰码配置 |
| `p.fec.*` | 卷积码与 Viterbi 参数 |
| `p.interleaver.*` | 交织深度 |
| `p.mod.*` | `BPSK` / `QPSK` / `MSK` |
| `p.fh.*` | 跳频序列类型、频点数、每跳长度 |
| `p.waveform.*` | `RRC` 成型与采样率 |
| `p.channel.*` | 脉冲干扰、多径、同步失配、窄带/扫频干扰 |
| `p.rxSync.*` | 细同步、CFO、PLL、多径均衡、DLL |
| `p.mitigation.*` | 脉冲抑制与 ML 阈值校准 |
| `p.eve.*` | Eve 假设与独立接收机配置 |
| `p.covert.warden.*` | Warden 检测参数 |

## 输出结果

运行结束后会在 `results/matlab_yyyyMMdd_HHmmss/` 下生成结果目录。

常见输出文件包括：

- `results.mat`
- `ber.png`
- `mse.png`
- `psnr.png`
- `kl.png`
- `psd.png`
- `images/00_tx_original.png`
- `images/snr_01_*.png`
- `images_eve/snr_01_*.png`（启用 Eve 时）
- `ber_eve.png`
- `mse_eve.png`
- `psnr_eve.png`
- `warden.png`

### `results.mat` 的保存方式

当前代码使用：

```matlab
save(fullfile(outDir, "results.mat"), "-struct", "results");
```

所以 `results.mat` 里保存的是顶层变量，而不是一个顶层 `results` 变量。常见字段有：

- `summary`
- `params`
- `methods`
- `ebN0dB`
- `ber`
- `imageMetrics`
- `packetDiagnostics`
- `eve`
- `covert`
- `spectrum`
- `kl`

读取示例：

```matlab
s = load('results/matlab_20260322_112934/results.mat');
disp(s.summary);
disp(s.eve.assumptions);
```

## 目录结构

```text
graduate/
├── README.md
├── run_demo.m
├── src/
│   ├── default_params.m
│   ├── simulate.m
│   ├── tx/
│   ├── frame/
│   ├── payload/
│   ├── source/
│   ├── recovery/
│   ├── security/
│   ├── coding/
│   ├── modem/
│   ├── fh/
│   ├── sync/
│   ├── channel/
│   ├── mitigation/
│   │   └── ml/
│   ├── covert/
│   ├── analysis/
│   ├── util/
│   └── io/
├── models/
├── results/
└── docs/
```

## 注意事项

- 当前代码对关键配置缺失是直接报错，不做回退兼容。
- `default_params()` 默认要求训练好的 ML 模型存在；最省心的入口仍然是 `run_demo`。
- 默认 `sessionHeaderMode = "session_frame_repeat"`，表示会话元信息先以 dedicated session frame 连续突发 3 次再发送数据帧；如果你只想评估主链路而不想让会话层占用空口，可以改成 `preshared`。
- 默认 `resyncIntervalPackets = 1`，因此当前主线其实是“每个分包独立成帧且使用长前导”方案，短同步字还不是默认主路径。
- Eve 如果自定义接收机配置，`p.eve.rxSync` 和 `p.eve.mitigation` 需要是完整结构体，并且 `p.eve.mitigation.methods` 必须与主链路完全一致。

## 许可证

本项目仅用于学术研究和竞赛用途。
