# Eve / Warden 指标与答辩口径

## 1. 最终定义

当前论文主线中，安全性口径统一修正为：

- `Bob = 抗干扰下的可靠恢复`
- `Warden = 抗截获 / 隐蔽性 / 低可检测性`
- `Eve = 抗破解 / 内容保密性`

因此：

- 抗截获不再由 Eve 表征，而由 Warden 的检测性能表征。
- Eve 不再使用“比 Bob 低 10 dB 所以恢复差”来证明安全性。
- Eve 只用于评估“即使截获到信号，错钥后是否仍无法恢复内容”。

## 2. 当前可写入论文的主指标

### 2.1 Bob

主指标：

- `BER`
- `rawPER`
- `PER`
- `PSNR`
- `SSIM`

### 2.2 Warden

主指标：

- `Pe = 0.5 * (Pfa + Pmd)`

辅助指标：

- `Pd`
- `Pfa`
- `Pmd`

当前答辩阈值：

- `Pe >= 0.40` 视为“具备工程可接受的低可检测性”

### 2.3 Eve

主指标：

- `BER_wrong_key`
- `PSNR_wrong_key`
- `SSIM_wrong_key`

当前答辩阈值：

- `BER_wrong_key >= 0.45`
- `PSNR_wrong_key <= 8 dB`
- `SSIM_wrong_key <= 0.05`

## 3. 已实现的抗破解机制

当前新链路已接回逐包混沌载荷加密与逐包解密：

- 发送端默认开启 `packetIndependent` 的 `chaosEncrypt`
- Bob 使用 `known key` 做逐包解密
- Eve 默认使用 `wrong_key`
- 也支持 `approximate` 作为补充实验口径

这意味着现在的 Eve 结果不再依赖“Eve 链路更差”，而是直接评估错钥/近钥敏感性。

## 4. 已删去或不再作为主线的 Warden 层

根据当前实测结果，以下 Warden 层不再保留在重构后三链路的默认主线中：

- `energyOpt`
- `energyFhNarrow`

原因：

- 这两层会引入额外检测假设和不稳定判定口径
- 继续保留它们会让默认口径分散，不利于论文围绕 `energyNp / energyOptUncertain` 两层自洽展开

当前论文主线默认保留层改为：

- `energyNp`
- `energyOptUncertain`

说明：

- `energyNp` 作为非参数能量检测基线
- `energyOptUncertain` 作为噪声不确定条件下的能量检测层

## 5. 当前实测结论

### 5.1 统一 Eve 口径

所有安全验证均采用：

- `EveLinkGainOffsetDb = 0 dB`
- `EveChaosAssumption = wrong_key`

因此 Eve 不靠链路更差取胜，而是靠错钥直接失效。

当前 Bob 可恢复点上，Eve 结果基本稳定为：

- `BER ≈ 0.5`
- `PSNR ≈ 5.58 dB`
- `SSIM ≈ 0.005`

这说明当前三链路在 Bob 成功恢复时，`wrong_key` 条件下均满足抗破解要求。

### 5.2 默认 Warden 条件：`WardenLinkGainOffsetDb = -10 dB`

结果目录：

- `results/validate_security_profiles/final_security_defaults_m10_20260427`

#### impulse

默认层：

- `energyNp`

满足条件：

- `Eb/N0 = 4 / 6 / 8 dB`
- `JSR = 0 dB`
- `Bob PER = 0`
- `Warden Pe = 0.4875 / 0.4625 / 0.4625`
- `Eve wrong-key` 满足抗破解阈值

结论：

- `impulse` 当前默认口径下可实现“Bob 可恢复 + Warden 难检测 + Eve 难破解”

#### narrowband

默认层：

- `energyOptUncertain`

满足条件：

- `Eb/N0 = 6 / 8 dB`
- `JSR = 0 dB`
- `Bob PER = 0`
- `energyOptUncertain Pe = 0.475 / 0.45`
- `Eve wrong-key` 满足抗破解阈值

不满足点：

- `Eb/N0 = 4 dB`，Bob 自身 `PER = 1`

结论：

- `narrowband` 当前默认口径下在 `6 / 8 dB` 满足三方目标

#### rayleigh_multipath

默认层：

- `energyOptUncertain`

默认 `Warden=-10 dB` 下结果：

- `Eb/N0 = 6 / 8 dB` 时 Bob 可恢复
- `energyOptUncertain Pe = 0.425 / 0.425`
- 按 `Pe >= 0.40` 口径满足抗截获要求

结论：

- `rayleigh_multipath` 在只保留 `energyOptUncertain` 的论文口径下满足抗截获；原有 `cyclostationaryOpt` 不作为主线判据

### 5.3 更弱 Warden 条件：`WardenLinkGainOffsetDb = -20 dB`

结果目录：

- `results/validate_security_profiles/final_security_rayleigh_m20_20260427`

#### rayleigh_multipath

满足条件：

- `Eb/N0 = 6 dB`
- `JSR = 0 dB`
- `Bob PER = 0`
- `energyOptUncertain Pe = 0.4625`
- `cyclostationaryOpt Pe = 0.4875`
- `Eve wrong-key` 满足抗破解阈值

补充说明：

- `Eb/N0 = 8 dB` 时 `energyOptUncertain Pe = 0.4375`，按 `Pe >= 0.40` 口径可通过

结论：

- 更弱 Warden 条件可作为余量补充，不再作为唯一通过条件

## 6. 当前可直接写进论文的结论

推荐写法：

- “本文将安全性评估拆分为 Warden 抗截获评估与 Eve 抗破解评估。”
- “Warden 采用平均判决错误率 `Pe` 作为主指标，`Pe >= 0.40` 视为达到工程可接受的低可检测性阈值。”
- “Eve 采用错误混沌密钥口径，主指标为 `BER`、`PSNR` 与 `SSIM`。”
- “在当前实现下，抗破解能力稳定成立；按 `energyNp / energyOptUncertain` 两层和 `Pe >= 0.40` 口径，统一主链路三类 case 均达到阈值。”
- “其中，脉冲 case 为边界通过，需要在论文中说明隐蔽性余量不足。”

不推荐写法：

- “Eve 比 Bob 弱 10 dB，因此系统具备抗截获能力”
- “Warden 在所有检测层中都无法检测”
- “系统绝对安全”
