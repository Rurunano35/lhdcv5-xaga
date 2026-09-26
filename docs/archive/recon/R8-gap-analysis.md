# R8 — "V5 通路"的语义边界 + 当前伪装（V5→V3）的实质缺陷清单

> 取证对象：`d:/Cache/Hyperos/xaga-lhdcv5/artifacts/libs/`（设备侧同名文件 SHA256 已由 R3 逐一对撞）
> 设备：Redmi Note 11T Pro (xaga / MT6895) / HyperOS `OS2.0.12.0.ULOCNXM` / Android 14 / KernelSU
> 方法：capstone 5.0.7 + pyelftools 离线反汇编 + `adb shell` 只读读取 + 既有日志复核
> 新脚本：`analysis/scripts/r8_dis.py`（带 adrp 字符串解析 + PLT 符号解析）、`analysis/scripts/r8_calls.py`（PLT 调用点反查）
> **本任务全程只读**：未修改设备任何状态；未安装/启用模块（实测 `lhdcv5` 模块当前处于 `disable` 状态）
>
> 地址约定：`libbluetooth_jni.so` 的 `.text/.rodata/.plt/.got/.got.plt` 满足 `sh_addr == sh_offset`，**VA 即文件偏移**。
> 其余厂商 `.so` 亦满足（R3 已核）。

---

## 0. 结论速览（一句话版）

| 问题 | 结论 |
|---|---|
| (丙) "让 HAL 原生携带 V5 信息"有实际收益吗？ | **没有**。软件编码通路上，HAL 只消费 `pcmConfig` 的三个字段，编解码器配置（无论 V3 的 `lhdcConfig` 还是 V5 的 `Lhdcv5Configuration`）**从不参与任何判定**。已用三层独立证据验证 |
| 那"V5"到底有什么可做的？ | 只有 **两项**：(丁-1) **低延迟控制面**（HIDL 通路完全缺失，已定位到具体 no-op 分支）；(丁-2) **摆脱硬编码偏移**（稳定性） |
| 伪装造成了音质/功能损失吗？ | **没有**。采样率/位深/声道/码率/AR/JAS/lossless/META 全部在 stack+encoder 层，与 P1/P2 无关 |
| 192 kHz 是伪装造成的吗？ | **不是**。三道闸门全部在 HAL/策略侧；栈侧（含 V3 转换函数）**允许 0x20 原样透传**，且 A2DP 层**实测已协商成功过 192000** |
| 附录 D 的两条"未走通"方向 | ① 已在当前实现中走通，当时判断基于一个**错误前提**（"HAL LHDC 上限 88200"不存在）；② 方向本身可行，只是被误判为"无意义" |
| 当前实现最大的真实风险 | **可维护性**：4 个硬编码文件偏移 + 3 个 GOT 槽偏移，APEX 一升级即整体失效（有身份校验兜底，不会变砖） |

---

## 1. 取证环境与复现命令

```bash
export PATH="/d/Tools/Anaconda3/envs/py3123:/d/Tools/Anaconda3/envs/py3123/Scripts:$PATH"
export PYTHONPATH="d:/Cache/Hyperos/pylibs"
export MSYS_NO_PATHCONV=1
cd d:/Cache/Hyperos/lhdcv5-tr/analysis/scripts

python r8_dis.py 82a8b0 2e0        # A2dpLhdcV3ToHalConfig 全文（含 PLT 符号 + 字符串）
python r8_dis.py 825ae0 3d8        # MTK HIDL a2dp::setup_codec
python r8_dis.py 837d80 140        # MTK AIDL a2dp::setup_codec（PCM 分支）
python r8_dis.py 829ac0 3c         # MTK HIDL A2dpCodecToHalSampleRate
python r8_dis.py 8253b0 6c         # set_audio_low_latency_mode_allowed（分发器）
python r8_calls.py 0x825ec0        # a2dp_get_selected_hal_codec_config 的调用者
python r3/r3_dis.py <so> <addr> +<len>   # 任意厂商 .so 反汇编
```

设备侧（只读）：
```bash
adb shell getprop | grep -i lhdc          # 全部未设置
adb shell su -c 'ls -la /data/adb/modules/lhdcv5/'
adb shell su -c 'dumpsys bluetooth_manager | grep -i -E "offload|codecName"'
```

---

## 2. 任务 1 — "实现 LHDC V5 路径"的四种语义界定

### 2.1 四种含义

| # | 含义 | 判据 | 当前状态 |
|---|---|---|---|
| **甲** | **语义/协议层**：与耳机在 AVDTP 上协商出 LHDC V5 的 SEP（V5 的 CIE 结构、V5 的特性位交换） | `dumpsys` 里 `mCodecConfig` 的 `codecName = "LHDC V5"`、`mCodecType = 12`、`mCodecSpecific*` 为 V5 的编码 | **已达成** |
| **乙** | **编码器层**：实际调用 V5 编码器（`liblhdcv5BT_enc.so` / `LHDC_V5-5.0.5`）产出码流 | `lhdcv5_encoder_new` / `lhdcv5BT_init_encoder: success!` + PCM 速率实测 | **已达成** |
| **丙** | **HAL 接口层**：送到音频 HAL 的配置结构**原生**是 V5 结构（`Lhdcv5Configuration`），不做 12→10 改写 | 栈侧存在 HIDL 版 `A2dpLhdcv5ToHalConfig`，或 HAL 侧出现 `Lhdcv5Configuration` | **未达成，且达成后也无收益（见 §2.3）** |
| **丁** | **其他**（本任务发掘，共 3 项） | | |
| 丁-1 | **低延迟（LL）控制面**：框架↔HAL 之间"允许低延迟 / 切换延迟模式"的协议 | 栈侧 `set_audio_low_latency_mode_allowed` 在 HIDL transport 下是否下发 | **HIDL 下是 no-op（已验证，见 §3.3）** |
| 丁-2 | **摆脱对硬编码偏移的依赖**：不依赖具体 APEX 构建的字节偏移 | 是否存在符号/特征定位而非固定偏移 | **未达成（见 §3.8）** |
| 丁-3 | **192 kHz** | 端到端 192 kHz PCM 通路 | **未达成，但与伪装无关（见 §3.6）** |

### 2.2 决定性证据：软件编码模式下 HAL 收不到 codecConfig

这一条是判定的基石，本次**独立复核并加固**。MTK HIDL `setup_codec` @`0x825ae0` 全文：

```asm
0x825b30  add   x0, sp, #0x30                    ; 栈上 CodecConfiguration
0x825b34  bl    #0x825ec0                        ; a2dp_get_selected_hal_codec_config(&cfg)
0x825b38  tbz   w0, #0, #0x825c1c                ; ★ 返回 false → ERROR "Failed to get CodecConfiguration" + 直接 return
0x825b3c  add   x0, sp, #0x30
0x825b40  bl    IsCodecOffloadingEnabled(&cfg)   ; ★ codec_config 的【唯一】消费者
0x825b48  tbz   w0, #0, #0x825c80                ; 未启用卸载 → ...
...
0x825d0c  ldr   x8, [x23, #0xde8]                ; active_hal_interface
0x825d10  ldr   x8, [x8, #0x90]                  ; GetTransportInstance()
0x825d14  ldrb  w8, [x8, #8]                     ; session_type
0x825d18  cmp   w8, #2                           ; == A2DP_HARDWARE_OFFLOAD_DATAPATH ?
0x825d1c  b.ne  #0x825d48                        ; ★ 本机恒走这条（软件编码）
0x825d20  ... codecConfig(codec_config) + UpdateAudioConfig   ; ← 只有卸载通路才把 codec_config 送给 HAL
0x825d48  ; ---- PCM 分支 ----
0x825d4c  bl    bta_av_get_a2dp_current_codec()
0x825d68  bl    A2dpCodecConfig::getCodecConfig()      ; ★ 重新取一份，与上面的 codec_config 无关
0x825d70  bl    A2dpCodecToHalSampleRate(&cfg)   → w21
0x825d80  bl    A2dpCodecToHalBitsPerSample(&cfg) → w20
0x825d90  bl    A2dpCodecToHalChannelMode(&cfg)
0x825d94  ldrb  w8, [sp, #0x70]                  ; cfg + 0x20 = codec_specific_2 低字节
0x825d9c  and   w8, w8, #1
0x825da0  strb  w8, [sp, #0xe]                   ; pcmConfig.isLowLatencyEnabled = codec_specific_2 & 1
0x825dc0  bl    AudioConfiguration::pcmConfig(&pcm)
0x825d2c  bl    BluetoothAudioClientInterface::UpdateAudioConfig(...)
```

**结论（已验证）**：
1. `a2dp_get_selected_hal_codec_config()` 的**返回值（bool）是必需的** —— 返回 false 会让 `setup_codec` 提前 return，PCM 通路根本不会建立。这正是**没有 P1/P2 时无声**的机制（与 MAIN-findings §5 的修正一致）。
2. 但它的**内容（结构体）** 只被 `IsCodecOffloadingEnabled()` 消费；卸载通路上才 `codecConfig(...)` 送给 HAL。
3. 送给 HAL 的 PCM 参数来自**另一次** `getCodecConfig()`（`0x825d68`），与 P2 的改写窗口**不重叠**（P2 的 TLS 标志只在 `A2dpLhdcV3ToHalConfig` 在栈上时置位）。

### 2.3 为什么 (丙) 没有收益 —— 三层证据

| 层 | 证据 | 结论 |
|---|---|---|
| **栈** | HIDL 命名空间下 `*ToHalConfig` 只有 6 个（SBC/AAC/aptX/LDAC/LHDC V2/LHDC V3），**零个含 V5**（R2 §2.5 否定证据 + 本次复核 `A2dpLhdcV3ToHalConfig` 的 `str w8,#0x20`） | HIDL 侧 V2/V3 被压成同一个 `CodecType = 0x20`，**即使写出 HIDL 版 V5 转换函数，结构与 V3 逐字节同构** |
| **接口** | MTK HIDL `CodecSpecific` 只有 `lhdcConfig`，类型 `LhdcParameters` = **8 字节 / 5 字段**（本次修正，见 §3.7） | 物理上装不下 V5 的 11 标量 + byte[] |
| **HAL** | `lhdcConfig()` 在 `hal22.so` / `libbluetooth_audio_session_mediatek.so` 中共 7 处调用点，**7/7 都在 `".lhdcConfig = "` 调试字符串拼接里**（R3 §4.1，本次以字符串计数复核：`hal22.so` 中 `lhdcConfig` 出现 2 次，全部为 toString/符号名）；`audio.bluetooth.default.so` 中 **"lhdc" 字符串计数 = 0** | HAL 对 `lhdcConfig` 的**唯一**用途是打日志 |

> **判定：(丙) 在本机型上是伪需求。** "伪装 V3" 与 "原生 V5" 在 HAL 侧产生的字节（`codecType=0x20` + 8 字节 `lhdcConfig`）**逐字节等价**。

### 2.4 有实际收益的是哪一项

**只有 丁-1（LL 控制面）与 丁-2（稳定性）**。丁-3（192 kHz）虽是需求，但**不是通过"V5 化"实现的**，而是需要改 HAL 会话库 + 音频策略（见 §3.6）。

---

## 3. 任务 2 — 伪装的实质缺陷（逐项验证 / 排除）

### 3.1 候选：V3 转换函数是否钳位采样率/位深/声道？ → **排除（无钳位）**

`A2dpLhdcV3ToHalConfig` @`0x82a8b0`（736 B）本次全文反汇编。校验与写入逻辑：

```asm
0x82a8f8  bl   A2dpCodecConfig::getCodecConfig()      ; 返回 56 字节结构到 [sp,#0x10]
0x82a8fc  ldr  w8, [sp, #0x10]                        ; +0x00 = codec_type
0x82a900  cmp  w8, #0xa                               ; 必须 == 10 (LHDC_V3)
0x82a904  b.ne #0x82ab5c                              ; 否则 return false（无日志、静默）
0x82a924  bl   A2dpCodecConfig::getCodecSpecificConfig(tBT_A2DP_OFFLOAD*)   ; ← 结果【从未被读取】
; ---- 采样率 ----
0x82a9d0  ldr  w8, [sp, #0x18]                        ; +0x08 = sample_rate（btav 位掩码）
0x82a9d4  sub  w9, w8, #1
0x82a9d8  cmp  w9, #0x3f
0x82a9dc  b.hi #0x82aaa4                              ; sr-1 > 63 → 走 0x80 特例判定
0x82a9e0  mov  w10, #1
0x82a9e4  lsl  x9, x10, x9                            ; 1 << (sr-1)
0x82a9e8  mov  x10, #-0x7fffffff80000000
0x82a9ec  movk x10, #0x808b                           ; x10 = 0x800000008000808B
0x82a9f0  tst  x9, x10
0x82a9f4  b.eq #0x82aaa4                              ; 不在掩码内 → 失败
0x82a9fc  str  w8, [sp, #8]                           ; ★ 原样透传，无钳位
; ---- 声道 ----
0x82a9f8  ldr  w9, [sp, #0x20]                        ; +0x10 = channel_mode
0x82aa00  cmp  w9, #2 ; cset w10, eq
0x82aa08  cmp  w9, #1 ; lsl w9, w10, #1 ; csinc w9, w9, wzr, ne
0x82aa14  strb w9, [sp, #0xc]                         ; LhdcParameters+4 = channelMode
0x82aa18  cbz  w9, #0x82aa50                          ; 无效 → 失败
; ---- 位深 ----
0x82aa1c  ldr  w8, [sp, #0x1c]                        ; +0x0c = bits_per_sample
0x82aa20  cmp  w8, #1 / #4 / #2 ; b.ne → 失败
0x82aa40  strb w8, [sp, #0xd]                         ; LhdcParameters+5 = bitsPerSample
; ---- LL ----
0x82a94c  ldrb w8, [sp, #0x30]                        ; +0x20 = codec_specific_2 低字节
0x82a958  and  w20, w8, #1
0x82a960  strb w20, [sp, #0xe]                        ; LhdcParameters+6 = isLLEnabled
; ---- 提交 ----
0x82aa38  add  x1, sp, #8
0x82aa3c  mov  x0, x19
0x82aa44  bl   CodecSpecific::lhdcConfig(const LhdcParameters&)
```

**掩码 `0x800000008000808B` 展开** = bit{0,1,3,7,15,31,63} → `sr-1 ∈ 该集合` → **`sr ∈ {1,2,4,8,16,32,64}`**
即允许的位掩码 = **{0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40}**：

| 掩码 | 含义 | 是否允许 |
|---|---|---|
| 0x01 | 44100 | ✅ |
| 0x02 | 48000 | ✅ |
| 0x04 | 88200 | ✅ |
| 0x08 | 96000 | ✅ |
| **0x10** | **176400** | **✅（报告/R3 未指出）** |
| **0x20** | **192000** | **✅（报告/R3 未指出）** |
| 0x40 | 16000 | ✅ |
| 0x80 | 24000 | ✅（0x82aaa4 特例） |
| 0x100/0x200 | 8000/32000 | ❌ |

> **结论**：`A2dpLhdcV3ToHalConfig` **不钳位任何参数**，只做合法性判定；且它**允许 176400/192000 通过**。
> 同样地，`A2dpCodecToHalSampleRate`（MTK HIDL）@`0x829ac0`（60 B）用的是**同一个掩码**，且返回**位掩码原值**（HIDL `SampleRate` 枚举与 btav 掩码同值）→ 也允许 0x10/0x20。
> **伪装没有钳位 96 kHz，也没有钳位 192 kHz。**

### 3.2 候选：`codec_type` 被改成 10 后，HAL 选的 AUDIO_FORMAT/通路是否不同？ → **排除**

| 观察项 | 证据 | 结论 |
|---|---|---|
| 送到 HIDL 的 `codecType` | `0x82a928 mov w8,#0x20` / `0x82a938 str w8,[x19],#0xc` | **恒为 0x20 = LHDC**，与内部索引 10/12 无关 |
| APM 侧格式 | 日志 `AS.AudioDeviceInventory: APM handleDeviceConfigChange success for A2DP device addr=... codec=AUDIO_FORMAT_LHDC`（`lhdc_param.log`，5 次） | LHDC 格式提示**正确到达 APM**，未被伪装影响（该映射来自 `A2dpCodecConfig` 的索引，不由 `getCodecConfig` 的改写决定） |
| `IsCodecOffloadingEnabled` 的输入 | `0x82bb48 ldr w23,[x20]`（= `codec_config->codecType` = 0x20）；`0x82bb54 cmp w23,w8`（对 HAL 声明的能力列表） | 匹配的是 **0x20=LHDC**，V3 伪装与原生 V5 输入完全相同 |
| 通路选择 | `0x825d18 cmp w8,#2` → 本机 session_type = `A2DP_SOFTWARE_ENCODING_DATAPATH`（日志 `BTAudioHalDeviceProxy: SetUp: session_type=A2DP_SOFTWARE_ENCODING_DATAPATH`） | 恒走 PCM 分支，与 codec 无关 |

> 另：设备当前 `dumpsys bluetooth_manager` 显示 `a2dp_source_offload_capability_mask: 0`，且 `persist.bluetooth.a2dp_offload.cap` **实测为空**（报告称 `sbc-aac`，与当前 boot 不符 —— 见 §6 修正表）。

### 3.3 候选：低延迟（LL）模式是否丢失？ → **★ 差异（HIDL 通路缺控制面）**

**这是本次最重要的新发现。**

**(a) HIDL 通路没有 LL 控制协议。** `vendor::mediatek::bluetooth::audio::a2dp::set_audio_low_latency_mode_allowed(bool)` @`0x8253b0`（108 B）全文：

```asm
0x8253c4  bl   HalVersionManager::GetHalTransport()
0x8253c8  and  w8, w0, #0xff
0x8253cc  cmp  w8, #4
0x8253d0  b.ne #0x8253e8
0x8253e4  b    bluetooth::audio::a2dp::set_audio_low_latency_mode_allowed      ; AOSP AIDL
0x8253e8  bl   HalVersionManager::GetHalTransport()
0x8253f0  cmp  w8, #2
0x8253f4  b.ne #0x82540c
0x825408  b    vendor::mediatek::...::aidl::a2dp::set_low_latency_mode_allowed  ; MTK AIDL
0x82540c  ... ret                                ; ★ transport ∈ {0,1,3} → 空操作
```

本机 `hal_version_ = 2` → `GetHalTransport() = 3`（R2 §6.4 常量表）→ **走到 `0x82540c`，直接返回，什么都不做**。

**(b) HIDL 接口里根本没有 LL 相关方法。** 字符串普查：

| 库 | `setLatencyMode` | `LatencyMode` | `LowLatencyModeAllowed` |
|---|---|---|---|
| `hl_vendor.mediatek.hardware.bluetooth.audio@2.2.so`（HIDL 接口） | 0 | 0 | 0 |
| `hal22.so`（HIDL 实现） | 0 | 0 | 0（只有 `isLowLatency`，来自 toString 字段名） |
| `libbluetooth_jni.so`（栈） | **3** | **8** | **3**（全部属于 AIDL 后端） |

栈侧符号：`vendor::mediatek::...::aidl::BluetoothAudioPortImpl::setLatencyMode(LatencyMode)` @`0x8560b0`、`bluetooth::audio::aidl::...::setLatencyMode` @`0x868680`、`...::aidl::BluetoothAudioClientInterface::SetLowLatencyModeAllowed(bool)` @`0x84f3e0` / `0x86a510`。
**没有任何 `hidl::...::setLatencyMode` / `hidl::...::SetLowLatencyModeAllowed`。**

**(c) HIDL HAL 模块对 LL 只打日志、不动作。** `audio.bluetooth.default.so`：
- `BluetoothAudioPortOut::LoadAudioConfig` @`0x19c90` 在 `0x1a010–0x1a040` 处把 `pcmConfig+6` 打出来，标签就是 `": savitech low latency = "`（源文件 `device_port_proxy.cc:344`）—— **纯日志**；
- `", LowLatencySt="`（@`0xc928`）与 `", latency="`（@`0x1034c`）同样是 ostream 拼接；
- 该 `.so` 的 **"lhdc" 字符串计数 = 0**。

**(d) 但 LL 信息本身在 HIDL 上仍有一条窄通道**：`pcmConfig.isLowLatencyEnabled = codec_specific_2 & 1`（`0x825d94–0x825da0`，见 §2.2）。本机实测该字段恒为 `Disabled`（`mCodecSpecific2 = 0`，见 `v5_dump.txt` 的 `mCodecConfig`）。

**(e) 反向发现：切到 AIDL 反而会丢 LL 标志。** MTK AIDL `a2dp::setup_codec` @`0x8378f0` 的 PCM 分支：

```asm
0x837e8c  stur  w20, [x29, #-0x70]        ; +0 = sampleRate（Hz）
0x837e90  sturb w0,  [x29, #-0x6c]        ; +4 = channelMode
0x837e94  sturb w8,  [x29, #-0x6b]        ; +5 = bitsPerSample
0x837e9c  stur  xzr, [x24, #6]            ; ★ +6..+13 全部清零 → isLowLatencyEnabled 恒为 0
0x837ea0  sturh wzr, [x29, #-0x62]        ; +14..+15 清零
```

即 **AIDL 的 PCM 结构里 LL 标志被硬编码为 0**（AIDL 侧改走 `setLatencyMode` 控制面）。

> **判定（已验证）**：**LL 是本机型上"V5"唯一真实的功能缺口，但它是 HIDL transport 的结构性缺口，不是"伪装 V3"造成的**。
> 换成原生 V5（若存在 HIDL 版转换函数）**同样拿不到 LL**。
> 而且 Java 侧还有一道独立的机型门禁：`MiuiBluetoothLatencyMode` 的名单 `{corot, duchamp, rothko, degas, malachite}` **不含 xaga**（R4 §5.1，`String.indexOf(ro.product.device)`），LL 开关在 UI 层即不可达。

### 3.4 候选：码率档位是否被 V3 结构限制？ → **排除**

| 观察 | 证据 | 结论 |
|---|---|---|
| 码率在哪 | V5 码率是 `lhdcv5_api.h` 的 `LHDCV5_QUALITY_T`（LOW0..AUTO，`LOW`=5→400K、`MID`=6→500K、`HIGH`=7→900K…），由 **encoder API** `set_target_bitrate_inx` 设置（R5 notes §2.7） | **纯编码器层** |
| 是否进 HAL 结构 | `a2dp_get_selected_hal_codec_config` 在 switch 之后填 `codec_config->encodedAudioBitrate = a2dp_config->getTrackBitRate()`（AOSP 原文 `a2dp_encoding_hidl.cc:277`；设备日志实测值 `500000 / 900000`） | 进的是 **`CodecConfiguration.encodedAudioBitrate`**，不是 `lhdcConfig`；且 HAL 软件通路**不读**该字段 |
| 伪装是否影响 | `A2dpCodecConfig::getTrackBitRate()` @`0x763610` 直接读 `this+0x1a8`（内部成员），**不经过 `getCodecConfig()`**，因此 P2 的改写窗口碰不到它 | **无影响** |
| 实测档位 | `v5_dump.txt`：`LHDC quality mode : LOW_400` / `LHDC transmission bitrate (Kbps) : 400000` | 当前默认档是 **400 kbps**；项目文档"陷阱 #10"的告警成立（96 kHz + 400 kbps ≈ 2.08 bit/sample） |

> **结论**：码率档位**未被 V3 结构限制**。但值得注意：**当前 96 kHz 的实测是在 400 kbps 档下完成的**，属于"速率达标、信息率不达标"。这是设置问题，不是伪装缺陷。

### 3.5 候选：AR / JAS / lossless / META 等 V5 特性 → **排除（全部不需要 HAL 知晓）**

本次枚举出 V5 的全部特性判定函数（`.dynsym`，全部签名为 `(out, const uint8_t* p_codec_info)`）：

| 地址 | 大小 | 函数 |
|---|---|---|
| `0x79bcf0` | 216 | `A2DP_VendorHasARFlagLhdcV5` |
| `0x79bc10` | 216 | `A2DP_VendorHasJASFlagLhdcV5` |
| `0x79bdd0` | 216 | `A2DP_VendorHasMETAFlagLhdcV5` |
| `0x79beb0` | 216 | `A2DP_VendorHasLLFlagLhdcV5` |
| `0x79b810` | 280 | `A2DP_VendorGetMaxBitRateLhdcV5` |
| `0x79b930` | 284 | `A2DP_VendorGetMinBitRateLhdcV5` |
| `0x79ba50` | 216 | `A2DP_VendorGetVersionLhdcV5` |
| `0x79bb30` | 216 | `A2DP_VendorGetBitPerSampleLhdcV5` |

`A2DP_VendorHasLLFlagLhdcV5` @`0x79beb0` 全文证实：它调用 `0x795f30`（CIE 解析器）解析 `p_codec_info`，把标志字节写进 `*out`（`0x79bf54–0x79bf5c`）。**没有任何 HAL 调用**。

> **结论**：AR / LARC / JAS / META / lossless / VBR / ABR **全部是 A2DP 信令层 + 编码器层**的概念（R5 notes §0：V5 配置面是"逐参数传递 + 带外扩展 API"，**没有**配置大结构体）。
> **在软件编码通路上，一个都不需要 HAL 知晓。** 只有"硬件卸载（offload）"才需要把 codec 配置交给 DSP —— 而本机 `persist.bluetooth.a2dp_offload.cap` 为空、`device_features/xaga.xml` 的 `support_lhdc=false`、HAL 也**没有** LHDC offload 分支（`IsOffloadCodecConfigurationValid` 对 codecType=32 无条件放行但 `lhdcConfig` 无分支，R3 §3.1）。

### 3.6 候选：192 kHz 是否被平台策略钳死？ → **是，但不止策略；且与伪装无关**

**三道闸门（本次逐条复核，含确切文件与行）**：

| # | 位置 | 内容 | 复核方式 |
|---|---|---|---|
| **1（决定性）** | `hl_libbluetooth_audio_session_mediatek.so` 的 `IsSoftwarePcmConfigurationValid` @`0x16e30` | `0x16e70 mov x10,#0x8b; 0x16e74 movk x10,#0x8000,lsl#48` → 掩码 `0x800000000000008b` = bit{0,1,3,7,63}；再加 `0x16eb0 mov w9,#0xcf; 0x16eb4 tst w8,w9; 0x16eb8 b.eq 失败`。**允许集 = {0x1,0x2,0x4,0x8,0x40,0x80} = {44100,48000,88200,96000,16000,24000}**。`0x10(176400)` / `0x20(192000)` 走 `0x16ec4 cmp w8,#0x80` → 不等 → `0x16ecc` 失败 | 本次全文反汇编 |
| 2（能力宣告） | 同库 `GetSoftwarePcmCapabilities` @`0x16bac`（V2_1 版）返回 `0xcf`；`GetSoftwarePcmCapabilities_2_1` @`0x1a244` 读 `.rodata 0x8580` = `cf 03 00 00 03 07 00 00 00 00 00 00` → sampleRate = **0x3cf** | 两者都不含 0x10/0x20 | 本次读出原始字节 |
| 3（音频策略） | **`/vendor/etc/bluetooth_offload_audio_policy_configuration.xml` 第 27–41 行**，三个 A2DP devicePort（`BT A2DP Out` / `BT A2DP Headphones` / `BT A2DP Speaker`）的 `<profile>`：**第 29 / 34 / 39 行** `samplingRates="44100 48000 88200 96000"` | 上限 96000 | `raw/16_bt_offload_policy.xml` 带行号复核 |

**关键补充（与报告/文档的推断不同）**：
- 栈侧**不阻 192 kHz**：`A2dpCodecToHalSampleRate` 掩码含 0x20 → 会原样发出 `RATE_192000`；`A2dpLhdcV3ToHalConfig` 掩码同样含 0x20。
- **A2DP 层实测已协商出 192000**：`v5_dump.txt` 有一条
  `mCodecConfig:{codecName:LHDC V5, mCodecType:12, mCodecPriority:1000000, mSampleRate:0x20(192000), mBitsPerSample:0x2(24), ...}`
  随后（同一次连接，2 秒后）回落为 `mSampleRate:0x8(96000)`。→ **192k 的失败点在 HAL 会话校验，不在协商、不在伪装。**
- 因此**闸门 1 是先触发的**：`setup_codec` 把 `RATE_192000` 交给 `UpdateAudioConfig`/`startSession` → `IsSoftwarePcmConfigurationValid` 拒绝 → 会话建立失败 → 无输出流 → 回落。
- 闸门 3 是"第二道"：即使把 HAL 掩码改开，AudioFlinger 仍无法按 192 kHz 打开 A2DP 输出流（profile 里没有该速率）。

> **判定**：192 kHz **确实不可达**，但**不是"被平台策略钳死"**这么单一 —— 决定性的是 HAL 会话库的掩码；策略是第二道。**两者都在 `/vendor`，与伪装方案无关。**

### 3.7 候选：`isLLSupported` 字段从未被填写 → **差异（但无功能影响）**

**对 R3 的修正**：`LhdcParameters` 不是 4 字段，而是 **5 字段 / 8 字节**：

| 偏移 | 类型 | 字段 | 写入者 |
|---|---|---|---|
| +0x0 | uint32 | `sampleRate` | V3 转换 `0x82a9fc` / V2 转换 |
| +0x4 | uint8 | `channelMode` | `0x82aa14` |
| +0x5 | uint8 | `bitsPerSample` | `0x82aa40` |
| +0x6 | uint8 | `isLLEnabled` | `0x82a960` |
| **+0x7** | **uint8** | **`isLLSupported`** | **无人写** |

证据：设备日志里 HAL/栈的 toString 明确打印 5 个字段
`{.sampleRate = RATE_96000, .channelMode = STEREO, .bitsPerSample = BITS_24, .isLLEnabled = Disabled, .isLLSupported = Unsupported}`（`lhdc_log` 中的 `a2dp_get_selected_hal_codec_config: CodecConfiguration={...}`，13 条 LHDC 记录全部为 `Unsupported`）。
而 V3 转换函数把 `lhdcConfig()` 现有的 8 字节整体拷到局部（`0x82a950 ldr x9,[x0]; 0x82a95c str x9,[sp,#8]`），只覆盖 +0/+4/+5/+6，**+7 保持原值（默认构造 = 0）**。

`lhdcConfig(const LhdcParameters&)` 的调用者全集（`r8_calls.py 0xf4ef20`）：
```
0x82aa44  A2dpLhdcV3ToHalConfig+0x194
0x82acac  A2dpLhdcV2ToHalConfig+0x11c
```
→ **只有 HIDL V2/V3 两个转换函数写它**，两者都不碰 +7。

> **判定**：`isLLSupported` 恒为 `Unsupported` 是**真实存在的信息缺失**，且**原生 V5 也不会有**（HIDL 侧没有 V5 转换函数）。
> **功能影响：无** —— HAL 只把它打进日志字符串（§3.1/§2.3 的 7/7 调用点证据）。

### 3.8 候选：稳定性 / 可维护性 → **★ 真实且最大的风险**

从模块源码 `xaga-lhdcv5/module/lhdcv5/jni/module.cpp`（417 行）与实际映射状态出发：

| # | 风险 | 证据 / 说明 | 严重度 |
|---|---|---|---|
| 1 | **4 个硬编码文件偏移 + 3 个 GOT 槽偏移** | `kP1Offset=0x2c562c`、`kP0Offset=0x763470`、`kP2Offset=0x82a904`、`kGotOsiPropertyGet=0xf94428`、`kGotGetCodecConfig=0xf95940`、`kGotLhdcV3ToHalConfig=0xf98d80` | 高（OTA 即失效） |
| 2 | **身份校验只覆盖 3 处 `.text`/`.rodata` 字节** | `0x763470 == 0x540005c0`、`0x2c562c == 0x5a`、`0x82a904 == 0x540012c1`；**不校验 GOT 槽里到底是不是目标符号**（只检查非 0） | 中（同构建必然一致，跨构建已由 3 处兜底） |
| 3 | **P0 是对 `osi_property_get` 的进程级 GOT 重定向** | 作用域限定在 `libbluetooth_jni.so` 自己的 PLT（其他库不受影响），但**该库内所有属性读取都过这个钩子**；对 `ro.product.name` 恒返回 `corot` | 低（过滤按 key 精确 `strcmp`） |
| 4 | **P0 的语义副作用** | 日志实测 `I btif_av: Init: Init: User: ro.product.name = corot`（报告 §3.5）。`BtifAvSource::Init` 用该属性决定 LHDC V2/V3 使能（R4 §4.3 长名单）；`corot` 也在该名单内 → 结果不变。**但这是"改属性而非改判定"的副作用，换构建后不保证** | 低 |
| 5 | **P2 的 TLS 标志未做异常安全** | `g_in_lhdc_conversion` 用 `= true ... = false` 包裹，无 RAII；该路径无异常/长跳转，风险极低 | 极低 |
| 6 | **P2 依赖"`A2dpLhdcV3ToHalConfig` 只有一个调用者"** | 本次复核 `r8_calls.py 0x825ec0`：`a2dp_get_selected_hal_codec_config` 的**唯一**调用者是 `hidl::a2dp::setup_codec+0x54`（`0x825b34`）；`A2dpLhdcV3ToHalConfig` 的 GOT 槽 `0xf98d80` 唯一调用点 `0x826090`（R2 §3.2）。→ 当前成立 | 低 |
| 7 | **`mprotect` 恢复为 `PROT_READ`（非原始权限）** | 实测 maps：`libbluetooth_jni.so` 的 `00f65000` 段（覆盖 0xf94428/0xf95940/0xf98d80）映射为 `r--p`；`.rodata` 所在的首段也是 `r--p`。→ **恢复正确**（R8 独立复核，非缺陷） | — |
| 8 | **对多设备的影响** | 补丁按"字节指纹"生效：同 APEX 构建的**任何机型**都会被改写。副作用：① 其 `ro.product.name` 也被改成 `corot`；② 若该机型本无 V5 编码器库，`A2dpCodecConfigLhdcV5Source::init()` 的 `A2DP_VendorLoadEncoderLhdcV5()` 会失败 → V5 被自然丢弃（安全）。**无"变砖"路径** | 低 |
| 9 | **APEX 升级的失效模式** | `com.android.btservices` 是 APEX（可独立升级）。新构建 → 3 处指纹不符 → `LOGE("library does not match the build this patch targets -- aborting")` 并放弃。**fail-safe，但功能静默消失**（用户只会发现 V5 没了） | 高（运维） |
| 10 | **未覆盖第二道按设备门禁** | `persist.bluetooth.a2dp.lhdc.whitelist`（`BtaAvCo::SelectSourceCodec` @`0x692e30`，R2 §8.4）。本机实测该属性**为空**，当前不阻塞；换耳机/换固件后可能成为新阻塞点 | 中 |

---

## 4. 任务 3 — 对报告附录 D 两条"未走通方向"的评估

### 4.1 方向 1：「补丁 HIDL 桥接」——**判断：可行，且当前实现已走通；当时的否决基于一个错误前提**

报告的原文理由：
> "需**同时**限制采样率 ≤ 88200（HAL 的 LHDC 上限），且要解决开机时把补丁库送进 bluetooth 私有命名空间的问题。两处补丁 + 命名空间难题，成功率不确定。"

逐条核对：

| 理由 | 复核 | 判定 |
|---|---|---|
| "HAL 的 LHDC 上限 88200" | **不存在这个上限。** ① 卸载校验 `IsOffloadCodecConfigurationValid` **没有 LHDC 分支**（对 codecType=32 直接 `return true`，不校验参数）；② 软件通路的 PCM 白名单含 **96000**（§3.6 闸门 1/2）；③ `88200` 这个数字在 HAL 二进制里找不到依据（R3 §10 同结论）。实测 96 kHz 通过 | ❌ **前提错误** |
| "要解决把补丁库送进 bluetooth 私有命名空间" | 这是 **bind-mount 方案**的困难（报告 §4.1 已实测否决）。**内存补丁方案不存在这个问题** —— 当前实现正是用 Zygisk 在进程内改内存，零挂载、零 SELinux 改动 | ❌ **前提不适用** |
| "两处补丁" | 正是当前的 P1 + P2（跳转表 + 转换函数守卫）。实测已生效：`Unknown codec_type=12` 出现 0 次 | ✅ 已实现 |

> **结论**：方向 1 **不是不可行，而是当时被两个错误前提劝退**。它已经以"内存补丁"的形态落地。
> **但它也不带来任何 (丙) 类收益**（§2.3）—— 它只是"让通路能建立"的必要手段，不是"让 V5 语义到达 HAL"。

### 4.2 方向 2：「修改 `/vendor/etc` 音频策略」——**判断：可行，且是 192 kHz 的必经之路；报告把它判为"无意义"是次序错误**

报告原文：
> "放宽 BT A2DP 采样率声明。但即便放宽，`Unknown codec_type=12` 依然阻断。"

| 部分 | 复核 | 判定 |
|---|---|---|
| "即便放宽，codec_type=12 依然阻断" | **次序上正确**：`setup_codec` 在 `a2dp_get_selected_hal_codec_config` 返回 false 时提前 return（§2.2），根本走不到 APM 打开输出流 | ✅ 成立 |
| 隐含结论"所以这条路无意义" | **不成立**：codec_type 阻塞已由 P1/P2 解决；在此之后，**策略文件是 192 kHz 的第二道闸门**，且是必须动的 | ❌ 结论不成立 |
| 可行性 | R3 §7.3 已实测：`/vendor` 是 `dm-12 vendor-verity` erofs ro（磁盘不可改），**但** pid 1006（`android.hardware.audio.service.mediatek`）与 init **同一 mount namespace**（`mnt:[4026533766]`），因此 `post-fs-data` 阶段 bind-mount 覆盖 `/vendor/lib64/hw/*` 与 `/vendor/etc/*.xml` **对该服务可见**（与 BT 进程被 Zygisk Next 剥离挂载的困境不同）。需配 `mount --context=u:object_r:vendor_file:s0` 或 sepolicy 规则 | ⚠️ 可行但有 SELinux/时序成本 |
| 需要改的最小集合 | ① `/vendor/etc/bluetooth_offload_audio_policy_configuration.xml` 第 29/34/39 行加 `192000`；② `libbluetooth_audio_session_mediatek.so` 的 `IsSoftwarePcmConfigurationValid` 掩码（`0x16e70–0x16e7c`）与 `GetSoftwarePcmCapabilities(_2_1)` 常量（`.rodata 0x8580` / `0xcf`）—— 二者都在 `/vendor`，可 bind-mount 或对 pid 1006 做进程内注入 | 明确 |

> **结论**：方向 2 **可行**，是 192 kHz 的**必要条件**（非充分：还要改 HAL 会话库掩码）。报告把它判为"无意义"是因为当时尚未解决 codec_type 阻塞 —— **次序问题，不是可行性问题**。

---

## 5. 任务 4 —「V5 与伪装 V5 的差异清单」

> **总纲**：在 **xaga + HIDL + 软件编码** 这个具体组合下，"V5"与"伪装 V5"在**音频数据面上逐字节等价**。下表把所有差异项按"是否有差异"分类。

### 5.1 存在差异的项（3 项）

| # | 差异项 | 影响面 | 证据强度 | 要实现它必须改动哪一层 | 实际收益 |
|---|---|---|---|---|---|
| **D1** | **低延迟（LL）控制面**：框架→HAL 的 `setLowLatencyModeAllowed(bool)` / HAL→栈的 `setLatencyMode(LatencyMode)` / `startSession` 的 `supportedLatencyModes[]` 在 **HIDL transport 下全部不存在** | **延迟**（功能） | **已验证**（`0x8253b0` 分发器 no-op + 4 个库的字符串普查 + 栈侧符号仅 AIDL） | **栈的传输选择层**（让 `hal_version_` 变成 3/4 ⇒ 需要 vendor AIDL 实现 + VINTF + 服务注册）**且** 需改 HAL 侧（`audio.bluetooth.default.so` 只有 LL 日志、无 LL 逻辑）**且** 需绕过 Java 机型门禁 `MiuiBluetoothLatencyMode` | **低**：三重门禁，任一层不通都白做；且 AIDL 的 PCM 结构反而清零 LL 标志 |
| **D2** | **`LhdcParameters.isLLSupported` 恒为 `Unsupported`** | 无（仅日志） | **已验证**（`lhdcConfig` setter 的 2 个调用点都不写 +7；日志 13/13 为 Unsupported） | 栈侧新增 HIDL 版 V5 转换函数（不存在），或直接改 `A2dpLhdcV3ToHalConfig` 多写一个字节 | **零** |
| **D3** | **可维护性**：4 个硬编码偏移 + 3 个 GOT 槽偏移，无符号级定位；APEX 升级即静默失效 | **稳定性** | **已验证**（`module.cpp` 常量 + 身份校验逻辑） | **模块自身**（改用"符号 + 特征码"定位，或做版本适配表） | **高**（唯一有实际工程价值的改进方向） |

### 5.2 经核验**不存在**差异的项（排除，7 项）

| # | 候选差异 | 影响面 | 结论 | 关键证据 |
|---|---|---|---|---|
| E1 | 采样率被钳位 | 音质 | **无差异** —— 掩码 `0x800000008000808B` 允许 {44100,48000,88200,96000,176400,192000,16000,24000}，原样透传 | `0x82a9e8–0x82a9fc` 全文 |
| E2 | 位深被钳位 | 音质 | **无差异** —— 只判 ∈{16,24,32}，不钳位 | `0x82aa1c–0x82aa40` |
| E3 | 声道被钳位 | 音质 | **无差异** —— 只判 MONO/STEREO | `0x82a9f8–0x82aa18` |
| E4 | HAL 收到不同 `AUDIO_FORMAT`/通路 | 音质/通路 | **无差异** —— HIDL `codecType` 恒为 0x20(LHDC)；APM 实测收到 `AUDIO_FORMAT_LHDC`；session_type 恒为软件通路 | `0x82a928`；`AS.AudioDeviceInventory` 日志 5 条 |
| E5 | 码率档位受限 | 音质 | **无差异** —— 码率在 encoder 层（`LHDCV5_QUALITY_T`），经 `getTrackBitRate()` 填 `encodedAudioBitrate`，HAL 不读 | `0x763610`；日志 500000/900000 |
| E6 | AR / JAS / lossless / META 丢失 | 功能 | **无差异** —— 全部是 A2DP CIE 解析 + encoder API，8 个 `A2DP_Vendor*LhdcV5` 特性函数均只读 `p_codec_info` | `0x79beb0` 全文 |
| E7 | 192 kHz 被伪装阻断 | 音质 | **无差异（但也不可达）** —— 栈侧允许 0x20 且实测协商出 192000；阻断在 HAL 会话掩码 + 策略 | §3.6 三闸门 |

### 5.3 若要"V5"（不伪装）的**最小充分改动集**

按"是否第三方可达"分类：

| 层 | 需要什么 | 可达性 |
|---|---|---|
| 栈（APEX，可内存补丁） | 一个 HIDL 版 V5 转换函数 —— **不存在**；退而求其次：把 `table[12]` 指向 V3 转换函数 + 让 V3 转换函数接受 12（= **当前 P1+P2**） | ✅ 已实现 |
| HIDL 接口（`vendor.mediatek...@2.2`） | 新增 `Lhdcv5Configuration` + 版本号 → 需厂商出 `.hal` + `.so` | ❌ 第三方不可行 |
| HAL 实现（软件通路） | **不需要**（只消费 `pcmConfig`） | — |
| HAL 实现（卸载通路） | **不需要**（codecType=32 无条件放行） | — |
| **HAL 会话库**（`libbluetooth_audio_session_mediatek.so`） | 若目标是 **192 kHz**：放开 `IsSoftwarePcmConfigurationValid` 掩码 + `GetSoftwarePcmCapabilities` 常量 | ⚠️ `/vendor`，可 bind-mount / 进程内注入 |
| 音频策略 | 若目标是 **192 kHz**：`samplingRates` 加 192000（第 29/34/39 行） | ⚠️ 同上 |
| 传输选择 | 若目标是 **LL**：`hal_version_ → 3`（AIDL 服务 + VINTF + SELinux） | ❌ 等价于要求厂商固件 |
| 模块自身 | 若目标是 **稳定性**：符号级/特征码定位替代硬编码偏移 | ✅ 完全可达 |

---

## 6. 对既有报告的修正与新增

| # | 既有表述 | R8 复核 |
|---|---|---|
| 1 | 实现文档 §1："伪装后 96kHz 得以保留 —— V3 转换函数原样透传、无任何钳位" | ✅ **成立**。补充：掩码 `0x800000008000808B` 还允许 **176400/192000**，即 V3 转换函数对采样率**完全不设上限** |
| 2 | R3 §4.4：`LhdcParameters` = 8 字节 `{sampleRate, channelMode, bitsPerSample, isLLEnabled}` | ⚠️ **需补第 5 个字段** `isLLSupported` @+0x7（toString 日志 + setter 调用点双证据） |
| 3 | R3 §7.1 / MAIN-findings §0："软件通路下 HAL 侧零改动，伪装与原生等价" | ✅ **独立复核成立**，并补上"返回 bool 必须为 true，否则 `setup_codec` 提前 return"这一层机制 |
| 4 | 报告 §3.3 附带发现：`persist.bluetooth.a2dp_offload.cap = sbc-aac` | ⚠️ **当前 boot 实测为空**（`getprop` 返回空；`dumpsys` 的 `a2dp_source_offload_capability_mask: 0`）。结论（不走卸载）不变，但引用该值时需注明来源 boot |
| 5 | 报告 §3.6 的失败链 "`Unknown codec_type=12` → `Failed to get CodecConfiguration` → ... → 回落扬声器" | ✅ 成立。精确机制：`setup_codec` 在 `0x825b38` 判 false 后**提前 return**（不是"配置传错导致选错通路"） |
| 6 | 报告附录 D-1："HAL 的 LHDC 上限 88200" | ❌ **不存在此上限**（见 §4.1）。这个错误前提直接导致了方向 1 被误判为"不可行" |
| 7 | 报告 §3.5 / 实现文档 §5.2："192 kHz 不可能（策略只声明到 96000）" | ⚠️ **结论成立，理由需补全为三道闸门**；且决定性的是 HAL 会话库掩码，不是策略。另：A2DP 层**实测协商出过 192000**（`v5_dump.txt`） |
| 8 | — | 🆕 **HIDL transport 下 `set_audio_low_latency_mode_allowed` 是空操作**（`0x82540c`），AIDL 才有实现 |
| 9 | — | 🆕 **MTK AIDL 的 PCM 分支把 `isLowLatencyEnabled` 硬编码为 0**（`0x837e9c`），切 AIDL 反而丢 LL 标志 |
| 10 | — | 🆕 **`A2dpLhdcV3ToHalConfig` 里 `getCodecSpecificConfig()` 的返回值从未被读取**（`0x82a924` 调用后无任何读取）—— 死调用，说明该函数是从某个使用 `tBT_A2DP_OFFLOAD` 的模板改写而来 |
| 11 | — | 🆕 **V5 特性判定函数共 8 个**（AR/JAS/META/LL/MaxBitRate/MinBitRate/Version/BitPerSample），全部只读 `p_codec_info`（A2DP CIE），**零 HAL 调用** |
| 12 | 实现文档 §5.2 验证表："HAL 通路 `APM handleDeviceConfigChange success … codec=AUDIO_FORMAT_LHDC`" | ✅ 复核成立（5 条日志），但它证明的是 **APM 收到了 LHDC 格式**，**不能**用来证明"HAL 拿到了 V5 信息" |

---

## 7. 证据分级

### 7.1 已验证事实（可复现，含地址/偏移/命令）

1. `A2dpLhdcV3ToHalConfig` @`0x82a8b0`（736 B）**全文**：守卫 `cmp w8,#0xa`；采样率掩码 `0x800000008000808B`（允许 0x10/0x20）；位深只判 {1,2,4}；声道只判 {1,2}；**无任何钳位**；写 `LhdcParameters` 的 +0/+4/+5/+6，**不写 +7**；`getCodecSpecificConfig` 结果未被读取。
2. `setup_codec`（MTK HIDL）@`0x825ae0`：`a2dp_get_selected_hal_codec_config` 返回 false → `0x825c1c` 提前 return；`codec_config` 的唯一消费者是 `IsCodecOffloadingEnabled`（`0x825b40`）；PCM 分支在 `0x825d48`，参数来自**另一次** `getCodecConfig()`（`0x825d68`）；`pcmConfig.isLowLatencyEnabled = codec_specific_2 & 1`（`0x825d94–0x825da0`）。
3. `a2dp_get_selected_hal_codec_config` @`0x825ec0` 的**唯一**调用者 = `hidl::a2dp::setup_codec+0x54`（`r8_calls.py`）。
4. `A2dpCodecToHalSampleRate`（MTK HIDL）@`0x829ac0`（60 B）：掩码 `0x800000008000808B`，**返回位掩码原值**（HIDL 枚举与 btav 掩码同值）。
5. `IsSoftwarePcmConfigurationValid` @`0x16e30`（session 库）：掩码 `0x800000000000008b` + `&0xcf` ⇒ 允许集 `{0x1,0x2,0x4,0x8,0x40,0x80}`，**拒绝 0x10/0x20**。`GetSoftwarePcmCapabilities` = `0xcf`；`_2_1` = `0x3cf`（`.rodata 0x8580` = `cf 03 00 00 03 07 00 00 00 00 00 00`）。
6. `libbluetooth_jni.so` 运行时映射：`00f65000` 段（含三个 GOT 槽）为 `r--p`；`.rodata`（含 `0x2c562c`）在首段 `r--p` ⇒ 模块的 `mprotect(R)` 恢复正确。
7. `vendor::mediatek::bluetooth::audio::a2dp::set_audio_low_latency_mode_allowed` @`0x8253b0`：transport ∈ {4→AOSP AIDL, 2→MTK AIDL}，其余**空操作**；本机 transport=3。
8. 4 个 HAL/接口库的 LL 字符串普查：HIDL 接口 0 个，HIDL 实现 0 个（只有 `isLowLatency` 字段名），栈侧 `setLatencyMode`×3 / `LatencyMode`×8 / `LowLatencyModeAllowed`×3（全部 AIDL）。
9. `audio.bluetooth.default.so`：**"lhdc" 字符串 0 个**；`pcmConfig+6` 仅被 `": savitech low latency = "` 日志打印（`0x1a010–0x1a040`，`device_port_proxy.cc:344`）；`LowLatencySt=`（`0xc928`）/`latency=`（`0x1034c`）同为日志拼接。
10. MTK AIDL `setup_codec` @`0x8378f0` PCM 分支：`stur xzr,[x24,#6]`（`0x837e9c`）+ `sturh wzr,[x29,#-0x62]` ⇒ **LL 标志清零**。
11. 8 个 `A2DP_Vendor*LhdcV5` 特性判定函数（地址见 §3.5），`HasLLFlagLhdcV5` @`0x79beb0` 全文确认只解析 `p_codec_info`。
12. `lhdcConfig(const LhdcParameters&)` 的 setter（PLT `0xf4ef20`）调用者全集 = 2 个（HIDL V2/V3 转换函数）。
13. 设备只读实测：所有 LHDC 相关属性**均为空**；`ro.product.name = xaga`；`/data/adb/modules/lhdcv5/disable` **存在**（模块当前停用）；`dumpsys` 的 `a2dp_source_offload_capability_mask: 0`。
14. 192 kHz 三闸门的确切位置（含 `/vendor/etc/bluetooth_offload_audio_policy_configuration.xml` **第 29/34/39 行**）。
15. `v5_dump.txt` 中存在 `mSampleRate:0x20(192000), mCodecPriority:1000000` 的 `mCodecConfig` 记录（2 秒后回落 96000）⇒ **A2DP 层协商出过 192000**。
16. `v5_dump.txt`：`LHDC quality mode : LOW_400` / `LHDC transmission bitrate : 400000` ⇒ 96 kHz 实测时码率档为 400 kbps。

### 7.2 推断（有证据支持但非直接观测）

- `CodecSpecific` union 判别子顺序（R3 §3.1 由校验分支反推）。
- `LhdcParameters` 字段的**名字**来自 toString 字符串（内存布局由写入偏移确定，二者一致）。
- `BtifAvSource::Init` 的 `ro.product.name` 长名单匹配方式（`indexOf` 子串 vs 精确比较）—— 从 P0 生效后 LHDC V2/V3 仍可用**反推**其匹配对 `corot` 成立。
- Java 侧 `MiuiBluetoothLatencyMode` 是 LL 的唯一 UI 门禁（R4 §5.1 的 dex 证据 + 无其它 native 开关）。
- `IsCodecOffloadingEnabled` 在匹配到 LHDC 能力后走内部 switch 的 default 分支并返回 false（由"实测走软件通路"反推；未逐指令确认 `0x82c1a4` 的返回值）。

### 7.3 未知 / 未验证

- `Lhdcv5Configuration`（MTK AIDL）11 个标量的**字段名**（二进制不可恢复；公开 `.aidl` 未找到）。
- AIDL `PcmParameters` 里是否存在 MTK 私有的 LL 字段（本次只确认 HIDL 版有 `isLowLatencyEnabled`）。
- `A2dpCodecConfigLhdcV5Base::setCodecConfig`（8560 B）中 `codec_specific_2` bit0 的**写入路径**（即"LL 使能时该位是否被置 1"）—— 未逐指令追踪。
- 把 `IsSoftwarePcmConfigurationValid` 掩码与策略放开后，192 kHz 是否能出声（未做实验；本任务只读）。
- 日志中 `encodedAudioBitrate = 9999999` 的来源（疑似"未知码率"哨兵；与伪装无关，`getTrackBitRate` 不经过被钩子的 `getCodecConfig`）。

---

## 8. 对后续路线设计的直接含义

1. **不要把"让 HAL 原生认识 V5"作为目标** —— 在本机型（HIDL + 软件编码）上它是伪需求，任何以此为核心的路线都不产生可观测收益。§5.2 的 7 项排除表可以直接作为"不必做"的清单。
2. **当前伪装方案在音质/功能上已经封顶**：96 kHz 已通，192 kHz 的瓶颈在 HAL 会话库与策略（与 V5/V3 无关），LL 的瓶颈在三重门禁（Java 机型名单 + HIDL 控制面缺失 + HAL 无 LL 逻辑）。
3. **唯一值得投入的工程方向是 丁-2（稳定性）**：把 4+3 个硬编码偏移换成"符号/特征码 + 版本适配"，或至少让失效时能给出明确提示。
4. **若一定要追求"不伪装"**：可达的形态只有 **AIDL transport**，而它需要 vendor 侧 AIDL 实现 + VINTF + 服务注册（等价于厂商固件），**且实测会让 LL 标志从"跟随 codec_specific_2"退化为"恒为 0"** —— 是负收益。
5. **若要 192 kHz**：改动集合明确且都在 `/vendor`（会话库掩码 + 能力常量 + 策略 XML 第 29/34/39 行），可用 bind-mount（音频 HAL 服务与 init 同 mount namespace）或对 pid 1006 进程内注入。**与 V5/V3 之争无关。**
