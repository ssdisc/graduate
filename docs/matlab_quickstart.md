# 赛道一（初赛）MATLAB 起步：端到端基线链路

本仓库提供一个**可直接跑通**的 MATLAB 端到端基线链路，用于初赛阶段快速产出：

- 随机脉冲干扰（Bernoulli-Gaussian）下的 `BER` 曲线（含抗干扰开/关对比）
- 接收端图像重建结果与 `PSNR`
- 一次突发传输的频谱图（PSD）与 99% 占用带宽（`obw`）

代码位置：`src/run_demo.m`、`src/link/simulate.m`、`src/link/default_params.m`

---

## 1) 如何运行

在仓库根目录打开 MATLAB，然后执行：

```matlab
addpath(genpath('src'));
run_demo
```

运行结束后会在 `results/matlab_yyyyMMdd_HHmmss/` 下生成：

- `results.mat`：全部仿真结果与参数
- `ber.png`、`psnr.png`、`psd.png`、`images.png`
- （启用 `p.eve/p.covert` 时）`ber_eve.png`、`psnr_eve.png`、`intercept.png`、`warden.png`

---

## 2) 这个基线链路包含什么

链路（符号级仿真，含帧同步）：

1. 图像源：默认 `cameraman.tif`，可改为自定义图片（灰度/缩放可配）
2. 成帧：前导（PN）+ Header（尺寸/长度/魔字）+ Payload（原始像素字节）
3. 扰码：PN 异或（可视作加密-lite/白化）
4. 信道编码：卷积码 `poly2trellis(7,[171 133])` + Viterbi 软判决
5. 交织：块交织（对抗突发型脉冲）
6. 调制：BPSK（基线稳）
7. 信道：AWGN + Bernoulli-Gaussian 脉冲噪声
8. 抗干扰：blanking / clipping（阈值可配）
9. 帧同步：用前导相关做粗同步，然后解码重建图像

---

## 3) 你最常改的参数（对应报告的“仿真数据”）

在 `src/link/default_params.m`：

- `p.sim.ebN0dBList`：横轴
- `p.channel.impulseProb`、`p.channel.impulseToBgRatio`：随机脉冲强度/频度
- `p.mitigation.methods`：对比哪些抗干扰策略
- `p.mitigation.thresholdAlpha`：阈值（越大越保守，越小越激进）
- `p.interleaver.nRows`：交织深度（越深越抗突发，但时延/缓存增加）

---

## 4) 你写初赛报告时怎么对齐这些模块

- **信道建模与干扰分析**：解释 BG 模型、参数含义（`impulseProb/impulseToBgRatio`）以及对 BER/图像的影响
- **图像压缩与编码方案**：基线先用 RAW（保证可重建），后续可替换为 JPEG/分块DCT/ROI 等；报告可说明为何要压缩以降低时宽/带宽
- **调制与同步模块设计**：BPSK + 前导相关帧同步（后续可加载波同步/定时同步）
- **抗干扰机制设计**：blanking/clipping + 交织 + 软判决译码的组合对比
- **仿真数据**：直接用本基线输出的 BER/PSNR/PSD/占用带宽，做“无/有抗干扰”对比曲线

---

## 5) 下一步建议（从“能跑”到“能打分”）

1. Header 加 `CRC16/CRC32`，把“头部误判导致尺寸乱跳”从根上消掉
2. 加入更强 FEC：LDPC/Polar/RS+卷积（按你后续迁移到 eLabRadio 的可用模块选）
3. 把抗干扰从 “幅度阈值” 升级到：脉冲检测 + 擦除标记 + 软信息抑制
4. 加入“隐蔽性”论述与仿真：突发、跳频（分段频移）、简单加密/扰码、低功率 PSD 约束
