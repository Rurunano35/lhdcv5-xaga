# LHDC V5 通路（xaga）

在 **Redmi Note 11T Pro（xaga / 天玑 8100 / MT6895）** 上，把 LHDC V5 从
「被固件挡住」变成**开机即用的原生通路**：蓝牙协议栈改走 AIDL 传输层驱动音频 HAL，
LHDC V5 以 `codec_type = 12` **原生送达**（不再被伪装成 V3），并解锁 **192 kHz**。

全部改动仅存在于内存，`/vendor` 与 APEX 分区**磁盘零写入**，卸载后与出厂一致。

> ⚠️ **本项目只针对 xaga（Redmi Note 11T Pro）+ HyperOS `OS2.0.12.0.ULOCNXM`。**
> 模块内移植的 HAL 库取自 Redmi Note 14 Pro（malachite）的固件，按 xaga 的接口版本
> （`bluetooth.audio-V3-ndk`）匹配挑选。**其他机型刷入不会生效，且有开不了机的风险。**
> —— 原理与做法可以借鉴，但产物不能直接搬。详见「[适用范围](#适用范围与前提)」。
>
> 本项目使用DeepSeekV4.1 Flash完成

---

## 背景：手机"不支持"的是什么

LHDC 是 Savitech 的高码率蓝牙音频编解码，V5 是它的第五代。相比通用的 AAC / SBC，
它能跑到 **900 kbps / 24 bit / 192 kHz** —— 这是无损音频传输才需要的数据量级。

xaga 的固件里其实**什么都不缺**：

- V5 编码器库在 APEX 里躺着（`liblhdcv5.so`、`liblhdcv5BT_enc.so`）
- 协议栈里有完整的 V5 实现（能力协商、CIE 报文解析与构建、编码器驱动）
- 平台级 LHDC 开关默认还是开着的

挡住它的是**四道门禁**，其中三道是厂商为 5 个"白名单机型"之外的所有机器设的：


| #      | 门禁                                             | 位置                                 | 能否用内存补丁绕过         |
| ------ | ------------------------------------------------ | ------------------------------------ | -------------------------- |
| G1     | 机型白名单：读`ro.product.name`，只放行 5 个代号 | `A2dpCodecConfig::createCodec`       | ✅                         |
| G2     | HIDL 分发表把`codec_type = 12` 指向错误分支      | `a2dp_get_selected_hal_codec_config` | ✅                         |
| G3     | V3 转换函数要求`codec_type == 10`                | `A2dpLhdcV3ToHalConfig`              | ✅                         |
| **G4** | **HIDL 那一代的 HAL 配置结构里根本没有 V5 字段** | `vendor.mediatek...@2.2`             | ❌**接口定义层面的硬约束** |

G1–G3 可以打补丁，**G4 不行** —— 在 HIDL 链路上，"V5 配置"和"V3 配置"在物理上不可区分，
这正是一些"能出声"的旧方案必须把 `codec_type` 从 12 改写成 10 的原因。

**唯一的出路是换传输层**：MediaTek 的 AIDL 实现里原生带 `Lhdcv5Configuration`，
协议栈内也已有对应的转换函数。栈在 `HalVersionManager` 里会**优先探测 AIDL 服务**，
探测到就走 AIDL —— 此时 G2/G3/G4 一起消失。

所以"V5"等价于一件事：**让协议栈探测到 AIDL 蓝牙音频服务**。

---

## 成果

以下指标均在真机上端到端实测：


| 项目                 | 结果                                                                                     |
| -------------------- | ---------------------------------------------------------------------------------------- |
| 编解码器             | **LHDC V5**，`mCodecType = 12`（非伪装）                                                 |
| 采样率 / 位深 / 声道 | **192 kHz** / 24 bit / 立体声                                                            |
| **PCM 实测速率**     | **1,152,457 B/s**（理论 1,152,000，误差 **0.04%**，设备侧时钟计时）                      |
| 传输层               | **AIDL**（此前一直是 HIDL）                                                              |
| 传输码率             | ABR 上限 =**耳机宣告的最高档位**（原厂封顶 400 kbps，本机耳机高音质档实测 **900 kbps**） |
| 采样率偏好           | 用户改过的采样率**跨断开重连保持**，关闭蓝牙重连也不回落（详见[实现报告 §5.6](docs/LHDC-V5-通路-实现报告.md)） |
| 稳定性               | PCM 零偏差、无 underflow、无崩溃                                                         |
| 磁盘改动             | **零** —— 全部内存挂载，`/vendor` 原件 SHA256 不变                                     |

---

## 它是怎么做到的

### 两部分组成，缺一不可


| 部分            | 内容                           | 作用                                                                |
| --------------- | ------------------------------ | ------------------------------------------------------------------- |
| **Zygisk 补丁** | `zygisk/arm64-v8a.so`          | 绕过 G1 机型白名单；抬高 ABR 码率上限；让用户改过的采样率跨重连保持 |
| **开机挂载**    | `post-fs-data.sh` + `payload/` | 点亮 AIDL 服务、加入 VINTF 声明、放开采样率、关掉 A2DP 硬件 offload |

- 去掉 Zygisk 部分 → V5 在编解码器创建阶段就被丢弃（**已实测**）
- 去掉挂载部分 → 栈仍走 HIDL，V5 被伪装成 V3

### 实现路上撞到的四道障碍

每一道都**只有实测才能定位**，解法都反直觉：


| # | 障碍                                     | 现象                                                                         | 解法                                                                              |
| - | ---------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | `init` 无法 exec bind-mount 的可执行文件 | `execute_no_trans denied`，连把原始二进制挂回去都被拒                        | 不换可执行文件，改为**顶替它本来就会 `dlopen` 的库**（`dlopen` 只需 read + mmap） |
| 2 | `mv` 替换 `ld.config.txt` 会卡开机       | 卡开机动画，换 tmpfs 也一样                                                  | 改为**原地截断重写**，保持同一 inode                                              |
| 3 | servicemanager 开机缓存 VINTF            | 注册返回`status=-3`（未声明）                                                | 整套改动必须在**开机期**完成 → 做成 `post-fs-data.sh`                            |
| 4 | AIDL 实现依赖更新的 libhidlbase          | `cannot locate symbol ...details::check`，`RTLD_GLOBAL` / `RTLD_LAZY` 均无效 | 发现该实现有 3 个冗余`DT_NEEDED`，改写其中之一指向符号补齐库                      |

第 4 点的关键：bionic 重定位 `dlopen` 的库时**只搜索该库自己的 `DT_NEEDED` 闭包**，
不查全局组；而 Android 库普遍带 `DF_BIND_NOW`，`RTLD_LAZY` 也救不了 ——
只能让补齐库**进入依赖闭包**。

### 关于码率

编解码器库本身把目标码率夹在 `[min_bitrate_inx, max_bitrate_inx]` 之间，而
`max_bitrate_inx` **来自耳机在配置里宣告的档位**。原厂把阶梯表的顶格钉在 400 kbps，
本项目的 Zygisk 补丁把顶格抬到耳机许可的最高档（900 kbps），并把"降档"从
「一步掉回最低」改成「一次只降一格」。

**上限始终由耳机说了算，模块不会覆盖**：想要更高码率，请在耳机侧的音质设置里选「高音质」。

---

## 适用范围与前提


| 项目 | 要求                                                                 |
| ---- | -------------------------------------------------------------------- |
| 设备 | **Redmi Note 11T Pro（xaga）**，其他机型**不要刷**                   |
| 系统 | Android 14 / HyperOS`OS2.0.12.0.ULOCNXM`（其他版本未验证）           |
| Root | **KernelSU**（Zygisk 部分依赖 Zygisk Next；Magisk 理论可行但未测试） |
| 耳机 | 支持 LHDC V5 的蓝牙耳机                                              |

> **为什么不能刷到别的机器上**：`payload/` 里的 HAL 库是从另一款手机（Redmi Note 14 Pro）
> 的线刷包里取的，靠 `bluetooth.audio-V3-ndk` 接口版本与 xaga 对上。它的符号、依赖、
> SELinux 标签都按 xaga 这套环境改写。换机器 = 换一整套接口版本和库，不能直接用。
>
> 原理与排查方法是通用的，`docs/` 里的两份定稿文档记录了完整的推理过程，
> 可作其他 MTK 机型的移植参考。

**风险提示**：这是改动系统启动流程的模块。虽然所有改动都在内存里（可通过删除模块
瞬间回退），但**错误使用仍可能导致无法开机**。请确认你会用 `adb` 且知道如何进恢复模式。
首次安装前建议先备份。

---

## 安装

```bash
# 1) 把模块目录推到 KernelSU 的模块目录
adb push module/lhdcv5-real /data/adb/modules/

# 2) 确保启动脚本有执行权限
adb shell su -c 'chmod 0755 /data/adb/modules/lhdcv5-real/post-fs-data.sh'

# 3) 重启
adb reboot
```


## 验证

```bash
# 1) 开机挂载日志（应显示 4 项挂载成功）
adb shell su -c 'cat /data/local/tmp/lhdcv5-aidl.log'

# 2) 编解码器与采样率
adb shell su -c 'dumpsys bluetooth_manager | grep -oE "mCodecConfig: \{[^}]*\}" | head -1'
#   期望：codecName:LHDC V5, mCodecType:12, mSampleRate:0x20(192000)

# 3) 协议栈确实走了 AIDL（而非 HIDL）
adb shell su -c 'logcat -d -b all | grep client_interface'

# 4) ABR 补丁是否落地（2 MiB 日志缓冲会在开机时冲掉模块日志，
#    建议先 logcat -c，再重启蓝牙）
adb shell su -c 'logcat -d -b all | grep LHDCV5A'
#   期望：ABR 表读回一致；降档跳板 44 字节写入 0x6724..0x6750（读回一致）
```

完整的验证清单（含 PCM 速率实测方法、内存补丁字节核对、SHA256 磁盘未改校验）见
[实现报告 §6](docs/LHDC-V5-通路-实现报告.md)。

---

## 卸载与回退

模块自带 `uninstall.sh`。KernelSU 在「移除模块」后的**下次开机**、post-fs-data 阶段
以 root 执行它（cwd = 模块目录），随后才删掉模块目录 —— 它会清掉模块写在**模块目录之外**
的东西，所以这是推荐方式：

```bash
adb shell su -c 'ksud module uninstall lhdcv5-real'   # 或在 KSU 管理器里点移除
adb reboot
```

脚本会（日志留在 `/data/local/tmp/lhdcv5-uninstall.log`）：

- **删除** `persist.bluetooth.a2dp_offload.disabled`（用 `ksud resetprop -p -d` 真删；
  `setprop … ""` 只是持久化一个空值条目，不算删）
- 删除更早实验遗留的 `persist.bluetooth.lhdcv5.sample_rate` / `persist.vendor.bluetooth.lhdcv5.test`
- 删除 `/data/vendor/lhdcv5/`（2.2 MB 落地产物）、`/data/misc/bluedroid/lhdcv5_sr.conf`、
  `/data/local/tmp/ld.new`、`/data/adb/lhdcv5.log` 及 `/data/local/tmp` 下本项目的产物

只停用、不清理：

```bash
adb shell su -c 'touch /data/adb/modules/lhdcv5-real/disable && reboot'
```

**什么会自己消失、什么不会**：`/vendor` 下被 bind 顶替的文件、`/linkerconfig/ld.config.txt`
的补丁、Zygisk 内存补丁，这三样重启即自愈；而上面那条 `persist` 属性和 `/data` 下的文件
**不会**自己走，必须清。不重启的话补丁与挂载都还在，模块"看起来还在工作"。
（顺带一提：「`/vendor` 原件 sha256 不变」恒成立 —— `/vendor` 是只读的 erofs，
模块从未写过它 —— 所以它不能当作回退成功的证据。）

## 常见问题

**为什么必须关掉 A2DP 硬件 offload？**
换成 AIDL 后**所有**编码都走移植过来的 AIDL HAL，包括原本由本机 HIDL HAL 处理的硬件
offload 通路。而 AIDL 侧的两条会话通路里，只有软件通路（`MtkBTAudioProviderA2dpSW`）在
xaga 上可用 —— 硬件 offload 通路（`MtkBTAudioProviderA2dpHW`）的 `startSession` 直接
返回、从不产生 `streamStarted`。本机策略恰好把 SBC / AAC 指向了这条起不来的通路，
所以必须关掉 offload，让它们落到软件通路。LHDC 本来就不在 offload 列表里，不受影响。

**模块会不会改坏系统？**
不会写入 `/vendor` 或 APEX。`payload/` 里的文件被复制到 `/data/vendor/lhdcv5/`，
再通过 `bind-mount` 顶替 `/vendor` 上的对应路径 —— 这些都是内存挂载，重启即消失。
落盘的有：`persist.bluetooth.a2dp_offload.disabled` 这一条持久属性，以及 `/data/vendor/lhdcv5/`（载荷副本）、`/data/misc/bluedroid/lhdcv5_sr.conf`（采样率偏好）、`/data/local/tmp/` 下的模块日志。**卸载模块不会自动清掉它们**，模块自带的 `uninstall.sh` 会在下次开机清掉（见「卸载与回退」）。

**为什么我的码率只有 400 kbps？**
说明耳机在配置里只宣告了低音质档（索引 5 = 400 kbps）。码率上限由耳机许可决定，
请在耳机的音质设置里选「高音质」档。

**会不会影响原来的 AAC / SBC？**
不会。关掉 offload 反而修正了它们（见第一个问题）。移植的 AIDL HAL 对三种编码都是一套
软件通路，LHDC V5 / AAC / SBC 均实测可用。

---

## 仓库结构

```
.
├── module/lhdcv5-real/     交付的 KernelSU 模块（Zygisk 补丁 + 开机挂载）
│   ├── module.prop             模块描述
│   ├── post-fs-data.sh         开机早期：落地载荷 + 写 ld.config + 4 项挂载
│   ├── payload/                移植的 HAL 库、VINTF 清单、BT 音频策略
│   ├── zygisk/arm64-v8a.so     已构建的 Zygisk 补丁
│   └── zygisk-src/             Zygisk 补丁源码（C++，NDK 构建）
├── shim/                   shim 库源码（C++，NDK 构建）
└── docs/
    ├── LHDC-V5-通路-实现报告.md      ← 成果、四道障碍与解法、码率、复现与验证
    ├── LHDC-V5-通路-前置条件分析.md  ← 可行性论证：HIDL/AIDL 边界的硬约束、固件实证
    ├── A2DP-FMQ缓冲-原理与改造.md      ← 专项：A2DP 软件通路 FMQ 环形缓冲的逆向与改造
    └── archive/                        调研过程记录（recon / design / process）
```

> 安装后模块目录即交付物本身，`payload/` 中各文件的目标路径与 SELinux 标签见
> `post-fs-data.sh`，逐项说明见 [模块 README](module/lhdcv5-real/README.md)。
>
> **文档中出现的 `tools/`、`reference/`、`artifacts/`、`romwork/` 等路径不在本仓库内** ——
> 它们是调查过程中在开发者本地建立的逆向脚本、第三方仓库副本、设备 dump 与固件提取产物。
> 本仓库只发布模块源码与文档；文中的结论不需这些文件即可阅读。

---

## 文档


| 文档                                              | 内容                                     | 建议             |
| ------------------------------------------------- | ---------------------------------------- | ---------------- |
| [实现报告](docs/LHDC-V5-通路-实现报告.md)         | 做了什么、怎么做的、遗留问题、复现步骤   | **先读这个**     |
| [前置条件分析](docs/LHDC-V5-通路-前置条件分析.md) | 为什么只能这样做                         | 关心技术原理时读 |
| [A2DP FMQ 缓冲](docs/A2DP-FMQ缓冲-原理与改造.md)  | 软件通路环形缓冲的逆向与字节级改造方案   | 专项深入         |
| [archive/](docs/archive/README.md)                | 8 路侦察报告、3 条候选路线设计、过程记录 | 追溯结论来源时读 |

> `archive/` 反映的是**当时**的判断，其中部分结论已被后续实测推翻。保留它们是为了可追溯，
> **不要直接采信其中的结论** —— 以 `docs/` 下的定稿为准。

---

## 相关项目

- [sprlightning/liblhdc-collections](https://github.com/sprlightning/liblhdc-collections) —— LHDC 编解码器源码与研究资料
- [DBeidachazi/liblhdcv5](https://github.com/DBeidachazi/liblhdcv5) —— Google 开源的 Rust 版 V5 编码器 + Linux 构建封装
- [TheXPerienceProject/android_vendor_savitech_lhdc](https://github.com/TheXPerienceProject/android_vendor_savitech_lhdc) —— Savitech 预编译库打包树

## 致谢

- **移植用的 AIDL 实现 / 音频 HAL 模块 / AIDL session 库**取自 **Redmi Note 14 Pro（malachite）**
  线刷包 `OS1.0.13.0.UOOCNXM`。选它是因为其 AOSP-AIDL 集群基于接口 **v3**，与本机协议栈匹配；
  zircon / corot 的同批库基于 **v2**，本机平台不提供 v2，无法使用。
- **白名单机型映射**参考 `MiCode/MTK_kernel_modules` 的分支表 —— 确认白名单 5 个机型全部是
  联发科平台，与 xaga 同属一个 `vendor.mediatek.hardware.bluetooth.audio` 接口族。
