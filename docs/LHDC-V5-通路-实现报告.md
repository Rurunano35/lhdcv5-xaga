# xaga LHDC V5 通路实现报告

> 设备：Redmi Note 11T Pro（xaga / MT6895 / 天玑 8100）
> 系统：Android 14 / HyperOS `OS2.0.12.0.ULOCNXM`
> 日期：2026-09-25
> 交付物：`module/lhdcv5-real/` —— 单一 KernelSU 模块

---

## 1. 成果

LHDC V5 在 xaga 上**以原生形态端到端跑通**，关键指标全部实测：

| 项目 | 结果 | 证据 |
|---|---|---|
| 编解码器 | **LHDC V5**，`mCodecType = 12` | `dumpsys bluetooth_manager` |
| 采样率 | **192 kHz** | `mSampleRate = 0x20` |
| 位深 / 声道 | 24 bit / 立体声 | 同上 |
| **PCM 实测速率** | **1,152,457 B/s**（理论 1,152,000，误差 **0.04%**） | 设备侧 `/proc/uptime` 计时两个采样点 |
| 传输层 | **AIDL**（`client_interface_aidl.cc`） | 此前一直是 `client_interface_hidl.cc` |
| 传输码率 | ABR 档上限 = **耳机宣告的最高档位**（本机 900 kbps，原厂封顶 400），见 §5.5 | 编码器日志 |
| 采样率偏好 | 用户改过的采样率**跨断开重连保持**（§5.6） | 重连日志 `采样率已生效（实际 = 期望 = 0x20）` |
| 稳定性 | PCM `expected/actual` 零偏差，无 underflow，无崩溃 | `dumpsys` |

**与"伪装方案"的本质区别**：旧方案在 HIDL 分发层把 `codec_type = 12`（V5）**改写为 10**（V3），
使 HAL 收到一份"V3 配置"。本方案让 V5 **原生送达** HAL，协议栈内部与 HAL 接口两端的
`codec_type` 都是 12。

---

## 2. 为什么必须原生送达 —— 以及原生到什么程度

### 2.1 四道门禁

| # | 门禁 | 位置 | 说明 |
|---|---|---|---|
| **G1** | 机型白名单 | `A2dpCodecConfig::createCodec` @ `0x763470` | 读 `ro.product.name` 与 `{corot, duchamp, zircon, rothko, malachite}` 比对；xaga 不在名单 → V5 在**编解码器创建阶段**即被丢弃 |
| **G2** | HIDL 分发表 | `a2dp_get_selected_hal_codec_config` 跳转表 `[12]` | HIDL 路径下索引 12 指向错误分支（`Unknown codec_type=12`） |
| **G3** | HIDL 等值校验 | `A2dpLhdcV3ToHalConfig` @ `0x82a904` | 要求 `codec_type == 10` |
| **G4** | **HIDL 接口无 V5 结构** | `vendor.mediatek.hardware.bluetooth.audio@2.2` | 该代次的 HAL 配置结构里**根本没有 V5 字段** |

G1–G3 可用内存补丁绕过（旧方案的做法），但 **G4 是接口定义层面的硬约束** —— 纯补丁无法解决，
只能"伪装"。这正是旧方案必须把 12 改写成 10 的原因，也是 `A2dpLhdcv5ToHalConfig` 在 HIDL 侧
根本不存在的原因。

### 2.2 唯一的通路：AIDL

设备上的 MediaTek AIDL 实现 `vendor.mediatek.hardware.bluetooth.audio-impl.so`
（白名单机型所带、xaga 缺失）**原生包含 `Lhdcv5Configuration`**，协议栈内也已存在
对应的转换函数 `A2dpLhdcv5ToHalConfig`。栈在 `HalVersionManager` 里**优先探测 AIDL 服务**，
探测到就走 AIDL —— 此时 V5 是原生支持的，G2/G3/G4 全部消失。

因此"V5"等价于：**让 `HalVersionManager` 探测到 AIDL 蓝牙音频服务**。

---

## 3. 实现路径：四道障碍与解法

把 AIDL 实现搬进本机，一路上撞到四个**各自独立、均需实测才能定位**的障碍。

### 障碍 1 —— `init` 无法 exec bind-mount 的可执行文件

最直觉的做法是替换音频 HAL 服务二进制 `android.hardware.audio.service.mediatek`
（AIDL 实现是**被它直接链接**的）。实测失败：

```
avc: denied { execute_no_trans } for comm="init"
     path="/vendor/bin/hw/android.hardware.audio.service.mediatek"
     dev="dm-55" tcontext=u:object_r:mtk_hal_audio_exec:s0 tclass=file
init: cannot execv(...): Permission denied
```

**控制实验**：把 **xaga 自己的原始二进制**复制到 `/data`、打上完全相同的标签
（`mtk_hal_audio_exec`）、`chmod 0755`、再 bind-mount 回原路径 —— **同样被拒**。
换 tmpfs、devtmpfs 亦同。

→ 与文件内容、SELinux 标签、文件系统**都无关**，是 `init` 对 bind-mount 文件
不做域转换。**这条路整体不通。**

**解法**：不替换可执行文件，改为**顶替它本来就会 `dlopen` 的库**。
`registerPassthroughServiceImplementation` 会 `dlopen`
`/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so`
并查找 `HIDL_FETCH_IBluetoothAudioProvidersFactory`。
`dlopen` 只需要 `read` + `mmap`，**不受 `execute` 限制**。

于是写一个 **shim** 顶替该文件：
1. `dlopen` HIDL 实现（原名迁到 `/data/vendor/lhdcv5/real_hidl22.so`）并**转发 FETCH** —— 保证 HIDL 通路不回归；
2. 借这次加载**点亮 AIDL**。

### 障碍 2 —— `mv` 替换 `/linkerconfig/ld.config.txt` 会卡开机

AIDL 实现与其依赖都在 `/data/vendor/lhdcv5/`，必须让厂商命名空间能搜索到它，
即往 `/linkerconfig/ld.config.txt` 的 `[vendor]` 段加搜索路径。

第一版用 `awk > 新文件 && mv` 替换 —— **设备卡在开机动画**。
改为**原地截断重写**（`cat new > $CFG`，保持同一 inode）—— **开机正常**。

```
inode before: 5  →  inode after: 5      # 原地写入
锚点行存在 ✓                              # 确认补丁插入过，不是空操作
```

运行中测试也佐证：打完补丁后批量重启 8 个厂商服务，**0 失败** ——
补丁内容本身无害，问题出在 inode 变化。

### 障碍 3 —— servicemanager 开机缓存 VINTF

AIDL 服务注册（`@VintfStability`）要求服务在设备 VINTF 清单中声明。
而 **servicemanager 在开机时缓存 VINTF**（其二进制内含
`Could not find %s.%s/%s in the VINTF manifest.` 与 `VintfObject::GetInstance()`，
且**无运行时禁用开关**）。运行中挂载清单不生效：

```
W BtAudioAIDLService: Could not register .../IBluetoothAudioProviderFactory/default, status=-3
```

（`-3` = `STATUS_INVALID_OPERATION` = "未在 VINTF 中声明"）

**解法**：整套改动必须在**开机期**完成 —— 因此必须做成 KernelSU 模块的
`post-fs-data.sh`，不能只靠 ADB。

> 附带结论：设备兼容性矩阵（FCM）**允许** AOSP 名 `android.hardware.bluetooth.audio` v3 AIDL，
> 所以 manifest 改动是合法的；而 MTK 名 AIDL **不在 FCM 中**，故"改用 MTK 名以规避改动"不可行。

### 障碍 4 —— AIDL 实现依赖更新的 libhidlbase

AIDL 实现（取自 malachite / Redmi Note 14 Pro，接口版本 v3，与本机栈匹配）导入了
xaga 的 `libhidlbase.so` **不提供**的符号：

```
dlopen failed: cannot locate symbol
  "_ZN7android8hardware7details5checkEbPKc"   # android::hardware::details::check(bool, char const*)
```

`RTLD_GLOBAL` 预加载补齐库**无效** —— bionic 在重定位 `dlopen` 的库时**只搜索它自己的
DT_NEEDED 闭包**，不查全局组（`RTLD_LAZY` 也无效，因为 Android 库普遍带 `DF_BIND_NOW`，
强制立即重定位）。

**解法**：静态分析发现该实现有 **3 个 DT_NEEDED 完全是冗余的**
（`vendor.mediatek.hardware.bluetooth.audio@2.1.so`、`@2.2.so`、`-V1-ndk.so`
—— 实现用到它们的符号数均为 **0**）。于是**改写其中一个 DT_NEEDED 字符串**，
指向符号补齐库 `/data/vendor/lhdcv5/shimsym.so`，使补齐库进入实现的依赖闭包：

```
改写前: ...  libbluetooth_audio_session_aidl_mtk.so
             vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so
             vendor.mediatek.hardware.bluetooth.audio@2.1.so      ← 冗余槽
             vendor.mediatek.hardware.bluetooth.audio@2.2.so
改写后: ...  libbluetooth_audio_session_aidl_mtk.so
             vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so
             /data/vendor/lhdcv5/shimsym.so                       ← 补齐库
             vendor.mediatek.hardware.bluetooth.audio@2.2.so
```

### 障碍 5 —— 192 kHz 被音频策略钳制

AIDL 打通后能力列表已暴露 `192000`，但实际协商不到 ——
`/vendor/etc/bluetooth_audio_policy_configuration.xml` 的三个 A2DP 设备口写的是
`samplingRates="44100 48000 88200 96000"`。加入 `176400 192000` 后即达成。

---

## 4. 交付物

### 4.1 模块结构

```
module/lhdcv5-real/
├── module.prop               模块描述
├── post-fs-data.sh           开机早期：落地载荷 + 写 ld.config + 4 项挂载 + 关 A2DP offload
├── uninstall.sh              卸载清理：删 offload 持久属性 + 清 /data 下的残留（见 §6.3）
├── payload/                  19 个文件
│   ├── shim.so                       顶替 MTK HIDL 2.2 实现（含 AIDL 点亮）
│   ├── shimsym.so                    补齐 android::hardware::details::check
│   ├── real_hidl22.so                xaga 原 HIDL 实现（SONAME 已改写）
│   ├── android.hardware.bluetooth.audio-impl.so        MTK AIDL 实现（DT_NEEDED 已改写）
│   ├── audio.bluetooth.default.so    AIDL 版音频 HAL 模块
│   ├── libbluetooth_audio_session_{aidl,aidl_mtk,mediatek}.so
│   ├── android.hardware.bluetooth.audio-V3-ndk.so
│   ├── android.hardware.common{-V2-ndk,.fmq-V1-ndk}.so
│   ├── android.hardware.audio.common-V1-ndk.so
│   ├── android.media.audio.common.types-V2-ndk.so
│   ├── android.system.suspend-V1-ndk.so
│   ├── vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so
│   ├── libPlatformProperties.so / libstdc++.so
│   ├── manifest.xml                 含 AIDL 声明的设备 VINTF 清单
│   └── bt_audio_policy.xml          samplingRates 加入 176400/192000
└── zygisk/
    └── arm64-v8a.so          纯内存补丁：G1 机型白名单绕过、ABR 码率上限、采样率偏好保持
```

### 4.2 模块做的五件事（post-fs-data）

1. 载荷从模块目录复制到 `/data/vendor/lhdcv5/`（**不能放模块目录** —— 那里的挂载会被剥离），
   并按原件设置 SELinux 标签（`.so` → `vendor_file`，xml → `vendor_configs_file`）；
2. **原地写入** `/linkerconfig/ld.config.txt`，给 `[vendor]` 命名空间加 `/data/vendor/lhdcv5`；
3. `bind-mount` 四个文件：

   | 目标 | 作用 |
   |---|---|
   | `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so` | shim：点亮 AIDL + 转发 HIDL |
   | `/vendor/lib64/hw/audio.bluetooth.default.so` | AIDL 版音频 HAL 模块 |
   | `/vendor/etc/vintf/manifest.xml` | 加入 AIDL 声明 |
   | `/vendor/etc/bluetooth_audio_policy_configuration.xml` | 放开采样率到 192 kHz |

4. `setprop persist.bluetooth.a2dp_offload.disabled true`（见 4.4）；
5. 除第 4 步外，改动仅存在于内存，`/vendor` 原件未变（可用 `sha256sum` 验证）。
   第 4 步会落到 `/data/property`，回退方式见 `module/lhdcv5-real/README.md`。

### 4.3 Zygisk 部分（G1）

`A2dpCodecConfig::createCodec` 读 `ro.product.name` 时返回白名单内的 `corot`。
**纯内存补丁**：只重定向 `libbluetooth_jni.so` 的一个 GOT 槽
（`osi_property_get` @ `r_offset 0xf94428`）。GOT 在数据页，
`mprotect(RW)` 写入后恢复 `R`，不涉及 `PROT_EXEC`，不触发 SELinux `execmod` 限制。

> 与旧模块的区别：旧模块还做了 P1（改写跳转表）与 P2（改写 `codec_type`），
> 那是 HIDL 伪装时期的手段。本模块**刻意不碰** `.text`、跳转表与 `codec_type`。

### 4.4 为什么必须关掉 A2DP 硬件 offload

换成 AIDL 后，**所有**编码都走移植过来的 AIDL HAL，包括原本由本机 HIDL HAL 处理的
硬件 offload 通路。而 AIDL 侧有两条会话通路：

| 会话通路 | 实现 | 本机状态 |
|---|---|---|
| `A2DP_SOFTWARE_ENCODING_DATAPATH` | `MtkBTAudioProviderA2dpSW` | **可用** —— LHDC V5 走的就是它（48k/96k/192k 24bit 均实测通过） |
| `A2DP_HARDWARE_OFFLOAD_ENCODING_DATAPATH` | `MtkBTAudioProviderA2dpHW` | **起不来** —— `startSession` 立即返回，从无 `streamStarted` |

本机策略 `persist.bluetooth.a2dp_offload.cap=sbc-aac` 只把 **SBC 与 AAC** 指向
offload 通路，于是这两个编码选出来没有声音；LHDC 不在 offload 列表里，因此不受影响。

证据（关掉 offload 前后同一编码的落点）：

```
# offload 开：AAC 会话打在 A2dpHW 上，只打了两行就返回
D/MtkBTAudioProviderA2dpHW: +startSession : 0x...
D/MtkBTAudioProviderA2dpHW: -startSession()

# offload 关：AAC 落到 A2dpSW，配置成功
I/a2dp_encoding_aidl.cc(394) a2dp_get_selected_hal_codec_config: codecType: AAC
I/a2dp_encoding_aidl.cc(417) a2dp_get_selected_hal_pcm_config: 44100/STEREO/16
I/MtkBTAudioProviderStub: updateAudioConfiguration - SessionType=A2DP_SOFTWARE_ENCODING_DATAPATH
I/MtkBTAudioProviderA2dpSW: UpdateFMQSize bytes_per_tick = 4057 - size of audio buffer 7680 byte(s)
```

所以 `post-fs-data.sh` 第 4 步关掉 offload，把 SBC/AAC 交给软件通路。
代价是 SBC/AAC 不再由 DSP 编码（多耗一点 CPU），换来的是这两个编码能用。

> **日志里的一个假线索**：`E client_interface_aidl.cc(269) UpdateAudioConfig:
> BluetoothAudioHal failure: Status(-3, EX_ILLEGAL_ARGUMENT)` 是**无害**的。
> 它紧跟在 `MtkBTAudioProviderStub: updateAudioConfiguration ... has NO session`
> 之后，只是"会话尚未建立时被调用"的顺序问题，协议栈记录为 ERROR 后照常继续。
> 同类的 `SetLowLatencyModeAllowed: BluetoothAudioHal is not ready` 同理。

---

## 5. 码率实测：ABR 与 HIGH 两档

> `dumpsys bluetooth_manager` 的 `LHDC transmission bitrate (Kbps)` 字段**单位标注有误**，
> 数值实际是 bps；`LHDC quality mode` 才是档位。

实测环境：Redmi Buds 5 Pro，LHDC V5，96 kHz / 24 bit / 立体声，手动选中 V5。

### 5.1 两档实测结果

| 档位（`LHDC quality mode`） | `dumpsys` 读数 | 编码器 `actual_bitrate` | 等效位深 @96k/24 |
|---|---|---|---|
| `ABR`（自适应） | 400000 | 403200 | 2.08 bit/样本 |
| `HIGH_900` | 900000 | 902400 | 4.69 bit/样本 |

`actual_bitrate` 比标称高约 0.8%，来自帧切分的取整（`cal_frame_size_and_frames_in_packet`
会打印 `target_bytes_per_second` 与 `handle->actual_bitrate` 两个值）。

### 5.2 ABR 模式的表现

ABR 会在链路质量变化时双向调整索引。一次实测序列（96 kHz/24 bit）：

```
22:53:10 [ABR_ADJ](DN) bitrate(400) to bitrate(256)   ← 触发源：AUDIO_CHOPPY，重传 2463 / 丢包 1962
22:54:10 [ABR_ADJ](UP) bitrate(256) to bitrate(320)
22:54:42 [ABR_ADJ](DN) bitrate(320) to bitrate(256)
22:55:42 [ABR_ADJ](UP) bitrate(256) to bitrate(320)
22:56:42 [ABR_ADJ](UP) bitrate(320) to bitrate(400)
22:57:42~23:04:42 [ABR_ADJ](UP) next bitrate not changed (400)[5]   ← 连续 8 分钟上爬无效
```

**结论：原厂状态下 ABR 档在本机封顶 400 kbps。** 不是"不上爬"，而是爬到了档位上限 ——
`next bitrate not changed (400)[5]` 表示算出来的下一档仍是索引 5。这解掉了本节此前
"ABR 模式为何不上爬尚未查清"的疑问。

> 注意：这条日志与表里的数值**无关**（打印的是当前码率与当前索引），改表不会让它变化。
> 模块已把上限抬到耳机宣告的档位，原因与修法见 §5.5。

### 5.3 码率阶梯（从 `liblhdcv5.so` 提取）

`/apex/com.android.btservices/lib64/liblhdcv5.so` 内嵌 5 组 15 元素的 u32 码率阶梯，
其中与实测吻合的一组为（单位 kbps，索引从 0 起）：

```
索引:  0    1    2    3    4    5    6    7     8     9     10    11    12    13
值:   64  128  192  256  320  400  500  900  1000  1100  1200  1300  1400  (哨兵)
```

实测 `succeed (3, 256)` / `(5, 400)` / `(7, 900)` 与该表逐项对上。**档位决定 ABR 的索引上限**：
`ABR` 停在 400（索引 5），`HIGH_900` 到 900（索引 7）。

### 5.4 对 192 kHz 的影响

| 组合 | 码率 | 等效位深 |
|---|---|---|
| 96 kHz + HIGH_900 | 900 kbps | 4.69 bit/样本 |
| 192 kHz + HIGH_900 | 900 kbps | 2.34 bit/样本 |
| **192 kHz + ABR** | **400 kbps** | **1.04 bit/样本** |

LHDC V5 的档位上限就是 900 kbps（`LHDCV5_QUALITY_HIGH_900`），**192 kHz 配不到足够码率**。
从等效位深看，**96 kHz + HIGH_900 明显优于 192 kHz**。

档位由耳机侧音质设置决定（日志中对应 `BluetoothA2dp.setCodecConfigPreference`
→ `btif_a2dp_source_encoder_user_config_update_req`），**模块不参与也不应干预**。
建议在耳机音质设置里选「高音质」，再按听感在 96 kHz 与 192 kHz 之间取舍。

### 5.5 抬高 ABR 上限：已实现（上限 = 耳机宣告的最高档位）

**目标**：让自适应档（ABR）的码率上限从 400 kbps 抬到**耳机自己宣告的最高档位**
（本机耳机在「高音质」档宣告 900 kbps）。**不覆盖耳机的宣告**——耳机只宣告 400 时，
上限就保持 400。

#### 5.5.1 钳制链

ABR 卡在 400 是**三层**叠加的结果，缺一层都改不动；这也解释了此前「写后读回一致却无效」。

**第 1 层 —— ABR 的上爬门槛（`liblhdcv5BT_enc.so`，直接原因）**

`lhdcv5BT_adjust_bitrate` 的全局表索引在 `.bss`（该库唯一的 4 字节全局，VA `0x8310`），
初始化即置为**表长−1 = 5**（`lhdcv5BT_init_encoder` 在 quality==13 时 `mov w8,#5` →
`0x57b8 str w8,[x22,#0x310]`；`lhdcv5BT_set_bitrate` 的 AUTO 路径同样写 5）。上爬时取

```
0x4dc8  cmp  w8, #5
0x4dcc  cinc w24, w8, lo        ; w24 = (index < 5) ? index+1 : index   → 恒 ≤ 5
0x4dd0  ldr  w25, [x27, w24, u32 #2]   ; 新目标 = table[w24]
...
0x4e60  cmp  w24, w4            ; w4 = [0x8310] 当前索引
0x4e64  b.ls 0x4e9c             ; next <= index 就放弃
```

索引初值就是 5，于是 `w24 == index` 恒成立、`b.ls` 永远命中，`set_target_bitrate_inx`
**在 AUTO 档下从第一次调用起就是死路**——表顶格的值（`table[5]`）只在 4→5 那一次跃迁时
才被用到，冷启动则永远用不上。原设计里表顶格 = `ABR_MAX_STAGE_BITRATE` = 400，
所以表现就是封顶 400，日志逐分钟打 `(UP) next bitrate not changed (400)[5]`。

> 关键教训：`(400)[5]` 这条日志在**改表前后完全一样**（索引不动、被 gate 跳过，
> 打印的是当前码率与索引，与表值无关）。此前据它判定「补丁未生效」是错的。

**第 2 层 —— AUTO 档的起始码率由核心库写死（`liblhdcv5.so`）**

`lhdcv5_util_set_target_bitrate_inx(handle, inx, out, apply)` 对普通索引做
`clamp(inx, [ctx+0x78]=min, [ctx+0x74]=max)`；**但 `inx == 13`（AUTO）时忽略请求值**，
改用固定索引 5（`0xcf6d8 cmp w8,#5` / `0xcf6dc mov w11,#5` / `0xcf6e0 csel`），
再夹进 `[min, max]`。这与表顶格的 400 恰好一致，是原设计的自洽点。

**第 3 层 —— 协议栈下发的 max 索引（`libbluetooth_jni.so`）**

`a2dp_vendor_lhdcv5_encoder_init`（`0x7a4260`）把「编解码器配置里宣告的码率档位」经

```
0x7a46d0  A2DP_VendorGetMaxBitRateLhdcV5(&val, codec_info)   ; 来自耳机 CIE 的 2-bit 字段
0x7a46f4  w8 = table[val]        ; 表 @ .rodata 0x2c407c = {0,1,2,3,4,5,6,7,13}
0x7a46fc  str w8, [ctx+0x554]    ; → max_bitrate_inx
```

换算成 `max_bitrate_inx`，再交给 `lhdcv5BT_set_max_bitrate` → `lhdcv5_util_set_max_bitrate_inx`
→ `lhdcv5_encoder_set_max_bitrate_inx`（`0xd00a8 str w4,[x19,#0x74]`，合法区间 `[5,12]`）。
即**上限最终由耳机宣告**：实测 7 次会话宣告 7（HIGH = 900 kbps）、2 次宣告 5（LOW = 400 kbps），
随耳机侧音质设置变化。核心库的 clamp 会把超出的请求压回该值 —— **本模块保持这一约束不动**，
所以这一层不需要任何补丁；ABR 阶梯的顶格只需对齐到耳机能宣告的最高档位（900 kbps，索引 7），
请求值就不会超出耳机许可，也就无需依赖 clamp 回收。

#### 5.5.2 七项补丁（都在 `liblhdcv5BT_enc.so`）

| # | 位置 | 类型 | 原值 | 新值 | 作用 |
|---|---|---|---|---|---|
| 1 | `.rodata` `0x2ac8`(44.1k) | 数据 | 128/192/240/320/400/**400** | 128/192/240/320/400/**900** | ABR 阶梯顶格 |
| 2 | `.rodata` `0x2ab0`(48k) | 数据 | 128/192/256/320/400/**400** | 128/192/256/320/400/**900** | 同上 |
| 3 | `.rodata` `0x2ae0`(96k/192k) | 数据 | 256/320/400/400/400/**400** | 256/320/400/400/400/**900** | 同上 |
| 4 | `.bss` `0x8310` | 数据 | (运行时) | 索引为顶格(5)时退一格 → 4 | 绕过第 1 层门槛 |
| 5 | `.text` `0x4f34` | 代码 | `ldr w24,[x27]` | `b` 到跳板 A | 降档落点 = table[tier−1] |
| 6 | `.text` `0x50a0` | 代码 | `str wzr,[x25,#0x310]` | `b` 到跳板 B | 降档回写 tier−1 |
| 7 | `.text` `0x6724`..`0x6750` | 代码 | (PLT0 死槽) | 两段跳板（11 条指令） | 上面两跳的目的地 |

只动每张表的**第 5 格**，其余格子保持原样 —— 这样绝不会引入该采样率家族阶梯里不存在的值
（`lhdcv5_util_get_bitrate_inx` 解析不出会走 ABR 的错误分支）。900 在全部 5 组阶梯里都存在
（索引 7），且恰好等于耳机宣告的 max，所以请求值与许可值一致。

第 4 项是本模块唯一需要「持续起作用」的补丁：把已到顶格的索引退回一格，使下一次决策走
正常的 `取 table[index+1]` 路径，顶格值照样下发。只在索引确实等于顶格时写，所以降档
（索引归 0 后的上爬）路径完全不受影响。**它是 .bss 里的普通可写内存，不需要 mprotect。**
第 5–7 项见 §5.5.7。

**实际效果**：

| 耳机宣告 | max_bitrate_inx | ABR 实际上限 |
|---|---|---|
| 7（`LHDCV5_QUALITY_HIGH`，高音质档） | 7 | **900 kbps** |
| 5（`LHDCV5_QUALITY_LOW`） | 5 | 400 kbps（保持耳机许可） |

#### 5.5.3 为什么第 4 项是改 `.bss` 索引，而不是改那条分支指令

对 `.text` 的两条路在本机都被 SELinux 堵死，且**失败方式很危险**：

1. **`mprotect(RW)` 写、再 `mprotect(R|X)` 恢复 —— 先摘 X 再想加回来不可行。**
   恢复那一步被内核以 `EACCES`（errno=13，execmod）拒绝，**而 memcpy 已经执行**，
   页就永久停在 `RW`、失去执行位。实测后果：`liblhdcv5BT_enc.so` 的 `0x4000` 页同时含
   `lhdcv5BT_get_handle`(0x40b0) 与目标指令(0x4e64)，于是蓝牙进程在
   `a2dp_vendor_lhdcv5_encoder_init` 里 `blr` 进该函数时 `SIGSEGV / SEGV_ACCERR`，
   **进入崩溃循环**（tombstone 已取证）。
   → **可行写法：首次 mprotect 就一次给出 `R|W|X`**（页自始至终可执行，也就不会触发
   execmod 检查），写完再恢复 `R|X` —— 恢复会成功。本模块的 `patch_text()` 即按此实现，
   实测两个站点写后读回一致且页已正确回到 `R|X`。
2. **`/proc/self/mem`（`FOLL_FORCE` 写只读页、不动保护位）—— 不可行。**
   `open("/proc/self/mem", O_RDWR)` 直接被拒（errno=13）。

第 4 项不需要写代码，改成操作 `.bss` 里的索引即可，效果与放宽那条门槛等价。
而第 5–7 项非改代码不可，用的就是上面那条「一次给出 RWX」的写法。

#### 5.5.4 验证方法

```bash
# 1) 补丁是否落地（模块自己的日志）
adb shell su -c 'logcat -d -b all | grep LHDCV5A'
#   期望看到：ABR 表 {44100,48000,96k/192k} … 读回一致
#             构建已确认，启用 ABR 索引退格
#             （不应出现 patch_bytes 失败或 SIGSEGV）

# 2) 上限确实等于耳机宣告（编码器库的日志）
adb shell su -c 'logcat -d -b all | grep lhdcv5BT_enc'
#   期望：lhdcv5BT_set_max_bitrate: Update Max target bitrate(LHDCV5_QUALITY_HIGH)
#   该档位名由编码器库的 rate_to_string 打印，本机耳机高音质档即索引 7 = 900 kbps。

# 3) ABR 实际爬升（关键证据）
adb shell su -c 'logcat -d -b all | grep -a "AUTO_BITRATE"'
#   期望出现 (UP) br_table[…] to br_table[…] 且目标码率到 900；
#   不再出现 "next bitrate not changed (400)[5]"。

# 4) 若怀疑进程不稳
adb shell su -c 'ps -A -o PID,NAME | grep com.android.bluetooth'   # 隔几秒采两次，pid 应不变
```

#### 5.5.5 设备实测结果（2026-09-26）

补丁落地日志（模块自己的 LOGI）：

```
ABR 表 44100    128/192/240/320/400/400 -> 128/192/240/320/400/900 (读回一致)
ABR 表 48000    128/192/256/320/400/400 -> 128/192/256/320/400/900 (读回一致)
ABR 表 96k/192k 256/320/400/400/400/400 -> 256/320/400/400/400/900 (读回一致)
构建已确认，启用 ABR 索引退格
```

上限确实等于耳机宣告的档位（编码器库日志）：

```
lhdcv5_encoder_set_max_bitrate_inx: last bitrate (400) upd_max_bitrate (900)
lhdcv5BT_set_max_bitrate: Update Max target bitrate(LHDCV5_QUALITY_HIGH)   ← 索引 7 = 900 kbps
lhdcv5BT_set_bitrate: [Set BiTrAtE] (LHDCV5_QUALITY_LOW) ABR_table_index(5)
lhdcv5BT_set_bitrate: Update target bitrate (LHDCV5_QUALITY_LOW) bitrate_inx(13)  ← 13 = AUTO
```

ABR 实际上爬（`[AUTO_BITRATE][ABR_ADJ]`，48 kHz / 24 bit）。
**补丁 1–4（上限相关）落地后、补丁 5–7（降档）之前**：

```
12:15:35 (UP) bitrate(400)[4] to bitrate(900)[5], queuSumTmp(0)   ← 到达表顶格 900
12:15:35 (DN) bitrate(400)[4] to bitrate(128)[0], queueLength(1)  ← 0.4 s 后链路吃不住，一次掉到底
12:17:35 (UP) bitrate(128)[0] to bitrate(192)[1]                  ← 要 5 个周期才爬回 900
```

`(400)[4] → (900)[5]` 对应的正是补丁后的 48k 表：索引 4 = 400、索引 5 = 900。
**ABR 上限已从 400 kbps 抬到耳机宣告的 900 kbps**，且降档/上爬逻辑照常工作。
蓝牙进程 pid 稳定、无 SIGSEGV。

> 实测同时说明：**这条链路撑不住 900 kbps**（到达 900 后 0.4 秒即因队列积压降档），
> 所以稳态会在上下限之间摆动 —— 这是 ABR 应有的行为，不是补丁问题。
> 也正因如此，「按耳机宣告封顶、不做越权」是比强推 1 Mbps 更合理的选择。

**补丁 5–7（降档改成一格一格）落地后**：

```
12:54:08.435 (UP) bitrate(400)[4] to bitrate(900)[5]   ← 爬到顶格
12:54:08.675 (DN) bitrate(400)[4] to bitrate(400)      ← 降一档：900 → 400
12:54:08.755 (DN) bitrate(400)[4] to bitrate(320)      ← 再降一档：400 → 320
12:56:08.755 (UP) bitrate(320)[3] to bitrate(400)[4]   ← 一格一格往上爬
12:58:08.755 (UP) bitrate(400)[4] to bitrate(900)[5]
12:58:08.995 (DN) bitrate(400)[4] to bitrate(400)
12:58:09.075 (DN) bitrate(400)[4] to bitrate(320)
```

统计：进程 pid 稳定 16 分钟、`SIGSEGV` 计数 0、日志中 `to bitrate(128)` 出现 **0 次**
（此前每次降档都是它）。

**跳板迁到 PLT0 死槽后**（2026-09-26 13:55，即当前交付版本；宿主不再碰无损分支）：

内存比对是这一版最硬的证据 —— 把蓝牙进程里整段可执行区间（`0x4000`..`0x6960`，10592 字节）
dump 出来与磁盘上的原文件逐字比对，**只有 13 个字不同**，全部在设计内：

```
0x4f34  文件 b9400378 -> 内存 140005fc    站点 A → 跳板 A
0x50a0  文件 b903133f -> 内存 140005a7    站点 B → 跳板 B
0x6724 .. 0x674c  (11 个字) 12 字节零填充 + PLT0 槽 -> 两段跳板
```

同时确认：`0x50a8` 起的**无损提升实现逐字节与原文件相同**，`0x6750` 起第一个真实 PLT
表项未改动。

行为侧（同一连接的 ABR 决策日志）：

```
13:55:10.278 (UP) bitrate(400)[4] to bitrate(900)[5]   ← 爬到顶格
13:55:10.518 (DN) bitrate(400)[4] to bitrate(400)[0]   ← 降一档：900 → 400
13:55:10.598 (DN) bitrate(400)[4] to bitrate(320)[0]   ← 再降一档：400 → 320
13:56:10.598 (UP) bitrate(320)[3] to bitrate(400)[4]   ← 一格一格往上爬
13:57:10.598 (UP) bitrate(400)[4] to bitrate(900)[5]   ← 第二轮，形态相同
13:57:10.918 (DN) bitrate(400)[4] to bitrate(400)[0]
13:57:10.998 (DN) bitrate(400)[4] to bitrate(320)[0]
```

`to bitrate(128)` 出现 **0 次**；进程 pid 全程不变（2732），无 SIGSEGV。
（降档只到 320 就止住，是因为链路随即恢复 —— 降档触发频率没变，变的只是每次落差。）

> 日志读法：`bitrate(A)[i] to bitrate(B)` 中 A 是 `table[gABR_table_index]`、i 是该索引，
> B 是本次下发的目标码率。降档分支格式串里的第二个 `[%u]` 是**编译进代码的常量 0**
> （原落点索引），补丁 5–7 没有改它，所以那一格仍显示 0，属正常。
> 另外由于补丁 4 会把顶格的索引退一格，DN 行里 A 显示的是退格后的值（400[4]），
> 而当时实际码率是 900 —— 这一处日志字段因此不再精确，仅影响可读性。


#### 5.5.6 复现步骤

```bash
# 1) 确认补丁落地
adb shell su -c 'logcat -d -b all | grep LHDCV5A'
# 2) 确认上限 = 耳机宣告
adb shell su -c 'logcat -d -b all | grep lhdcv5BT_enc | grep "Update Max"'
# 3) 观察 ABR 爬升（需耳机已连接且有音频在播放，约 1 分钟一条）
adb shell su -c 'logcat -d -b all | grep -a ABR_ADJ'
```

注意 2 MiB 的 main 缓冲会在开机时把模块日志冲掉；要看模块日志需在**蓝牙进程重启后**
再看，或参考 §5.5.4。

**绕开日志缓冲的直接核对**（推荐，模块日志很容易被冲掉）：

```bash
P=$(adb shell pidof com.android.bluetooth)
# 取 liblhdcv5BT_enc.so 的 load bias：找 r-xp 且偏移 0x4000 的那行，bias = 起始地址 - 0x4000
adb shell su -c "grep lhdcv5BT_enc /proc/$P/maps"
# 设 B=<bias>，然后按 16 字节对齐窗口读（注意：toybox 的 dd 用 bs=1 + 大 skip 会读出全 0，
# 必须用 bs=16 且 skip=地址/16）
adb shell su -c "dd if=/proc/$P/mem bs=16 count=4 skip=$((B+0x6720))/16 2>/dev/null | od -An -tx1 -v"
#   期望 0x6724 起：e91b40b9 29050051 2905891a 785b69b8 a13300d1 01faff17 …
# 整段比对（最硬的证据）：dump 0x4000..0x6960 共 10592 字节与原文件逐字对比，
#   应只有 13 个字不同：0x4f34、0x50a0、0x6724..0x674c（见 §5.5.5）。
```

#### 5.5.7 把降档改成「一次只降一格」

**动机**：原实现把降档落点写死成 `table[0]`（表的最小格，48k 为 128 kbps）。从顶格 900
一次掉到 128 是 7 倍落差，且回爬要 5 个决策周期（实测每周期约 60 s），实听就是频繁的
「掉下去再慢慢爬」。

**两处硬编码**（都在 `lhdcv5BT_adjust_bitrate` 内）：

```
0x4f34  ldr w24, [x27]        ; 落点 = table[0]（索引常量 0 折进了地址偏移）
0x50a0  str wzr, [x25,#0x310] ; 然后把 gABR_table_index 写回 0
```

改成 `idx-1` 需要多几条指令，而该库 `.text` **没有任何空隙**（0x4000–0x6724 已逐字节扫描，
≥8 字节的 udf/nop 填充为 0），模块自身又远在 ±128 MB 之外（实测模块代码在
0x32727c3604，库在 0x71362d4000，相距约 250 GB，4 字节 `b` 够不着）。

**解法：把跳板写进该库自己的一段走不到的死代码里 —— 宿主取 `.text` 末尾的 12 字节对齐
填充 + PLT0 槽，`0x6724`..`0x6750` 共 44 字节连续可执行空间。**

该区间为死代码，四条独立证据：

- **该库是 `-z now` 构建**：`.dynamic` 里 `DT_FLAGS` 含 `DF_BIND_NOW`（`0x6ffffffb`/`DT_FLAGS_1`
  同时置了 `DF_1_NOW`），`.rela.plt` 的全部 33 条 `R_AARCH64_JUMP_SLOT` **addend 全为 0**、
  由加载器在装载时直接填入符号地址 —— 没有惰性绑定，GOT 槽永远不会指向 PLT0。
- **全可执行区间扫描**：没有任何 `b` / `bl` / `b.cond` 跳进 `0x6724`..`0x6750`。
- **`DT_RELR` 只重定位 `0x7000`..`0x7030`**（`.data.rel.ro` / `.fini_array` / `.dynamic`），
  不涉及 `.plt`。
- `0x6724` 起的 12 字节是 `.text`（结束于 `0x6724`）与 `.plt`（起始 `0x6730`）之间的
  **对齐填充，内容为全零**；`0x6730`..`0x6750` 是标准 PLT0 解析桩（5 条指令 + 3 条 `nop`）。

> **这一版刻意避开了无损模式。** 上一版把跳板放在 `0x50a8` 起的**无损提升分支**里
> （进入条件 `lossless==1 && 48kHz && 16bit && 码率恰好 400`，见 `0x4e9c`..`0x4ee0`），
> 虽然本机耳机 `lossless_on(0)` 走不到，但换成支持无损的耳机就会执行到非原逻辑上。
> 现在 PLT0 槽与业务代码毫无关系，`0x50a8` 起那段**一个字节都不用动**。
>
> 跳板与站点同在库内，全是短跳，**不需要任何绝对地址**，因此每个字都是编译期常量。

跳板内容（每个字都与二进制真值逐条核对过编码；`cinc` 的编码另与 `0x4dcc` 处既有的
`cinc w24,w8,lo` 比对确认）：

```
; 跳板 A @0x6724（站点 0x4f34 跳到这里）
ldr  w9,  [sp, #0x18]        ; 当前码率在 ABR 表里的档位（0x4f28 存进去的）
sub  w9,  w9, #1             ; 降一格
cinc w9,  w9, mi             ; 夹到 >= 0（档位为 0 时留在 table[0]，避免 [x27,-1] 越界读）
ldr  w24, [x27, w9, uxtw #2] ; w24 = table[tier-1]     ← 原来这里是 table[0]
sub  x1,  x29, #0xc          ; 补上被 b 覆盖掉的 0x4f38
b    0x4f3c                  ; 回到 mov w0,w24 → get_bitrate_inx

; 跳板 B @0x673c（站点 0x50a0 跳到这里）
ldr  w9,  [sp, #0x18]
sub  w9,  w9, #1
cinc w9,  w9, mi
str  w9,  [x25, #0x310]      ; gABR_table_index = tier-1，与落点保持一致
b    0x4c58
```

24 + 20 = 44 字节，恰好填满宿主，且终点正好是 `.plt` 的第一个真实表项（`0x6750`，未改动）。
站点处被覆盖的 `0x4f38` / `0x50a4` 不再被执行，字节原样保留。

用 `[sp,#0x18]`（而不是全局索引）是关键：它是**按当前实际码率在表里比较出来的档位**，
不受补丁 4 的「索引退格」影响，所以 `tier-1` 一定是当前档位的下一格。

写入顺序不能变（模块里的 `apply_abr_code_patches` 即按此实现）：
**先只读核对全部指纹 → 写跳板 → 最后才改站点**。反过来会出现「站点已指向尚未写入的
跳板」的窗口；而在认错构建的情况下写别人代码区更是不能接受。

**风险与代价**（明确记录）：

1. **无损模式不再受影响**：`0x50a8` 起的无损提升实现**逐字节未改**（已用内存比对确认）。
   换耳机、换设置都不会因为本补丁而崩。
2. 宿主是 PLT0 死槽，前提是**该库保持 `-z now` 构建**。若换成惰性绑定的构建，PLT0 就成了
   活代码，此时写入会破坏全部 PLT 调用。模块在写入前会核对这 44 字节的原始内容，
   不匹配就整体放弃降档改写（`.text` 两个站点也保持原样）。
3. 三个 `.text` 页会被 `mprotect` 到 `R|W|X` 再恢复 `R|X` —— 页全程可执行，
   没有崩溃窗口（§5.5.3 第 1 条）。
4. 降档的**触发频率**没变（仍是队列积压 4 个 tick 一次），变的只是**每次的落差**。
   本机链路撑不住 900，所以仍会看到连续两次降档（900→400→320），但不会再一步到底。

### 5.6 采样率保持：从「换掉分派依据」到「重放用户那次调用」

**需求**：用户在「设置 → 蓝牙 → 耳机 → 采样率」里改到 96 kHz 后，断开重连不会
被打回 48 kHz，而是保持用户选定的值。要求是**持久化用户设置**，不是锁死采样率。

> 5.6.1–5.6.6 记录早期几次失败与当时的推断（保留下来避免重走）；
> **5.6.7 是最终实现并通过设备验证的方案**，5.6.8 / 5.6.9 是弯路与低层坑的清单。

#### 5.6.1 实测证据（2026-09-26，耳机 Redmi Buds 5 Pro）

用户动作与结果，全部有日志：

```
15:20:06  D/MiuiHeadsetCodecSampleRateFragment: setCodec 8
15:20:06  D/MiuiHeadsetCodecSampleRateFragment: set LHDC SAMPLE_RATE_96000
15:20:06  I/bta_av_co.cc(2018) SetCodecUserConfig: codec_preference={codec: LHDC V5
              priority: 1000000 sample_rate: 96000 bits_per_sample: 16|24 ...}
15:20:06  I/a2dp_codec: setCodecUserConfig: Configured: config_updated = 1
15:20:06  D/RasterMill: lhdcv5_encoder_init: sampleRate = 96000, bitrate = 400 ...
15:20:06  I/codec_status_aidl.cc(653) A2dpLhdcv5ToHalConfig: sampleRate = 96000
15:20:06  D/MiuiHeadsetCodecSampleRateFragment: getSampleRate = 8      <- 页面刷新为 96k
```

**「设置」这一步是成功的**：native 接受、编码器与 HAL 同步切到 96000。

```
15:22:05  I/bta_av_co.cc(2618) SetCodecOtaConfig: codec: LHDC V5
15:22:05  I/bta_av_co.cc(2220) ReportSourceCodecState: codec_config={codec: LHDC V5
              priority: 8003 sample_rate: 48000 bits_per_sample: 24 ...}
15:22:05  D/RasterMill: lhdcv5_encoder_init: sampleRate = 48000, bitrate = 400 ...
```

**「重连」这一步丢失**：全程**没有任何一次 `SetCodecUserConfig`**；`priority` 从
`1000000`（`BTAV_A2DP_CODEC_PRIORITY_SELECTED`，用户选择标记）退回 `8003`
（LHDC V5 默认优先级）。

#### 5.6.2 根因

AOSP 里「用户 codec 偏好」的持久化与重连恢复靠 `A2dpService.updateDeveloperPreferences()`
—— 它把偏好写进 `Settings.Secure`，设备重连时读回来重新下发。**本 ROM 的
`A2dpService` 没有这个方法**（`libbluetooth_jni.so` 的 dex 全量反汇编中不存在该符号，
且该类对 `Settings` 的所有读写都是白名单 / 音量 / 多设备音频，**没有一处与 codec 配置有关**）。
旁证三条，互相印证：

- `Settings.Secure` / `Settings.Global` 中没有任何采样率相关的键；
- `/data/misc/bluedroid/bt_config.conf` 里只记了 `Codecs = SBC,AAC,LHDC V5,LHDC_V3`，无采样率；
- MIUI 自己的采样率页面只从**当前会话**读值显示选中项，从不保存。

**所以用户的选择只活在当前 A2DP 会话的内存里，一断连就归零。这不是某个开关没打开，
是整块机制被省掉了。**

#### 5.6.3 尝试一：读 `mCodecUserConfig.sample_rate`（失败）

**方案**：在 `A2dpCodecConfigLhdcV5Base::setCodecConfig`（库内 `0x7992e0`）里改道
`0x799670`（`str wzr, [x20, #0x60]`），把 `w9`（此时由 `0x799668`
`ldr w9, [x20, #0x140]` 载入，即 `mCodecUserConfig.sample_rate`）写回
`mCodecConfig.sample_rate`（对象 `+0x60`）。

**结果**：补丁本身确认落地（内存比对：站点 `0x799670` 由 `b900629f` 变为 `141e927c`，
PLT0 跳板 5 条指令读回一致），但重连后仍为 48000。

**失败原因**：`mCodecUserConfig.sample_rate` 在重连时**已被 ROM 重置为协商结果**
（48000），补丁读到的是污染后的值。用户实测复现：先设 96 kHz 再重连，仍回 48 kHz。

#### 5.6.4 尝试二：沿用「上一次生效的值」（失败，且导致采样率被锁死）

**方案**：不再读 `mCodecUserConfig`，改用 `mCodecConfig.sample_rate`（`+0x60`）**清零前**
的旧值 —— 它按道理就是上一次生效的采样率，即用户上次设定值。跳板：

```
ldr  w10, [x20, #0x60]     ; 上一次生效的采样率
cbz  w10, +0x0C            ; 为 0 则跳过
mov  w9,  w10              ; 用它当分派索引
str  w9,  [x20, #0x60]     ; 写回（等价于不清零）
b    0x799674              ; 继续原 switch
```

**结果**：重连仍回 48000，**且用户再也改不动采样率**（表现为"锁定"）。

**失败原因（两层，都致命）**：

1. **锁死的直接原因**：`0x799670` 之后紧跟 `cmp w9, #0x40` + 跳转表 `br x11`，
   这段代码**本来就是按 `w9` 分派**的。跳板用旧值覆盖了 `w9`，就**压过了
   `mCodecUserConfig` 里用户新选的值** —— 用户改成别的采样率会被弹回旧值。
2. **无效的原因**：`mCodecConfig.sample_rate` 在重连时同样已被重置为 48000，
   所谓"旧值"并不是用户设定值。

**跳转表已解出**（`.rodata` `0x2c3ee0`，索引 = `btav_a2dp_codec_sample_rate_t` 位图）：

| `w9` | 落点 | 行为 |
|---|---|---|
| `0x0` / `0x4` / `0x10` / `0x40` | `0x799694` | 不设 `+0x60`（只清 `+0x98` 能力位） |
| `0x1` (44100) | `0x7997e8` | 查对端能力位后设 44100 |
| `0x2` (48000) | `0x7997d4` | 查对端能力位后设 48000 |
| `0x8` (96000) | `0x799804` | 查对端能力位后设 96000 |
| `0x20` (192000) | `0x799824` | 查对端能力位后设 192000 |
| 其余 | `0x799698` | 按对端能力位从高到低选 |

即：这段代码**已经**实现了「用户选择 ∩ 对端能力」，它缺的只是「用户选择跨重连存活」。

#### 5.6.5 附带确认的技术事实

- `libbluetooth_jni.so` **有完整导出符号表**（18253 项），无需签名扫描即可精确定位：
  `BtaAvCo::SetCodecUserConfig` `0x6969d0`、`BtaAvCo::SetCodecOtaConfig` `0x694a40`、
  `A2dpCodecConfig::setCodecUserConfig` `0x764b20`、`getCodecUserConfig` `0x764980`、
  `getCodecConfig` `0x764800`、`A2dpCodecConfigLhdcV5Base::setCodecConfig` `0x7992e0`。
- `A2dpCodecConfig` 对象布局：`mCodecConfig` 在 `+0x58`、`mCodecUserConfig` 在 `+0x138`，
  两者都是 56 字节，`sample_rate` 在各自结构内 `+0x08`。
- 该库同样是 `-z now`（`DT_FLAGS=0x8`、`DT_FLAGS_1=0x1`，`.rela.plt` 全部 9727 项
  addend 为 0），`.plt` PLT0（`0xf3e060`，32 字节含 3 个 nop）**无任何分支引用**
  （全库 404875 条 `b`/`bl`/`b.cond` 扫描确认），可作跳板宿主。
- `.text` 内**没有 >= 24 字节的填充空洞**；库内 `0xf64070..0xf65000` 有 3984 字节
  **未映射**间隙（可考虑 `mmap` 作扩展代码区，未验证 SELinux 是否放行）。

#### 5.6.6 若要继续，可选路线（写于最终实现之前，历史记录）

- **A. Xposed 模块（推荐）**：设备已装 Vector 框架。Hook MIUI 的
  `MiuiHeadsetCodecSampleRateFragment` —— 点选时把值存进 SharedPreferences，
  A2DP 连上后自动调用它自己的 `setCodecInfo(保存值)` 重新下发。**走的是用户手动点选
  已验证有效的那条路径，不碰 stripped native 库**，风险最低。
- **B. Zygisk 持久化**：`mmap` 库内 3984 字节间隙作代码区 → hook
  `BtaAvCo::SetCodecUserConfig` 捕获用户选择并落盘 → hook `SetCodecOtaConfig`
  在协商后重新调用 `SetCodecUserConfig`。技术上可行，但要在 stripped 库里做两个
  inline hook 加文件 IO，工作量大、崩溃风险高。
- **C. 维持现状**：采样率每次重连后手动设一次。

**回退**：两次尝试的代码均已从 `module/lhdcv5-real/zygisk-src/module.cpp` 撤销，
`.so` 的 md5 恢复为 `4b75699072f39a17b6e7f0d36703d0df`（仅含 ABR 降档补丁）。
设备已重启，站点 `0x799670` 经内存比对确认恢复为原指令 `b900629f`。

#### 5.6.7 最终实现：捕获用户那次调用，连接建立后重放（已实现并通过设备验证）

**一句话**：本模块记住用户点选采样率时**原生实际收到的那次调用**，在耳机连接建立后
把它**原样重放**，并盯着「实际生效值」重试到生效为止。

**为什么是这个形态**：用户手动点选是设备上**唯一**被验证过能改到采样率的入口
（`bta_av_co_set_codec_user_config` → `BtaAvCo::SetCodecUserConfig`）。
既然那条路走得通，就不要另造一条 —— 把同一次调用在正确的时机重放一遍即可。
AOSP 的 `updateDeveloperPreferences()` 做的也是这件事（连接状态变化时重新下发偏好），
只是它通过 `Settings.Secure` 落盘、由 Java 层驱动。

**捕获**：`bta_av_co_set_codec_user_config` 的 GOT 槽 `0xf942d8` 重定向到模块。
该符号全库只有一处调用者 —— `btif_a2dp_source_encoder_user_config_update_event`
（源文件 `btif_a2dp_source.cc`），其 config 向量来自 Java `BluetoothA2dp.setCodecConfigPreference`，
确实是用户偏好而非能力表。**只在返回 true 时**记下那次调用用的**完整 56 字节配置**
（编解码器类型/优先级、采样率、位深、声道模式、四个 codec_specific 都在里面，
重放时必须原样送回，只记采样率是不够的）。

**重放**：`BtaAvCo::ProcessOpen`（GOT `0xf941f8`）是 AVDTP 流打开、对端状态
已经落地的时刻。该函数第二个参数直接就是 `RawAddress const&`，所以不必去猜
`BtaAvCoPeer` 的字段偏移。连接建立后用它调一次同一个入口。

**为什么要重试 —— 两条实测到的拒绝**：连接刚建立时原生会把重放拒掉，两次拒绝
都在设备上抓到了原文：

```
E bta_av_co.cc(2054) SetCodecUserConfig: peer … : cannot find peer SEP to configure for codec type 12
W bta_av_co.cc(2039) SetCodecUserConfig: peer … : not all peer's capabilities have been retrieved
```

第一条对应 `FindPeerSink()` 里读 `peer->num_sinks == 0`（sink 表还没建），
第二条是「对端能力还没取全」。**用户手动点选之所以有效，只是因为那时候早就齐了。**
与其继续猜「哪个时点才算够晚」（已经猜错过两次），不如做成闭环。

**闭环怎么闭**：新增第三个 GOT 钩子包住
`A2dpCodecs::getCodecConfigAndCapabilities`（GOT `0xf95a28`）—— 它的第 1 个参数
就是当前配置的出参（`btav_a2dp_codec_config_t*`，实测调用点 `0x6927cc` 处
`add x1, sp, #0x68`），于是模块有了一个**可靠的「实际生效采样率」读数**。
然后由频繁出现的属性读取驱动：

```
读数 == 期望  → 收手（本次连接不再尝试）
读数 != 期望  → 重放一次，最多 12 次、两次之间至少隔 1 秒
```

失败的重放是空操作，成功的那次会经 `BTA_AvReconfig` 触发一次 AVDTP RECONFIGURE，
所以「生效即停」既不会多触发也不会漏。三个钩子之外，**本模块不改任何一条指令**。

**节奏由属性读取驱动，不是"1 秒一次"**：`sr_tick()` 只挂在 `osi_property_get` 上，
所以「至少隔 1 秒」是**下限**而非周期 —— 进程不读属性就不会重放。实测三次断连重连的
首次重放间隔分别是 **1.0 / 10.3 / 30.5 秒**（见下表），也就是说耳机连上后，前十几到
几十秒听到的仍是 48 kHz，之后编码器才中途重启到目标采样率。功能不受影响（三次全在
2 次尝试内生效，12 次预算绰绰有余），但**别按「1 秒一次」估时间**。

**设备验证**（xaga，LHDC V5，Redmi Buds 5 Pro）：

```
12:44:47  连接建立，准备重放用户偏好（期望 0x8，当前实际 0x2）
12:44:47  第 1/12 次重放：期望 0x8，返回 1（实际仍为 0x2，restart=0）   ← 能力未就绪，被拒
12:44:48  第 2/12 次重放：期望 0x8，返回 1（实际仍为 0x2，restart=1）
12:44:48  采样率已生效（实际 = 期望 = 0x8）—— 重放结束，共试 2 次
12:45:02  期望 0x20 的两次断开重连同样在 2 次内生效
```

有完整时间戳的三次断连重连（后两次为 2026-09-27 复测，同一副耳机）：

| 存的偏好 | 重连后起始值 | 编码器初始化 | 首次重放间隔 | 结果 |
|---|---|---|---|---|
| 0x8（96 kHz，上面这段日志） | 0x2 | —（当时未记） | **1.0 秒** | 2 次内生效 |
| 0x20（192 kHz） | 0x2 | 48000 → **192000** | **10.3 秒** | 2 次内生效 |
| 0x8（96 kHz） | 0x2 | 48000 → **96000** | **30.5 秒** | 2 次内生效 |

「编码器初始化」那列是最硬的一层证据 —— 采样率确实传到了 LHDC 编码器，不是只改了
某个字段：`mCodecConfig` 里的读数是「已生效」，而编码器初始化是「已使用」。

```
mCodecConfig: {codecName:LHDC V5, mCodecPriority:1000000, mSampleRate:0x20(192000), …}
lhdcv5_encoder_init: Init Encoder sampleRate = 192000, bit per sample = 24, Block size=960
```

**两个边界**：

- 只对**同一副耳机**的 MAC 重放；换了对端什么都不做，避免把 A 的设置塞给 B。
- 偏好文件格式是 `<MAC> <56 字节 hex>`；**升级自老格式后需要在设置里重新选一次
  采样率**以记录偏好（老格式一律忽略，当作没有偏好）。

#### 5.6.8 走过的两条弯路（务必不要再试）

**弯路一：换掉 `0x799668` 的分派依据（曾以为这是正解，实测无效）**

`A2dpCodecConfigLhdcV5Base::setCodecConfig` 里 0x799668 是
`ldr w9, [x20, #0x140]`（取 `mCodecUserConfig.sample_rate`），随后按 `w9`
索引 `.rodata 0x2c3ee0` 的跳转表分派。看起来「只要把来源换成持久化值就行」。

**实测无效，原因是这张表是死代码**：四个分支后面各有一道能力位校验
`tbz/tbnz w24, #N`，而 `w24` 恒为 0 —— 它来自 `and w24, [sp+0x1c1], [x28+6]`，
而 `[sp+0x1c1]` 在函数序言里被 `stp xzr,xzr,[sp,#0x1b8]` 清零后，全函数 8560 字节
再无任何写入。于是四个分支永远全部落到 `0x799698` 的兜底。

决定采样率的是 `0x7996c8 ldr w8, [x20, #0x178]` 索引的另一张表
（`.rodata 0x2c3f21`，索引 = `sample_rate - 1`），而 `+0x178` 是对象 `+0x170`
那个结构的 `sample_rate` —— **正是 `A2dpCodecConfig::setCodecUserConfig` 写进去的
那份数据**，也就是「用户手动点选」才会写的东西。

**结论：唯一可控的输入就是重放用户那次调用本身，改分派索引是白费力气。**

**弯路二：把重放挂在「协商完成」的时点上**

先后试过挂在 `BtaAvCo::SetCodecOtaConfig` 之后、再挂到 `BtaAvCo::ProcessOpen` 之后，
都不行 —— 就是 5.6.7 里那两条拒绝。教训是：**不要猜时点，做成闭环。**

**弯路三（更早，见 5.6.3/5.6.4）**：读 `mCodecUserConfig` / 沿用旧值。这两次失败
当时的归因（「字段被 ROM 重置」）其实只是表象；原因是上面那条「那张表是死代码」。

#### 5.6.9 实现过程中踩到的三个低层坑（都已在设备上复现过）

1. **跳板里不能有 store。** 曾用 `.plt` 的 PLT0 死槽做跳板并在里面放计数器自增，
   `patch_text` 写完会把页恢复成 `R|X`，那条 `str` 立刻吃 `SEGV_ACCERR`
   （fault addr = 宿主 +0x18，pc = 宿主 +0x0c），把协议栈打进崩溃循环，
   表现是编码器列表只剩 SBC。**代码页只能读。**
2. **改跳板里的字面量要补上宿主偏移。** `sr_write_word(off)` 当时算的是
   `bias + off`，而传进去的 `off` 是相对跳板的，于是写到了 `bias + 0x18`
   （ELF 头的 `e_entry`）；回读校验读的正是刚写进去的那 4 字节，所以每次都回报成功，
   唯独跳板那一格纹丝不动 —— 用户改成 192/48/44.1 全无效，又被误判成「锁死」。
3. **Zygisk 会缓存模块 .so。** 替换 `/data/adb/modules/*/zygisk/*.so` 后只重启
   `com.android.bluetooth` 不够，跑起来的仍是旧代码（日志里还是旧字符串）；
   必须**整机重启**让 Zygisk 重新读取。这一点与「加载时机」那节（5.7）是两回事。

## 6. 复现与验证

### 6.1 安装

```bash
adb push module/lhdcv5-real.tar.gz /data/local/tmp/   # 或直接推目录
adb shell su -c 'cp -a /data/local/tmp/lhdcv5-real /data/adb/modules/'
adb shell su -c 'chmod 0755 /data/adb/modules/lhdcv5-real/post-fs-data.sh \n                          /data/adb/modules/lhdcv5-real/uninstall.sh'
adb reboot
```

### 6.2 验证清单

```bash
# 1) 模块日志（应显示 4 项挂载成功）
adb shell su -c 'cat /data/local/tmp/lhdcv5-aidl.log'

# 2) AIDL 服务已注册
adb shell su -c 'service list | grep bluetooth.audio'

# 3) 协议栈走 AIDL（而非 hidl）
adb shell su -c 'logcat -d | grep -oE "client_interface_aidl|client_interface_hidl" | tail -1'

# 4) 编解码器 = LHDC V5，采样率 = 192000
adb shell su -c 'dumpsys bluetooth_manager | grep -oE "mCodecConfig: \{[^}]*\}" | head -1'

# 5) PCM 速率实测（两次采样，用设备侧时钟计时）
adb shell su -c 'dumpsys bluetooth_manager | grep "PCM read bytes" | head -1; cut -d" " -f1 /proc/uptime'
#    间隔 20-25 秒再采一次；差值 / 时间差 ≈ 1,152,000 B/s 即为 192kHz×24bit×立体声

# 6) /vendor 未被修改
#    注意：模块生效时这个路径被 bind mount 顶替，读到的是载荷里的 shim，不是出厂原件。
#    两个值都要认得出来，才不会误判：
adb shell su -c 'sha256sum /vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so'
#    模块生效时：abad71d02d4fcf4271a6f8f5104a403d79c1f8021e6f2414ac6fe31676205890  (= payload/shim.so)
#    卸载重启后：8a26665956b391d4e815aae1173cc3388e418e65227e88c112eb310654511fa2  (= 出厂原件 hal22.so)
#    /vendor 是 erofs 只读，磁盘内容不可能被改；所以「卸后 sha256 等于出厂」这条
#    **恒成立，不能当作回退成功的证据**（见 §6.3）。

# 7) 采样率偏好跨重连保持（§5.6）
#    先在设置里选一次采样率（例如 192 kHz）让它被记录，然后断开耳机再重连；日志应出现
#    「连接建立，准备重放用户偏好」与「采样率已生效（实际 = 期望 = 0x20）」
adb shell su -c 'logcat -d -b main | grep LHDCV5A | grep -E "重放|已生效" | tail -5'
#    偏好落在 /data/misc/bluedroid/lhdcv5_sr.conf，一行 "<对端 MAC> <56 字节配置的 hex>"
#    注意：升级自老格式后需要在设置里重新选一次采样率，老格式一律忽略
```

### 6.3 回退

#### 6.3.1 完整卸载

模块自带 `uninstall.sh`。KernelSU 在「移除模块」后的**下次开机**、post-fs-data 阶段
以 root 执行它（cwd = 模块目录），**随后**才 `remove_dir_all` 删掉模块目录。
那一次开机模块已不再加载，所以 `post-fs-data.sh` 不会运行 —— 也就是说，
模块写在**模块目录之外**的一切都由这个脚本负责。

```bash
adb shell su -c 'ksud module uninstall lhdcv5-real'   # 或在 KSU 管理器里点移除
adb reboot
```

`uninstall.sh` 只清**本模块自己的产物**，共两件事（日志只进 logcat，**不落盘**）：

1. **删除** `persist.bluetooth.a2dp_offload.disabled` —— 用
   `ksud resetprop -p -d`（真删）。**不能用 `setprop … ""`**：那只会持久化一个空值条目。
2. 删除本模块的落地产物与中间文件：`/data/vendor/lhdcv5/`（2.2 MB）、
   `/data/misc/bluedroid/lhdcv5_sr.conf`（采样率偏好，回退路径
   `/data/local/tmp/lhdcv5_sr.conf` 一并删）、`/data/local/tmp/ld.new`、
   `/data/local/tmp/lhdcv5-aidl.log`。

本项目历史上手工推入 `/data/local/tmp` 的临时文件（安装包、调试 dump 等）**不属于模块
产物**，脚本刻意不碰，需要时由使用者在模块外自行处置。

#### 6.3.2 只停用（不清理）

```bash
adb shell su -c 'touch /data/adb/modules/lhdcv5-real/disable && reboot'
```

模块不再加载，但**什么都不清**：offload 属性、`/data/vendor/lhdcv5/`、采样率偏好文件都还在。

#### 6.3.3 手工回退

```bash
adb shell su -c 'rm -rf /data/adb/modules/lhdcv5-real'
adb shell su -c 'ksud resetprop -p -d persist.bluetooth.a2dp_offload.disabled'
adb shell su -c 'rm -rf /data/vendor/lhdcv5 /data/misc/bluedroid/lhdcv5_sr.conf \
                        /data/local/tmp/lhdcv5_sr.conf /data/local/tmp/ld.new \
                        /data/local/tmp/lhdcv5-aidl.log'
```

#### 6.3.4 什么会自己消失、什么不会（实测）

**重启即自愈，无需处理**：

| 东西 | 为什么 |
|---|---|
| `/vendor` 下被 bind 顶替的 4 个文件 | bind mount 只在内存里；`/vendor` 是 erofs 只读，模块从未写过它 |
| `/linkerconfig/ld.config.txt` 的两行补丁 | `/linkerconfig` 是 tmpfs（`mount` 可证），每次开机由系统重建 |
| Zygisk 的内存补丁 | 随进程消失 |

**不重启就什么都不算**：补丁、bind mount、属性全都还在，模块"看起来还在工作"。

**必须手动清**：`persist.bluetooth.a2dp_offload.disabled=true`
（落在 `/data/property/persistent_properties`，与模块目录无关）、上面第 2 条列的那些文件。

**不消失但无害**：`bt_config.conf` 里 `Codecs` 列表中的 `LHDC V5`（下次 BT 启动会重写）。

`uninstall.sh` 刻意不写任何文件 —— 它的日志只进 logcat（`adb logcat -d -s LHDCV5U`），
所以卸载完成后本模块在磁盘上**零残留**。

#### 6.3.5 判据

```bash
adb shell 'mount | grep -c vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio'  # 期望 0
adb shell su -c '/data/adb/ksud resetprop -P persist.bluetooth.a2dp_offload.disabled'  # 期望 "not found"
#   别用 getprop 判空：属性被真删 与 被设成空值，读回来都是空串，分不出来
adb shell su -c 'ls /data/vendor/lhdcv5'                                             # 期望 No such file
```

**唯一说明"准入补丁已失效"的判据需要耳机连着**：重启后
`dumpsys bluetooth_manager` 的 `mCodecsLocalCapabilities` 里不应再出现 LHDC V5。
（`codecConfigPriorities` 里的 `LHDC V5: 8003` 是 ROM 自带的静态表，一直在，不能当判据。）

**「`/vendor` 原件 sha256 不变」不是有效验证**：`/vendor` 只读，该值恒等于出厂值。

---

## 7. 致谢与来源

- **AIDL 实现 / 音频 HAL 模块 / AIDL session 库**：取自 **Redmi Note 14 Pro（malachite）**
  线刷包 `OS1.0.13.0.UOOCNXM`。选它的原因是其 AOSP-AIDL 集群基于接口 **v3**，
  与本机协议栈（同样链 `android.hardware.bluetooth.audio-V3-ndk.so`）匹配；
  而 zircon/corot 的同类库基于 **v2**，本机平台不提供 v2，无法使用。
- **白名单机型映射**：`MiCode/MTK_kernel_modules` README 分支表 —— 确认白名单 5 个机型
  （corot/zircon/duchamp/rothko/malachite）**全部是联发科平台**，与 xaga 同属一个
  `vendor.mediatek.hardware.bluetooth.audio` 接口族，这是移植可行的前提。
- **LHDC 编解码器源码与研究资料**：`sprlightning/liblhdc-collections`、
  `DBeidachazi/liblhdcv5`、`TheXPerienceProject/android_vendor_savitech_lhdc`。

---

## 8. 方法论备忘

本次实现中值得记录的判断失误与教训：

| 失误 | 原因 | 教训 |
|---|---|---|
| 误判"移植大概率不能解锁 192kHz" | 只看了 AOSP 版 session 库（不含 192k），漏了 MTK 版 | **同一接口的两个实现可能有不同能力**，必须逐个查 |
| 误判"卡开机是 ld.config 补丁内容有问题" | 未区分内容与 inode | 运行中批量重启 8 个服务全通过，证明内容无害 —— **要设计能区分变量的实验** |
| 误判"Zygisk 部分可能不必要" | 因为看不到模块的 maps 与日志 | Zygisk 会隐藏模块映射；**功能表现才是判据**，用"移走后再看"来验证 |
| 一次性启用全部改动做开机测试 | 未做隔离 | **开机级改动必须逐项、逐次重启验证** |
| 误报"码率 900 kbps" | 把 `dumpsys` 的能力上限当成当前值 | 能力字段 ≠ 生效值，要交叉验证编码器侧日志 |
