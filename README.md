# 第四届"凌特杯"赛道一 - 抗脉冲干扰无线图像传输系统

## 项目概述

本仓库提供一个基于 MATLAB 的端到端参考链路，当前代码主线已经从“单帧基线”演进为“分包图像传输 + 连续状态重建 + Eve/Warden 联合评估”版本，重点覆盖以下内容：

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
| 调制 | `BPSK` |
| 跳频 | 启用，默认 `chaos` 序列，`8` 个频点，每跳 `64` 符号 |
| 波形成型 | 启用 `RRC`，`sps=4`，`rolloff=0.25` |
| 同步 | 默认每包都使用长 `PN` 前导重同步 |
| PHY 小头 | 默认 `compact_fec` |
| Session 元数据 | 默认 `preshared`，即默认不在空口发送 session header |
| Eve | 默认启用，`Eb/N0` 比 Bob 低 `6 dB`，默认场景是 `scramble=known`、`fh=partial`、`chaos=known` |
| Warden | 默认启用，主判据为 `energyOptUncertain` |

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
 -> BPSK
 -> 混沌跳频
 -> RRC成型
 -> [长PN前导 | PHY小头 | 受保护数据]
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
 -> PHY小头译码
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

## 默认分包与头部设计

### 当前默认包结构

当前默认配置下，`p.frame.resyncIntervalPackets = 1`，所以每一包都使用长前导：

```text
[127-bit 长PN前导][compact_fec PHY小头][受保护数据]
```

其中：

- `31-bit` 短同步字仍然保留在代码中，但当前默认主线不使用，只作为实验选项。
- 默认 `sessionHeaderMode = "preshared"`，因此“受保护数据”默认只包含该包 payload，不包含空口 session header。
- 如果切换到 `sessionHeaderMode = "inline"`，则首包或长前导重同步包可以携带 session header。

### `compact_fec` PHY 小头

默认 PHY 小头字段为：

```text
magic8 | packetIndex16 | packetDataCrc16 | headerCrc16
```

它的特点是：

- 只传最小必要字段，减少空口开销
- 不显式发送 `packetDataBytes`
- 接收端依赖 `packetIndex` 和当前配置推导本包应有的受保护数据长度

因此：

- `compact_fec` 只适用于 `packet.enable = true`
- 如果关闭分包，必须切换到 `frame.phyHeaderMode = "legacy_repeat"`，否则会直接报错

### 连续状态重建

当前主线不是每包都从零开始独立扰码和跳频，而是：

- 发端按整段会话连续推进 PN 扰码状态和跳频 hop 偏移
- 收端根据 `packetIndex` 调用 `derive_packet_state_offsets(...)`
- 在本地精确重建该包起点对应的扰码偏移和 hop 偏移

这也是当前链路和早期“每包独立链路”最大的区别之一。

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

### 4. 改成空口发送 session header

如果你要从“仿真假定接收端已知会话元数据”改成“通过空口首包恢复元数据”，可以改成：

```matlab
p.frame.sessionHeaderMode = "inline";
p.frame.repeatSessionHeaderOnResync = true;
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
| `p.frame.*` | 前导、短同步字、PHY头、session头模式 |
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
- `images.png`
- `intercept.png`
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
- 默认 `sessionHeaderMode = "preshared"` 是仿真口径，表示 Bob 预先知道会话元数据；如果要模拟完全空口恢复，请改成 `inline`。
- 默认 `resyncIntervalPackets = 1`，因此当前主线其实是“每包长前导”方案，短同步字还不是默认主路径。
- Eve 如果自定义接收机配置，`p.eve.rxSync` 和 `p.eve.mitigation` 需要是完整结构体，并且 `p.eve.mitigation.methods` 必须与主链路完全一致。

## 许可证

本项目仅用于学术研究和竞赛用途。
