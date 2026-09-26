# 归档：调研过程记录

这里保存的是实现过程中的**中间产物**，按性质分三类。保留是为可追溯，
**其中的结论不要直接采信** —— 部分已被后续实测推翻。定稿以 `docs/` 下两份文档为准。

---

## recon/ —— 8 路并行侦察报告

实现前做的系统性调查，每一份都要求"结论必须有可复现的证据"。

| 文件 | 内容 |
|---|---|
| `R1-aosp-hidl-hal.md` | AOSP Android 14 蓝牙音频 HIDL/AIDL 路径源码分析。**重要发现**：原生 AOSP 的分发里根本没有 LHDC，是小米/MTK 自行加入的 |
| `R2-libbluetooth_jni-二进制取证.md` | 本机栈二进制取证：三套 codec→HAL 转换函数族的符号枚举（HIDL 侧无 V5 转换函数） |
| `R3-厂商HAL与音频通路取证.md` | 厂商 HAL 与音频通路：谁 openOutputStream、PCM 走 FMQ 等 |
| `R4-miui-branch.md` | MIUI 分支特性：白名单的作用点与范围 |
| `R5-参考仓库-liblhdc-collections-分析.md` | 第三方 LHDC 仓库的作用边界（结论：只解决编码器层） |
| `R6-设备实况核查.md` | 设备只读体检：属性、服务、库、进程映射等 |
| `R7-bt-audio-hal-pipeline.md` | 蓝牙音频 HAL 管线地图（HIDL vs AIDL 的完整数据流） |
| `R8-gap-analysis.md` | V5 与伪装 V5 的差异清单（后经 V3 证伪，多数"差异"实为不存在） |

## design/ —— 三条候选路线设计

| 文件 | 路线 | 最终判定 |
|---|---|---|
| `D1-aidl-bridge.md` | 补上 AIDL 服务让栈切到 AIDL | **方向正确**，但当时评估为"收益低"，因为漏看了 MTK 版 session 库含 192 kHz |
| `D2-own-vendor-hal.md` | 自建 HIDL 厂商 HAL | 否决（HIDL 语义下无法原生携带 V5）。**其中"移植大概率不能解锁 192kHz"的推断是错的**，被固件实证推翻 |
| `D3-in-stack-v5.md` | 栈内提供 V5 转换函数 | 否决（功能收益为零） |

## process/ —— 过程记录

| 文件/目录 | 内容 |
|---|---|
| `MAIN-findings.md` | 阶段性汇总结论 |
| `deploy-scripts/` | 28 个逐阶段部署脚本，记录了排除过程中尝试过的每一种做法 |

---

## 从这批记录里得到的教训

见实现报告 §8「方法论备忘」。核心三条：

1. **同一接口的两个实现可能有不同能力** —— 只看 AOSP 版 session 库导致漏判 192 kHz
2. **要设计能区分变量的实验** —— 卡开机时未区分 ld.config 的"内容"与"inode"
3. **功能表现才是判据** —— Zygisk 会隐藏模块映射，看不到 maps 不等于没加载
