# 基于跳频与抗干扰调制的隐蔽图像通信系统（MATLAB）

## 进度结论（论文开写口径）
截至 **2026-04-23**，本项目已经具备“**可以写论文初稿**”的完整度。

- 已有端到端闭环：图像源 -> 加密/编码 -> 跳频调制 -> 受干扰信道 -> 同步/抑制/译码 -> 图像重建 -> 指标统计。
- 已有离线训练与模型加载流程：LR/CNN/GRU + 干扰选择器 + 窄带动作模型 + FH 软擦除模型 + 多径均衡模型。
- 已有论文可用结果导出：BER/PER、图像质量（MSE/PSNR/SSIM）、KL、频谱、Warden 检测层结果，自动导出 CSV 与图。
- 最近完整结果目录：`results/matlab_20260423_142626`（含 `run_summary.csv`、`metrics_bob.csv`、`warden_layers.csv` 与全部图）。

当前更准确的判断是：**初稿可以直接写，终稿前还需要补更大样本量和更系统的参数扫频实验。**

## 项目目标
课题题目：**基于跳频与抗干扰调制的隐蔽图像通信系统设计与实现**  
本仓库实现了一个以 MATLAB 为主的可复现实验平台，面向以下问题：

- 图像在复杂干扰信道下的可靠传输。
- 基于跳频、抗干扰前端和编码的抗干扰能力评估。
- 混沌加密和截获/隐蔽性（Eve/Warden）能力评估。
- 传统方法与机器学习方法在抗干扰链路中的对比。

## 对应开题任务的实现状态
| 开题任务 | 当前状态 | 已实现内容（代码） |
| --- | --- | --- |
| 任务一：图像处理与混沌加密 | 已完成主线 | `src/source/*`（图像载荷编解码）、`src/security/*`（Arnold + chaos 置乱/扩散、按包解密） |
| 任务二：混沌跳频通信架构 | 已完成主线 | `src/fh/*`（慢/快跳频、频点序列）、`src/modem/*`、`src/frame/*`、`src/tx/*` |
| 任务三：信道建模与接收关键技术 | 已完成主线 | `src/channel/*`（AWGN/脉冲/单音/窄带/扫频/多径）、`src/sync/*`（同步、PLL、均衡） |
| 任务四：深度学习干扰检测与抑制 | 已完成并可离线训练 | `src/mitigation/ml/*`（LR/CNN/GRU/selector/narrowband/fh_erasure/multipath_eq 训练与推理） |
| 任务五：综合性能评估 | 已完成基础版本 | `src/simulate.m` + `src/analysis/*` + `src/io/export_thesis_tables.m`（图表与表格导出） |

## 代码入口
- 主仿真入口：`run_demo.m`
- 离线训练入口：`run_offline_training.m`
- 窄带中心频点扫描：`scan_narrowband_centers.m`
- 全局默认参数：`src/default_params.m`
- 主调度与统计：`src/simulate.m`
- 调用关系总览：`docs/project_function_call_graph.md`

## 已实现能力（系统层）
- 图像载荷：`raw` / `dct` 两种 codec，支持按包传输与丢包补偿。
- 安全机制：混沌加密（图像域与比特域）+ 扰码 + 会话/PHY 头保护。
- 抗干扰链路：FH、可选 DSSS、LDPC/卷积码、外层 RS（包级纠删恢复）。
- 信道模型：AWGN、脉冲、单音、窄带、扫频、多径/瑞利。
- 接收机：帧同步、分数定时、CFO 估计、PLL、SC-FDE/多径均衡、软判决译码。
- 抑制方法：`none/fh_erasure/ml_fh_erasure/blanking/clipping/fft_notch/fft_bandstop/adaptive_notch/stft_notch/ml_* / adaptive_ml_frontend`。
- 隐蔽评估：Warden 多检测层（含 `energyOptUncertain`、`energyFhNarrow`、`cyclostationaryOpt`）。

## 环境要求
- MATLAB（建议较新版本）。
- 常用工具箱依赖：
  - Communications Toolbox（LDPC、调制相关能力）。
  - Signal Processing Toolbox（频谱、滤波相关能力）。
  - Deep Learning Toolbox（CNN/GRU/MLP 训练与推理）。
  - Parallel Computing Toolbox（可选，用于 `parfor` 加速）。

## 快速开始
1. 离线训练并保存模型（首次建议执行）
```matlab
run_offline_training
```

2. 加载模型并运行主仿真
```matlab
results = run_demo;
```

3. （可选）窄带中心频点扫描
```matlab
scan_narrowband_centers("CenterFreqPoints", -5.5:0.5:5.5);
```

## 最近一次完整结果（2026-04-23）
结果目录：`results/matlab_20260423_142626`

关键配置（见 `run_summary.csv`）：
- `mod=QPSK`，`fec=LDPC(short, rate=1/2)`，`payload=dct`。
- `Eb/N0 = [4,6,8,10] dB`，`JSR = 0 dB`。
- 干扰类型：窄带干扰（`narrowband`，centerFreqPoints=2.5，bandwidthFreqPoints=1）。
- 启用方法：`none, fh_erasure, ml_fh_erasure, ml_cnn, ml_gru, adaptive_ml_frontend`。
- 帧数：`nFramesPerPoint=5`（说明：这是快速对比口径，不是最终统计口径）。

在 `Eb/N0=10 dB` 点的 Bob 端结果（摘自 `metrics_bob.csv`）：

| method | BER | PER | payloadSuccessRate | PSNR(original, compensated) |
| --- | ---: | ---: | ---: | ---: |
| fh_erasure | 0.0438 | 0.0000 | 1.0000 | 30.59 dB |
| adaptive_ml_frontend | 0.1148 | 0.0000 | 1.0000 | 30.59 dB |
| ml_fh_erasure | 0.1290 | 0.0000 | 1.0000 | 30.59 dB |
| none | 0.1301 | 0.0000 | 1.0000 | 30.59 dB |
| ml_cnn | 0.1585 | 0.0476 | 0.9524 | 29.09 dB |
| ml_gru | 0.3869 | 0.3810 | 0.6190 | 20.55 dB |

Warden（`warden_layers.csv`，`energyOptUncertain` 层）在 `Eb/N0=4/6/8/10 dB` 的 `Pe` 约为：
- `0.4853 / 0.4820 / 0.4750 / 0.4673`

这说明当前口径下系统具备可分析的隐蔽通信评估结果（仍建议扩大样本量后再下最终结论）。

## 论文可直接引用的材料位置
- 系统调用图：`docs/project_function_call_graph.md`
- 指标曲线图：结果目录下 `ber.png`、`per.png`、`psnr*.png`、`mse*.png`、`kl.png`、`psd.png`、`warden.png`
- 论文表格 CSV：`run_summary.csv`、`points_overview.csv`、`metrics_bob.csv`、`metrics_eve.csv`（启用 Eve 时）、`warden_layers.csv`
- 全量结果结构体：`results.mat`

## 现在写论文时建议的叙事框架
- 先写“系统设计与模块实现”：按 TX/RX 链路和抗干扰前端展开。
- 再写“方法对比实验”：`none` 与 `fh_erasure / adaptive_ml_frontend / ml_*` 对比。
- 再写“隐蔽性评估”：Warden 多层检测结果与 KL 指标。
- 最后写“局限与改进”：样本量、参数覆盖、泛化场景。

## 论文开写顺序（建议）
1. 先写“系统模型与总体流程”与“关键模块设计”两章（最稳定、返工最少）。
2. 再写“实验设置”和“评价指标定义”（直接引用 CSV 字段与默认参数）。
3. 然后写“结果与分析”初稿（先放当前结果，再留位置给补实验）。
4. 最后写“讨论、局限与后续工作”。

## 论文可直接落地的章节骨架（建议）
1. 绪论：研究背景、问题定义、本文贡献。
2. 系统模型与总体架构：发射端、信道、接收端、隐蔽检测模型。
3. 关键算法设计：混沌加密、跳频与成帧、抗干扰策略、ML 抗干扰前端。
4. 仿真平台与实验设置：参数、场景、评价指标（BER/PER/PSNR/SSIM/KL/Pe）。
5. 实验结果与分析：方法对比、Warden 分层结果、有效性与失效场景分析。
6. 结论与展望：主要结论、局限、改进方向。

## 章节-证据映射（写作时可直接对照）
| 论文章节（建议） | 可直接引用的证据 |
| --- | --- |
| 系统模型与流程 | `docs/project_function_call_graph.md`、`src/simulate.m` |
| 发射端设计（图像、加密、成帧、跳频） | `src/source/*`、`src/security/*`、`src/frame/*`、`src/fh/*`、`src/tx/*` |
| 接收端与抗干扰设计 | `src/sync/*`、`src/mitigation/*`、`src/coding/*` |
| 机器学习抗干扰方法 | `src/mitigation/ml/*`、`run_offline_training.m`、`models/*.mat` |
| 性能实验与结果 | `results/matlab_20260423_142626/*.png`、`metrics_bob.csv`、`points_overview.csv` |
| 隐蔽通信评估 | `results/matlab_20260423_142626/warden_layers.csv`、`warden.png` |
| 讨论与局限 | 本文“终稿前建议补的实验”章节 |

## 当前风险与说明（写作与答辩都适用）
- 当前展示结果多数是快速口径（`nFramesPerPoint=5`），结论趋势可看，但统计置信度有限。
- 默认绑定规则会按干扰类型筛方法；若只开窄带干扰，不是所有抑制方法都会进入主对比。
- 扫描脚本 `scan_narrowband_centers.m` 已接入，但 `results/scan_narrowband_centers_all_points` 目前只有目录骨架，尚未形成可用汇总 CSV，后续建议单独补跑并检查输出。

## 终稿前建议补的实验（优先级）
1. 把 `nFramesPerPoint` 从 5 提升到 30~100，降低统计波动。
2. 做更完整的 JSR 扫描（例如 `[-10,-5,0,5] dB`）并固定其余参数。
3. 分场景单独评估：窄带/单音/扫频/脉冲/多径，不混在一起。
4. 开启 Eve 口径并导出 `metrics_eve.csv`，形成“Bob vs Eve”安全性对比。
5. 对关键方法做消融：是否开 SC-FDE、是否开 RS、是否开会话头重复。

## 开发约定
- 本仓库默认采用“**不做回退兼容，配置错误直接报错**”策略。
- 关键配置修改后，建议重新离线训练并重跑主实验，避免模型上下文不匹配。
