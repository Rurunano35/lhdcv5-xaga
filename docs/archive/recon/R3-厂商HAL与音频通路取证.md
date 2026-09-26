# R3 — 厂商侧 HAL 与音频通路取证

> 设备：Redmi Note 11T Pro（xaga / MT6895）/ HyperOS `OS2.0.12.0.ULOCNXM` / Android 14 / KernelSU root
> 取证方式：**全部只读**（`adb shell` 读取 + `lshal` / `dumpsys` / `/proc`；二进制离线反汇编）
> 脚本：`d:/Cache/Hyperos/lhdcv5-tr/analysis/scripts/r3/`（r3_dis.py / r3_elfinfo.py / r3_plt.py / r3_callsites.py / r3_strings.py）
> 原始 dump：`d:/Cache/Hyperos/lhdcv5-tr/analysis/raw/`
> 反汇编工具：capstone 5.0.7 + pyelftools（`PYTHONPATH=d:/Cache/Hyperos/pylibs`）
> 说明：7 个目标 .so 的 `sh_addr == sh_offset`，**VA 即文件偏移**。

---

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| (a) 厂商 HAL 实现 | `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so`（本地副本 `hal22.so`，173360 B），服务名 `vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory/default`，**HIDL/hwbinder**，由 `android.hardware.audio.service.mediatek`（pid 1006）注册 |
| (b) 接受的 codec_type | HIDL `CodecType` 是**位枚举**：`SBC=1 AAC=2 APTX=4 APTX_HD=8 LDAC=16 LHDC=32`。**软件通路根本不读 codec_type**；卸载（offload）通路只接受这 6 个值，其余走 `return false` + ERROR 日志 |
| (c) lhdcConfig 用途 | **HAL 完全不用**。7 处 `lhdcConfig()` 调用全部在调试字符串拼接里（`.lhdcConfig = `）。软件通路只用 `pcmConfig`；卸载通路只用 `codecConfig.codecType` + 各 codec 的 sampleRate/bits/channelMode |
| (d) PCM 通路 | 应用 → AudioFlinger → `audio.bluetooth.default.so`（"bluetooth" 音频 HAL 模块，**同在 pid 1006**）`out_write` → `BluetoothAudioPortOut::WriteData` → `BluetoothAudioSession::OutWritePcmData` → **FMQ 写**；BT 栈 `libbluetooth_jni.so` 从同一 FMQ **读**。**不是** `IBluetoothAudioHost::streamOut` |
| (e) AIDL | 接口库在 APEX（`vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`，含 `Lhdcv5Configuration`/`Lhdcv5Capabilities`），但**设备上没有任何 AIDL 实现**（无服务、VINTF 无 aidl 条目、/vendor 无 -ndk 实现库）→ 该 HAL **只支持 HIDL** |
| (f) 最小改动 | **软件通路下 HAL 侧零改动**（HAL 与 codec 无关）。缺口在 HIDL 接口本身没有 V5 结构 → 无法"V5"。文件在 `/vendor`（非 APEX），但 `/vendor` 是 `dm-12 = vendor-verity` erofs ro；**可 bind-mount 替换**（音频 HAL 服务与 init **同一 mount namespace**） |
| (g) 192 kHz | **不支持**。三道闸：音频策略 `samplingRates` 上限 96000；HAL 的 `IsSoftwarePcmConfigurationValid(_2_1)` 显式拒绝 `sampleRate` 位 `0x10/0x20`；`kSoftwarePcmCapabilities` 只声明到 96000。`LoadAudioConfig` 里有 0x20→192000 的映射，但过不了校验 |

---

## 1. 目标文件身份核对（设备 vs 本地副本）

`sha256sum` 全部一致（设备侧用 `su -c`，原始输出见 `raw/22_device_sha256.txt`）：

| 设备路径 | 本地副本 | 大小 | SHA256 |
|---|---|---|---|
| `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so` | `hal22.so` | 173360 | `8a26665956b391d4e815aae1173cc3388e418e65227e88c112eb310654511fa2` |
| `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.1-impl.so` | `hl_vendor.mediatek.hardware.bluetooth.audio@2.1-impl.so` | 96824 | `2aca8fb9be864cce531457e85324ffbb77591d7dfe691605b23384053791e64a` |
| `/vendor/lib64/hw/audio.bluetooth.default.so` | `audio.bluetooth.default.so` | 135032 | `7ad79adf061a763be1d4863dbedeab7cd340bde12fcdd71844c34a5f41930b67` |
| `/vendor/lib64/libbluetooth_audio_session_mediatek.so` | `hl_libbluetooth_audio_session_mediatek.so` | 120608 | `5eadb9b650f71da4a65ed68840e0d83807adf32f8e83cab30a1f0032a27592e6` |
| `/vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.2.so` | `hl_vendor.mediatek.hardware.bluetooth.audio@2.2.so` | 170448 | `b33b026e2a8b23b7e0d307156b5c37dcc383c28cba31dfc4502b7af3ed3fdd55` |
| `/vendor/lib64/hw/android.hardware.bluetooth.audio@2.1-impl.so` | `hl_android.hardware.bluetooth.audio@2.1-impl.so` | 140800 | `76754fbafffaa97f7fc9d627833524bc94a12a1576733cf51f1cbd2d8ec58441` |

> 注意：`hl_audio.primary.mediatek.so`（2831384 B）与 /vendor 上同名文件亦一致，但**与本议题无关**（它是 primary 音频 HAL，不含 BT 通路）。

---

## 2. (a) 厂商 HIDL HAL 实现是哪个文件 / 服务名 / VINTF 声明

### 2.1 服务与实现

```
$ adb shell lshal | grep -i "bluetooth.audio"
FC ? android.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default          N/A 1006 1006
FC ? vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory/default  N/A 1006 1006
X  ? vendor.mediatek.hardware.bluetooth.audio@2.1::I*/* (/vendor/lib64/hw/)                 N/A N/A
X  ? vendor.mediatek.hardware.bluetooth.audio@2.2::I*/* (/vendor/lib64/hw/)                 N/A N/A

$ adb shell ps -A -o PID,NAME | grep -iE "audio|blue"
1006 android.hardware.audio.service.mediatek
1007 android.hardware.bluetooth@1.1-service-mediatek
1109 audioserver
2688 com.android.bluetooth
```

**关键事实**：不存在独立的 BT 音频 HAL 服务进程。`vendor.mediatek...@2.2` 与 `android.hardware.bluetooth.audio@2.1` 两个工厂**都由音频 HAL 服务 `android.hardware.audio.service.mediatek`（pid 1006）注册**。

`/proc/1006/maps`（`raw/07b_maps_1006_full.txt`）证实它加载了全部相关库：

```
/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so   ← 厂商 HIDL 实现（= hal22.so）
/vendor/lib64/hw/android.hardware.bluetooth.audio@2.1-impl.so           ← AOSP 包 2.1 实现（同进程，备用）
/vendor/lib64/hw/audio.bluetooth.default.so                             ← "bluetooth" 音频 HAL 模块
/vendor/lib64/libbluetooth_audio_session_mediatek.so                    ← MTK 版 session 库
/vendor/lib64/libbluetooth_audio_session.so                             ← AOSP 版 session 库
/vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.1.so / @2.2.so ← HIDL 接口/代理
/vendor/lib64/android.hardware.bluetooth.audio@2.0.so / @2.1.so
```

`hal22.so` 的导出符号确认它就是实现体（`raw/r3_elfinfo.txt`）：

```
0x00010440  BluetoothAudioProvidersFactory::openProvider(V2_2::SessionType, ...)          ; V2_2 入口
0x000108dc  BluetoothAudioProvidersFactory::openProvider_2_1(V2_1::SessionType, ...)      ; V2_1 兼容
0x00010e58  BluetoothAudioProvidersFactory::getProviderCapabilities(V2_1::SessionType,...)
0x00011268  BluetoothAudioProvidersFactory::getProviderCapabilities_2_1(...)
0x00011700  HIDL_FETCH_IBluetoothAudioProvidersFactory                                    ; HIDL 工厂取用点
0x00012e30  BluetoothAudioProvider::startSession(V2_1::IBluetoothAudioPort, V2_1::AudioConfiguration, cb)
0x00012fbc  BluetoothAudioProvider::startSession_2_1(V2_1::IBluetoothAudioPort, V2_2::AudioConfiguration, cb)
0x00018418  A2dpOffloadAudioProvider::startSession(...)      ; 卸载通路
0x0001b2e4  A2dpSoftwareAudioProvider::startSession(...)     ; 软件通路
```

日志侧交叉验证（`raw`/`artifacts/logs/lhdc_param.log`）：

```
I/MediatekBTAudioProvidersFactory(17108): getProviderCapabilities - SessionType=A2DP_HARDWARE_OFFLOAD_DATAPATH supports 6 codecs
I/MediatekBTAudioProvidersFactory(17108): openProvider - SessionType=A2DP_SOFTWARE_ENCODING_DATAPATH
```
`MediatekBTAudioProvidersFactory` 这个日志 tag 字符串就在 `hal22.so` 的 `.rodata 0xcef1`。

各 .so 内嵌的源码路径（反汇编中 `LogMessageCtor` 的 file 参数，属强证据）：

| 文件 | 源码路径 |
|---|---|
| `hal22.so` | `vendor/mediatek/proprietary/hardware/interfaces/bluetooth/audio/2.2/default/A2dpSoftwareAudioProvider.cpp` / `A2dpOffloadAudioProvider.cpp` |
| `hl_libbluetooth_audio_session_mediatek.so` | `vendor/mediatek/proprietary/hardware/interfaces/bluetooth/audio/utils/session/BluetoothAudioSupportedCodecsDB.cpp`、`.../BluetoothAudioSupportedCodecsDB_2_1.cpp` |
| `libbluetooth_jni.so`（栈） | `vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/mediatek/audio_hal_interface/hidl/codec_status_hidl.cc` |


### 2.2 VINTF 声明

`/vendor/etc/vintf/manifest.xml`（`raw/05_vintf_manifest.xml`）：

```xml
<!-- L70-79 -->
<hal format="hidl">
    <name>android.hardware.bluetooth.audio</name>
    <transport>hwbinder</transport>
    <version>2.1</version>
    <interface><name>IBluetoothAudioProvidersFactory</name><instance>default</instance></interface>
    <fqname>@2.1::IBluetoothAudioProvidersFactory/default</fqname>
</hal>

<!-- L334-343 -->
<hal format="hidl">
    <name>vendor.mediatek.hardware.bluetooth.audio</name>
    <transport>hwbinder</transport>
    <version>2.2</version>
    <interface><name>IBluetoothAudioProvidersFactory</name><instance>default</instance></interface>
    <fqname>@2.2::IBluetoothAudioProvidersFactory/default</fqname>
</hal>
```

- 整个 `manifest.xml` **没有任何 `format="aidl"` 条目**（`grep -c 'format="aidl"'` = 0）。
- `/vendor/etc/vintf/manifest/` 下 45 个 fragment 里也没有 bluetooth audio 相关条目。
- 厂商 `@2.1` 变体在 VINTF 中**未声明**（lshal 中仅以 `DM,FC` 形式出现，未运行）——即实际只有 **@2.2** 一条厂商 HIDL 链路。

---

## 3. (b) 该实现接受哪些 codec_type？未知类型如何处理？

### 3.1 HIDL `CodecType` 枚举被反解出来 = 位枚举

两条独立证据（均在 `hl_libbluetooth_audio_session_mediatek.so`，源码路径字符串为
`vendor/mediatek/proprietary/hardware/interfaces/bluetooth/audio/utils/session/BluetoothAudioSupportedCodecsDB.cpp`）：

**(1) 能力表**：`GetOffloadCodecCapabilities(SessionType)` @ `0x16bf4`，用**字节**跳转表 `0x8418`（`base = 0x16d08`，`target = base + v*4`）对 `codecType (≤0x20)` 分派到 6 个能力构造器：

| codecType | 表项 | 目标 | 调用的构造器 |
|---|---|---|---|
| 1 | 0x18 | 0x16d68 | `Capabilities::sbcCapabilities(SbcParameters@0x84e4)` |
| 2 | 0x21 | 0x16d8c | `Capabilities::aacCapabilities(AacParameters@0x84f0)` |
| 4 | 0x26 | 0x16da0 | `Capabilities::aptxCapabilities(AptxParameters@0x8504)` |
| 8 | 0x2a | 0x16db0 | `Capabilities::aptxCapabilities(AptxParameters@0x850c)` |
| 16 | 0x00 | 0x16d08 | `Capabilities::ldacCapabilities(LdacParameters@0x84fc)` |
| **32 (0x20)** | **0x1d** | **0x16d7c** | **`Capabilities::lhdcCapabilities(LhdcParameters@0x8514)`** |
| 其它 | 0x0d | 0x16d3c | 空能力（默认构造） |

6 个条目 ↔ 日志 "supports 6 codecs" 精确吻合。

**(2) 卸载校验表**：`IsOffloadCodecConfigurationValid(SessionType, CodecConfiguration)` @ `0x174c8`，
**uint16** 跳转表 `0x843e`（`base = 0x175a8`，`target = base + v*4`）：

| codecType | 表项 | 目标 | 分支行为 |
|---|---|---|---|
| 0,3,5..15,17..31 | 0x0000 | 0x175a8 | `mov w0,wzr; ret` → **return false** |
| 1 | 0x0015 | 0x175fc | 要求 `CodecSpecific` 判别子 == 0 → `sbcConfig()` 校验 |
| 2 | 0x00cd | 0x178dc | 要求判别子 == 1 → `aacConfig()` 校验 |
| 4 | 0x0131 | 0x17a6c | 要求判别子 == **3** → `aptxConfig()` 校验（APTX） |
| 8 | 0x0028 | 0x17648 | 要求判别子 == **3** → `aptxConfig()` 校验（APTX_HD） |
| 16 | 0x0077 | 0x17784 | 要求判别子 == **2** → `ldacConfig()` 校验 |
| **32 (0x20)** | **0x0001** | **0x175ac** | **直接落到 epilogue，返回 w0（编译期被提升到分派前的 `mov w0,#1`）= return true，不做任何参数校验** |

> `mov w0, #1` 出现在 `0x175e0`（分派之前），正是因为存在一个"直接返回 true"的 case —— 即 **LHDC 在卸载通路上被无条件放行**。

**由此还可反推 `CodecSpecific` union 判别子顺序**：`0=sbcConfig, 1=aacConfig, 2=ldacConfig, 3=aptxConfig, (4=lhdcConfig)`（由上面"要求判别子==3 却调用 aptxConfig"、"==2 却调用 ldacConfig"确定）。

**独立交叉验证（栈侧）**：`libbluetooth_jni_orig.so` 的 `A2dpLhdcV3ToHalConfig` @ `0x82a8b0`：

```asm
0x82a928  mov      w8, #0x20                     ; HIDL codecType = 32 = LHDC
0x82a938  str      w8, [x19], #0xc                ; 写入 CodecConfiguration.codecType，指针 += 0xc
0x82a93c  mov      x0, x19
0x82a940  bl       CodecSpecific::lhdcConfig(LhdcParameters&&)
```
→ 与上表 **32 = LHDC** 完全一致。（源码路径 `.../MiuiBluetooth/system/mediatek/audio_hal_interface/hidl/codec_status_hidl.cc:494`）

### 3.2 未知 codec_type 的行为

| 通路 | 行为 |
|---|---|
| **软件**（`A2DP_SOFTWARE_ENCODING_DATAPATH`，本机实际使用） | **完全忽略**。`A2dpSoftwareAudioProvider::startSession` @ `0x1b2e4` 只做两件事：① `audioConfig.getDiscriminator()` 必须 == 0（pcmConfig）；② `IsSoftwarePcmConfigurationValid(pcmConfig)`。**从未读取 codecType / codecSpecific** |
| **卸载**（`A2DP_HARDWARE_OFFLOAD_DATAPATH`） | 表项落 0x175a8 → **return false**；并打一条 ERROR 级日志：`IsOffloadCodecConfigurationValid: Unsupported Codec Configuration=<cfg>`（`LogMessageCtor(file, line=0x180, severity=4, tag="MediatekBTAudioProviderSessionCodecsDB")`）→ 随后 `A2dpOffloadAudioProvider::startSession` 返回 FAILURE。**不是崩溃、不是忽略** |

`A2dpOffloadAudioProvider::startSession` @ `0x18418` 反汇编（`raw/r3_off_provider_start.txt`）：
```
0x018458  bl  AudioConfiguration::getDiscriminator()
0x018460  cmp w8, #1                    ; 必须是 codecConfig
0x01847c  bl  IsOffloadCodecConfigurationValid(V2_2::SessionType, V2_1::CodecConfiguration)
0x018480  tbz w0, #0, #0x184bc          ; false → 失败路径
```

---

## 4. (c) 它用 lhdcConfig 的哪些字段？

### 4.1 HAL / session 库对 `lhdcConfig()` 的全部调用点

用 `r3_callsites.py` 扫描 `.text` 中所有 `bl` 到 `CodecSpecific::lhdcConfig()` PLT 桩的调用：

| 文件 | 调用点 | 上下文 |
|---|---|---|
| `hal22.so` | `0x14358` | `adrp x1, ".lhdcConfig = "` + `string::append` **之后**取指针 → 纯日志 |
| | `0x190ac` | 同上（".lhdcConfig = "） |
| | `0x1bbfc` | 同上 |
| | `0x206b4` | 同上 |
| `hl_libbluetooth_audio_session_mediatek.so` | `0xb19c` | 同上（`string::append` 之后） |
| | `0x13f64` | 同上 |
| | `0x18688` | 同上 |

7/7 全部在**调试字符串拼接**（`AudioConfiguration` 的 toString）里，无一参与任何判定或参数下发。

### 4.2 软件通路实际使用的字段：只有 `pcmConfig`（**运行时日志直接证实**）

设备日志里 HAL 自己把收到的 `AudioConfiguration` 打了出（`artifacts/logs/lhdc_param.log`）：

```
I/MediatekBTAudioProviderSession(17108): OnSessionStarted - SessionType=A2DP_SOFTWARE_ENCODING_DATAPATH,
   AudioConfiguration={.pcmConfig = {.sampleRate = RATE_96000, .channelMode = STEREO,
                      .bitsPerSample = BITS_24, .isLowLatencyEnabled = Disabled}}
I/MediatekBTAudioProviderSession(17108): OnSessionStarted - SessionType=A2DP_SOFTWARE_ENCODING_DATAPATH,
   AudioConfiguration={.pcmConfig = {.sampleRate = RATE_48000, ...}}
I/MediatekBTAudioProviderA2dpSoftware(17108): startSessionstart session
```

→ 判别子是 **pcmConfig**（不是 codecConfig），字段集 = `{sampleRate, channelMode, bitsPerSample, isLowLatencyEnabled}`。
**96 kHz / 24 bit / 立体声就是这条通路实际跑出来的参数**（与项目文档 §5.3 的速率实测一致）。

反汇编侧的字段读取（`BluetoothAudioPortOut::LoadAudioConfig` @ `audio.bluetooth.default.so 0x19c90`，1212 B，`raw/r3_LAC_out.txt`）：

`BluetoothAudioPortOut::LoadAudioConfig(audio_config*)` @ `audio.bluetooth.default.so 0x19c90`（1212 B，`raw/r3_LAC_out.txt`）：

```asm
0x019cf4  bl  V2_2::AudioConfiguration::getDiscriminator()
0x019cf8  tst w0, #0xff
0x019cfc  b.eq #0x19d1c                 ; 判别子==0 → pcmConfig 分支
0x019d20  bl  V2_2::AudioConfiguration::pcmConfig()
0x019d24  mov x20, x0
0x019d3c  ldr w8, [x20]                 ; +0 sampleRate（位掩码）
0x019d54  cmp w8, #0x7f / b.gt ...      ; 64 项跳转表 @0x40e4 → 具体 Hz
0x019df8  ldrb w8, [x20, #4]            ; +4 单字节字段（16/24/32 bit 之一）
0x019e10  str  w9, [x19, #4]            ; audio_config->format
0x019e14  ldrb w9, [x20, #5]            ; +5 单字节字段（单声道/立体声之一）
0x019e2c  str  w8, [x19, #8]            ; audio_config->channel_mask
```
（+4 / +5 两个单字节字段与运行时日志里的 `bitsPerSample` / `channelMode` 对应；二者在结构体里的先后顺序
两种解读都能自洽，本文不据此下结论 —— 结论只依赖"**HAL 只读这三个字段，且全部来自 pcmConfig**"。）

跳转表实测映射（`sampleRate` 字段是 **btav 位掩码**，不是 HIDL AudioSampleRate 枚举）：

| 字段值 | Hz | 字段值 | Hz |
|---|---|---|---|
| 0x1 | 44100 | 0x20 | **192000** |
| 0x2 | 48000 | 0x40 | 16000 |
| 0x4 | 88200 | 0x80 | 24000 |
| 0x8 | 96000 | 0x100 | 8000 |
| 0x10 | **176400** | 0x200 | 32000 |
| 其它 | 44100（默认） | | |

**结论**：HAL 的功能性输入只有 `pcmConfig.{sampleRate, bitsPerSample, channelMode}`。
`lhdcConfig` 对 HAL 而言**纯粹是日志里的一个字段**。

### 4.3 卸载通路用的字段

`IsOffloadCodecConfigurationValid` 的每个 codec 分支只读 `{uint32 sampleRate; uint8 bitsPerSample; uint8 channelMode; ...}` 这三项（例如 LDAC 分支 `ldr w8,[x0] / ldrb w9,[x0,#4] / ldrb w11,[x0,#5]`，SBC 分支同形）。
**没有 LHDC 分支** → `lhdcConfig` 在卸载通路也不被读取。

### 4.4 顺带确定：HIDL `LhdcParameters` 只有 4 个字段、**无版本号**

由 `A2dpLhdcV3ToHalConfig`（`0x82a9d0`–`0x82aa48`）写入过程反推（`raw/r3_lhdcv3tohal.txt`）：

```asm
0x82a9fc  str  w8, [sp, #8]      ; +0x0  uint32 sampleRate（位掩码，单 bit 校验）
0x82aa14  strb w9, [sp, #0xc]    ; +0x4  uint8  channelMode  (1=MONO, 2=STEREO)
0x82aa40  strb w8, [sp, #0xd]    ; +0x5  uint8  bitsPerSample(1=16,2=24,4=32)
0x82a960  strb w20,[sp, #0xe]    ; +0x6  uint8  isLLEnabled  (current_codec.codec_specific_2 & 1)
0x82aa38  add  x1, sp, #8
0x82aa44  bl   CodecSpecific::lhdcConfig(const LhdcParameters&)
```
→ `LhdcParameters` = **8 字节**：`sampleRate / channelMode / bitsPerSample / isLLEnabled`。
**没有 LHDC 版本字段、没有码率字段、没有 AR/LOSSLESS/JAS/META 等 V5 特性位。**

**这就是"伪装"的根本原因**：HIDL 结构体在物理上无法区分 V3 与 V5，也无法承载 V5 独有参数。
（补充证据：`hl_vendor.mediatek.hardware.bluetooth.audio@2.2.so` 中 `lhdcv5` 字符串计数 = **0**。）

---

## 5. (d) PCM 数据通路（谁 openOutputStream / 如何协作 / 数据方向）

### 5.1 参与方与所在进程

| 组件 | 文件 | 进程 |
|---|---|---|
| BT 协议栈 | `/apex/com.android.btservices/lib64/libbluetooth_jni.so` | `com.android.bluetooth`（pid 2688） |
| HIDL HAL 提供者（工厂+provider） | `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so` | `android.hardware.audio.service.mediatek`（pid 1006） |
| "bluetooth" 音频 HAL 模块（A2DP 输出流） | `/vendor/lib64/hw/audio.bluetooth.default.so` | 同上（pid 1006） |
| session 库（FMQ 持有者/写者） | `/vendor/lib64/libbluetooth_audio_session_mediatek.so` | 同上（pid 1006） |

### 5.2 建立会话（控制面）

```
BT 栈 (libbluetooth_jni.so)
  │ ① IBluetoothAudioProvidersFactory(2.2)::openProvider(A2DP_SOFTWARE_ENCODING_DATAPATH)
  ├────────────────────────────────────────────► hal22.so (pid 1006)
  │ ② provider->startSession_2_1(hostIf = 栈侧 IBluetoothAudioPort 实现, audioConfig)
  ├────────────────────────────────────────────► A2dpSoftwareAudioProvider::startSession @0x1b2e4
  │                                                  │ 校验 getDiscriminator()==0 且 IsSoftwarePcmConfigurationValid
  │                                                  │ MessageQueueBase ctor → 创建 FMQ
  │                                                  │ BluetoothAudioSession_2_1::OnSessionStarted(hostIf, mqDesc, cfg)
  │                                                  │   （同进程内调用 libbluetooth_audio_session_mediatek.so）
  │ ③ _hidl_cb(Status, MQDescriptor)  ← FMQ 描述符回传
  │◄────────────────────────────────────────────
  │
  │ ④ AudioFlinger 打开 BT A2DP 输出流
  │      AudioPolicyManager → openOutputWithProfileAndDevice
  │      → audio.bluetooth.default.so : adev_open_output_stream
  │      → BluetoothAudioPortOut::SetUp(device) @0x17230 → init_session_type() @0x175ec
  │      → BluetoothAudioSessionInstance_2_1::GetSessionInstance(sessionType)   [PLT 0x1df80]
  │      → IsSessionReady()  ← 若 ② 未成功，这里就是日志里那句
  │           "BTAudioHalDeviceProxy: init_session_type: ... is not ready"
  │      → LoadAudioConfig(&audio_config) @0x19c90  ← 把 pcmConfig 变成采样率/格式/声道
  │
  │ ⑤ HAL → 栈 回调（控制）：IBluetoothAudioPort::startStream / suspendStream / stopStream
  │      BluetoothAudioPort::Start @0x1b430 → BluetoothAudioSession::StartStream [PLT 0x1e130]
```

### 5.3 PCM 数据面（FMQ，不是 streamOut）

```
应用 / AudioTrack
   ↓ (AudioFlinger 混音后写入 A2DP 输出流)
audio.bluetooth.default.so : out_write()
   ↓
BluetoothAudioPortOut::WriteData(buf,len) @0x1c620
   ↓ (内部 0x1c710)
BluetoothAudioSessionInstance_2_1::GetSessionInstance(A2DP_SOFTWARE_ENCODING_DATAPATH)  [PLT 0x1df80]
BluetoothAudioSession_2_1::GetAudioSession()                                            [PLT 0x1dfb0]
BluetoothAudioSession::OutWritePcmData(buf,len) @0xf044
   ↓
MessageQueueBase<MQDescriptor<uint8_t>>::write(buf,len) @0xf210
   ↓
============= FMQ（fast message queue，共享内存） =============
   ↓
BT 栈 libbluetooth_jni.so : MessageQueueBase<MQDescriptor<uint8_t>>::read(...)   ← 已导入（见下）
   ↓ LHDC V5 编码 → L2CAP → 耳机
```

**方向证据**（`libbluetooth_jni_orig.so` 的动态符号表）：

```
_ZN7android16MessageQueueBaseINS_8hardware12MQDescriptorEhLNS1_8MQFlavorE1EE4readEPhm    ← 栈侧 read
_ZN7android16MessageQueueBaseINS_8hardware12MQDescriptorEhLNS1_8MQFlavorE1EE5writeEPKhm  ← 反向（LE/HA 输入用）
_ZN7android16MessageQueueBaseINS_7details20AidlMQDescriptorShimEaLNS_8hardware8MQFlavorE1EE4readEPam  ← AIDL 变体（本机未用）
```

**明确否证**：**不存在** `IBluetoothAudioHost::streamOut` 调用。那是 AOSP HIDL 2.0 时代的旧接口名；
本机（vendor HIDL 2.1/2.2）的控制接口叫 `IBluetoothAudioPort`（`startStream/suspendStream/stopStream/getPresentationPosition`），
**PCM 数据面完全走 FMQ**，HIDL 调用里没有音频数据。

### 5.4 两个库的分工（问题原文所问）

| 库 | 角色 | 证据 |
|---|---|---|
| `audio.bluetooth.default.so` | "bluetooth" 音频 HAL 模块（`audio_hw_device`），**PCM 生产者**：`out_write` → `WriteData` → FMQ 写 | 导入 `BluetoothAudioSession::OutWritePcmData`、`BluetoothAudioPortOut::WriteData`、`BluetoothAudioPort::init_session_type`、`adev_open_output_stream`；导出 `HMI`（HAL 模块信息结构） |
| `libbluetooth_audio_session_mediatek.so` | **会话/FMQ 封装库**，被上面两个库共用：持 FMQ、提供 `OutWritePcmData/InReadPcmData`、`UpdateAudioConfig`、`OnSessionStarted`、`StartStream/StopStream`、`GetPresentationPosition` | 定义 `BluetoothAudioSession`、`BluetoothAudioSession_2_1`、`BluetoothAudioSessionInstance(_2_1)`、`PortStatusCallbacks` |
| `hal22.so` | HIDL provider：**创建 FMQ**、调用同进程的 `OnSessionStarted`、把 `MQDescriptor` 回传栈、转发控制回调 | 导入 `BluetoothAudioSession_2_1::OnSessionStarted`、`MessageQueueBase` 构造 |

> 关键点：**HAL provider 与音频 HAL 模块在同一进程（pid 1006）**，所以 FMQ 的"创建方"与"写入方"是同进程的两个组件，通过 `libbluetooth_audio_session_mediatek.so` 的进程内单例耦合；而 FMQ 的**读取方**在 BT 栈进程。

**运行时日志逐步佐证**（`artifacts/logs/lhdc_param.log`，pid 17108 = 音频 HAL 服务）：

```
MediatekBTAudioProviderA2dpSoftware: startSessionstart session                 ← ② 软件 provider 进入
MediatekBTAudioProviderSession:      OnSessionStarted - SessionType=A2DP_SOFTWARE_ENCODING_DATAPATH,
                                     AudioConfiguration={.pcmConfig = {.sampleRate = RATE_96000, ...}}
                                                                               ← ② OnSessionStarted 拿到 pcmConfig
BTAudioHalDeviceProxy:               SetUp: session_type=A2DP_SOFTWARE_ENCODING_DATAPATH, cookie=0x100
                                                                               ← ④ 音频 HAL 模块建流
DeviceHAL:                           openOutputStreamCore, flags: 0, open_output_stream success
BTAudioHalDeviceProxy:               Start: session_type=A2DP_SOFTWARE_ENCODING_DATAPATH, ... request
MediatekBTAudioProviderSession:      ReportControlStatus - status=SUCCESS ... started   ← ⑤ startStream 回调
BTAudioHalDeviceProxy:               control_result_cb: ... status=SUCCESS, start_rsp=1
```

---

## 6. (e) 是否只支持 HIDL？有无 AIDL 实现？

### 6.1 设备上的 AIDL 资产盘点

```
$ adb shell su -c 'ls -l /apex/com.android.btservices/lib64/'
-rw-r--r-- system system 188040  vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so     ← 仅接口
-rw-r--r-- system system 183792  android.hardware.bluetooth.audio-V3-ndk.so            ← AOSP AIDL 接口
-rw-r--r-- system system 16729080 libbluetooth_jni.so
（HIDL：android.hardware.bluetooth.audio@2.0.so / @2.1.so、vendor.mediatek...@2.1.so / @2.2.so）
```

`vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`（已 pull 到 `raw/`）的符号表证明它是**完整的 AIDL 接口**，且**含 V5 类型**：

```
aidl::vendor::mediatek::hardware::bluetooth::audio::IBluetoothAudioProviderFactory{Default}
aidl::...::IBluetoothAudioProvider{Default}
aidl::...::IBluetoothAudioPort{Default}
aidl::...::Lhdcv5Configuration::{readFromParcel,writeToParcel,descriptor}
aidl::...::Lhdcv5Capabilities::{readFromParcel,writeToParcel,descriptor}
aidl::...::Lhdcv2Configuration::{...}
aidl::...::CodecConfiguration::CodecSpecific / VendorConfiguration
aidl::...::CodecCapabilities::Capabilities / VendorCapabilities
```

### 6.2 但**没有实现**

| 检查 | 结果 |
|---|---|
| `adb shell service list` | 339 个服务中**没有任何** bluetooth audio AIDL 服务（只有 `bluetooth_manager`）；对照可见 `vendor.mediatek.framework.mtksf_ext.IMtkSF_ext/default`、`vendor.xiaomi.hardware.mrm.IMrm/default` 等厂商 AIDL HAL 确实会出现在列表里 → 说明"看不到"不是权限过滤 |
| `/vendor/etc/vintf/manifest.xml` | `format="aidl"` 出现 **0 次** |
| `/vendor/lib64`、`/vendor/lib64/hw` 全列表 | 无任何 `*bluetooth.audio*ndk*` / `*-V*-ndk.so` 实现库 |
| `lshal` | 无 AIDL 段中的 bluetooth 条目 |

### 6.3 栈侧的双路径

`com.android.bluetooth` 的 maps 同时包含 HIDL 代理和两个 AIDL 接口库：

```
/apex/com.android.btservices/lib64/vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so
/apex/com.android.btservices/lib64/android.hardware.bluetooth.audio-V3-ndk.so
/apex/com.android.btservices/lib64/vendor.mediatek.hardware.bluetooth.audio@2.1.so
/apex/com.android.btservices/lib64/vendor.mediatek.hardware.bluetooth.audio@2.2.so
```

启动日志（`artifacts/logs/lhdc_param.log:8239-8240`）显示栈**先探 AIDL 再回退 HIDL**：

```
I/droid.bluetooth: [hal_version_manager.cc(141)] HalVersionManager: aidl vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default
I/droid.bluetooth: [hal_version_manager.cc(155)] HalVersionManager: hidl vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory
...
I/bt_stack: [hal_version_manager.cc(107)] V2_1::IBluetoothAudioProvidersFactory::getService() returned 0x... (remote)
```
→ **最终走 HIDL**。栈侧存在 `A2dpLhdcv5ToHalConfig`（AIDL 版，`0x83fd80` / `0x870b80`）但**在设备上是死代码**。

### 6.4 结论

**该厂商 HAL 只有 HIDL 实现。** AIDL 只在 APEX 里留了接口库（供跨机型共享的协议栈链接用），
本机型没有对应的 AIDL 服务 → **无法通过"切到 AIDL 通路"获得 `Lhdcv5Configuration`**。
（这同时印证了调查报告"白名单 5 机型才带 AIDL HAL"的推断。）

---

## 7. (f) 要支持 LHDC V5 的最小改动 & 可替换性

### 7.1 先明确：软件通路下 HAL 侧**零改动**

本机实际走 `A2DP_SOFTWARE_ENCODING_DATAPATH`（日志 `BTAudioHalDeviceProxy: SetUp: session_type=A2DP_SOFTWARE_ENCODING_DATAPATH, cookie=0x100`），
而该通路下 HAL 只消费 `pcmConfig`（§4.2），**与 codec 完全无关**。
因此：

- "让 HAL 支持 codec_type=12 / Lhdcv5Configuration" **在软件通路上不是前置条件**。
  现有 P0/P1/P2 伪装之所以能出声且能到 96 kHz，正是因为 HAL 不关心 codec。
- 现有实现唯一"不干净"的地方是 **栈侧**：V5 被强行喂给 V3 转换器（P2），且 `codec_type` 被改写。
  但它写到 HIDL 结构里的 `codecType` 仍然是 **32 = LHDC**（§3.1 已验证），
  `lhdcConfig` 里也只有 sampleRate/channelMode/bitsPerSample/isLLEnabled —— **对 HAL 而言与真实 V3 无区别**。

### 7.2 若要"V5 通路"（不伪装），缺口清单

| 层 | 需要什么 | 本机可行性 |
|---|---|---|
| 栈（`libbluetooth_jni.so`，APEX） | 一个 HIDL 版的 `A2dpLhdcv5ToHalConfig`（现只有 AIDL 版），或让 `a2dp_get_selected_hal_codec_config` 原生认识 `codec_type=12`。**但由于 HIDL `LhdcParameters` 无版本字段（§4.4），即使这么做，送到 HAL 的结构与 V3 逐字节同构** | 只能内存补丁 |
| HIDL 接口（`vendor.mediatek...@2.2`） | 新增 `Lhdcv5Configuration` 结构 + 新版本号 → 需要厂商出新 `.hal` + 新 `.so` | **第三方不可行** |
| HAL 实现 | 软件通路：**不需要**；卸载通路：`IsOffloadCodecConfigurationValid` 对 codecType=32 已无条件放行（§3.1），**也不需要** | — |
| 音频策略 | 软件通路 ≤96 kHz 无需改动；192 kHz 需改 `samplingRates`（见 §8） | 可改（/vendor 只读，见 7.3） |
| 卸载通路启用 | `persist.bluetooth.a2dp_offload.cap` 需含 LHDC；`audio_policy_configuration.xml` primary 模块的 `BT A2DP Out` `encodedFormats` 需加 LHDC | 属性可改；xml 只读 |

**要点**：所谓"HAL 支持 V5"在本机型上是一个**伪需求** —— 瓶颈是 HIDL 结构体没有 V5 字段，
而不是 HAL 不认 V5。因此"不伪装"的可行形态只能是 **栈侧原生 V5 分支 + HIDL 仍传 LHDC(32)+8 字节 lhdcConfig**，
即：**在 HIDL 链路上，V3 与 V5 在结构上必然同形，"伪装"无法被完全消除**。

### 7.3 该文件在 APEX 还是 /vendor？能否替换/打补丁？

**在 `/vendor`，不在 APEX**（`/apex/com.android.btservices/` 只有接口 .so 与 `libbluetooth_jni.so`）。

存储与完整性状态（`raw/19_mounts.txt`、`raw/20_dm_names.txt`、`raw/21_verity_props.txt`）：

```
/dev/block/dm-12 on /vendor type erofs (ro,seclabel,relatime,...)
dm-12: vendor-verity            ← dm-verity 保护
ro.boot.verifiedbootstate = green
ro.boot.flash.locked      = 1
ro.boot.vbmeta.device_state = locked
ro.boot.veritymode        = enforcing
```
→ **磁盘文件不可改**（erofs ro + dm-verity + 锁 BL + green）。

**但运行时替换是可行的，且比 BT 进程侧更有利**：

```
/proc/1/ns/mnt    -> mnt:[4026533766]
/proc/1006/ns/mnt -> mnt:[4026533766]      ← 音频 HAL 服务 = init 的 mount namespace！
/proc/2688/ns/mnt -> mnt:[4026535972]      ← com.android.bluetooth 是独立 namespace
```

- `android.hardware.audio.service.mediatek`（pid 1006）与 **init 同一挂载命名空间**，
  SELinux 域 `u:r:mtk_hal_audio:s0`，库文件标签 `u:object_r:vendor_file:s0`。
- 因此**用 KernelSU 模块在 `post-fs-data` 阶段 bind-mount 覆盖
  `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so`（或 `audio.bluetooth.default.so`）
  对该服务是可见的** —— 这与调查报告里"BT 进程侧 bind-mount 被 Zygisk Next 还原挂载剥离"的困境**不同**
  （BT 进程是 zygote fork 的应用进程；音频 HAL 是 init 直接 fork 的原生服务，不在 Zygisk 管辖内）。
- 注意事项：
  1. 挂载必须在 `hal` 类服务启动前完成（`post-fs-data` 早于 `boot`/`late_start`，满足）。
  2. 源文件在 `/data` 下，mount 后标签会变成 data 类标签，`mtk_hal_audio` 读会被 SELinux 拒绝 →
     需 `sepolicy.rule` 或 `mount --context=u:object_r:vendor_file:s0`。
  3. 需 `resetprop`/重启 `init.svc` 让服务重新加载（或开机即生效）。
- 备选：直接对 pid 1006 做进程内注入（ptrace/LD_PRELOAD 式）。Zygisk 不适用（非 zygote 应用）。

---

## 8. (g) 是否支持 192 kHz？AUDIO_FORMAT_LHDC 的采样率上限在哪定义？

### 8.1 结论：**不支持 192 kHz**，三道独立闸门

**闸门 1 —— 音频策略声明（PCM 侧）**

`/vendor/etc/bluetooth_offload_audio_policy_configuration.xml`（`raw/16_bt_offload_policy.xml`）：

```xml
<module name="bluetooth" halVersion="2.0">
  <devicePort tagName="BT A2DP Out" type="AUDIO_DEVICE_OUT_BLUETOOTH_A2DP" role="sink"
      encodedFormats="AUDIO_FORMAT_LDAC AUDIO_FORMAT_LHDC AUDIO_FORMAT_LHDC_LL AUDIO_FORMAT_APTX AUDIO_FORMAT_APTX_HD">
    <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
             samplingRates="44100 48000 88200 96000"        ← 上限 96000
             channelMasks="AUDIO_CHANNEL_OUT_STEREO"/>
  </devicePort>
  （Headphones / Speaker 同上）
```
该文件由 `/vendor/etc/audio_policy_configuration.xml:328` 的 `xi:include` 引入。

另：`audio_policy_configuration.xml` 的 **primary 模块**（L46–L325）里另有一组 `BT A2DP Out`
（L200–208），`encodedFormats="AUDIO_FORMAT_SBC AUDIO_FORMAT_AAC"`、PCM `samplingRates="44100 48000"`
—— 对应 `persist.bluetooth.a2dp_offload.cap = sbc-aac` 的卸载能力划分。

**闸门 2 —— HAL 的软件 PCM 参数校验（决定性）**

`IsSoftwarePcmConfigurationValid` @ `hl_libbluetooth_audio_session_mediatek.so 0x16e30`（V2_1，源码 `.../BluetoothAudioSupportedCodecsDB.cpp`）：

```asm
0x016e58  ldr   w8, [x0]              ; sampleRate（位掩码）
0x016e5c  sub   w9, w8, #1
0x016e60  cmp   w9, #0x3f
0x016e64  b.hi  #0x16ec4              ; 只处理 sr-1 ≤ 63
0x016e6c  lsl   x9, x10, x9           ; 1 << (sr-1)   ← 单 bit 判定
0x016e74  movk  x10, #0x8000, lsl #48
0x016e78  tst   x9, x10               ; mask = 0x800000000000008b → 允许 bit {0,1,3,7,63}
0x016e7c  b.eq  #0x16ec4
0x016e80  ldrb  w9, [x19, #5]         ; channelMode ∈ {1,2,4}
0x016ea0  ldrb  w9, [x19, #4]         ; bitsPerSample ∈ {1,2}
0x016eb0  mov   w9, #0xcf
0x016eb4  tst   w8, w9                ; (sampleRate & 0xcf) != 0
0x016eb8  b.eq  #0x16f0c              ; → "Unsupported PCM Configuration"
0x016ec4  cmp   w8, #0x80             ; 例外：允许 0x80
0x016ec8  b.eq  #0x16e80
```
允许的 `sampleRate` 位掩码（`1<<(sr-1)` ∈ mask ∪ {0x80}，且 `sr & 0xcf ≠ 0`）：

> **{0x1, 0x2, 0x4, 0x8, 0x40, 0x80} = {44100, 48000, 88200, 96000, 16000, 24000}**

`IsSoftwarePcmConfigurationValid_2_1` @ `0x1a2f4`（V2_2，`.../BluetoothAudioSupportedCodecsDB_2_1.cpp`）同形，只多放行 `0x100/0x200`（8000/32000），并要求 offset+8 的字段非 0。

**`0x10 (176400)` 与 `0x20 (192000)` 在两个版本里都被拒绝**（`b.eq → 0x16ec4 → cmp #0x80 → 不等 → 0x16ecc 失败路径`）。

调用点：`A2dpSoftwareAudioProvider::startSession` @ `hal22.so 0x1b2e4`：

```
0x01b338  bl  getDiscriminator()  ; 必须 == 0
0x01b3c8  bl  AudioConfiguration::pcmConfig()
0x01b3cc  bl  IsSoftwarePcmConfigurationValid(V2_1::PcmParameters)
0x01b3d0  tbz w0, #0, #0x1b3f8    ; false → 打 " - Unsupported PCM Configuration=" 并失败
```

（`IsSoftwarePcmConfigurationValid_2_1`（V2_2 版）在 hal22.so 里只有 1 个调用点 `0x1f978`，
位于 `LeAudioAudioProvider::startSession_2_1`；A2DP 软件通路用的是 **V2_1 版**。两版对 0x10/0x20 的拒绝一致。）

**入口点确认**（运行时日志）：`MediatekBTAudioProviderA2dpSoftware: startSessionstart session`
（源码 `.../bluetooth/audio/2.2/default/A2dpSoftwareAudioProvider.cpp:78`）——软件会话确实由该类处理。

**闸门 3 —— HAL 对外声明的 PCM 能力**

`GetSoftwarePcmCapabilities_2_1` @ `0x1a244` 返回 `.rodata 0x8580` 的 12 字节常量：

```
cf 03 00 00 | 03 | 07 | 00 00 | 00 00 00 00
 sampleRate=0x3cf  bits=0x3  ch=0x7   (offset+8)=0
```
`0x3cf` = bit{0,1,2,3,6,7,8,9} = 44100|48000|88200|96000|16000|24000|8000|32000
→ **能力宣告里就没有 176400 / 192000**。

### 8.2 `AUDIO_FORMAT_LHDC` 相关采样率上限"定义在哪"

| 层 | 位置 | 内容 |
|---|---|---|
| 音频策略 | `bluetooth_offload_audio_policy_configuration.xml` 的 A2DP devicePort `profile/@samplingRates` | `44100 48000 88200 96000`（软件/卸载共用的 PCM 通道上限） |
| HAL 校验 | `BluetoothAudioSupportedCodecsDB(.cpp/_2_1.cpp)` → `IsSoftwarePcmConfigurationValid(_2_1)` | 允许集 = {44100,48000,88200,96000,16000,24000(,8000,32000)} |
| HAL 能力宣告 | 同文件 → `GetSoftwarePcmCapabilities(_2_1)` → 常量 `0x3cf` | 同上 |
| HAL 值映射 | `audio.bluetooth.default.so : BluetoothAudioPortOut::LoadAudioConfig` @`0x19c90`，跳转表 @`0x40e4` | **有** `0x10→176400`、`0x20→192000` 的映射（即"能表达"，只是过不了校验） |
| HIDL 类型 | `LhdcParameters.sampleRate`（位掩码，4 B） | 类型本身不设限 |

> 关于 `encodedFormats`：A2DP devicePort 的 `encodedFormats` 列了
> `AUDIO_FORMAT_LDAC / AUDIO_FORMAT_LHDC / AUDIO_FORMAT_LHDC_LL / AUDIO_FORMAT_APTX / AUDIO_FORMAT_APTX_HD`，
> 但**没有"每格式采样率"子属性**；`AUDIO_FORMAT_LHDC` 的速率上限实际由上面两条 PCM/策略项共同钳死。
> 另注：`encodedFormats` 里**没有**独立的 "LHDC V5" 格式（只有 LHDC 与 LHDC_LL）。

---

## 9. 证据 / 推断 / 未知 分级

### 9.1 已验证事实（命令 + 偏移可复现）

1. 服务与实现体：`lshal` + `ps` + `/proc/1006/maps` + VINTF manifest（§2）。
2. 6 个厂商 .so 的设备/本地 SHA256 一致（§1）。
3. `CodecType` 位枚举 `{SBC=1,AAC=2,APTX=4,APTX_HD=8,LDAC=16,LHDC=32}`：能力表 `0x8418` 与校验表 `0x843e` 双表互证 + 栈侧 `A2dpLhdcV3ToHalConfig` 写 `0x20`（§3.1）。
4. 软件通路不读 codec_type；卸载通路未知 codec_type → `return false` + ERROR 日志（§3.2）。
5. `lhdcConfig` 在 HAL/session 库中 7/7 调用点均为日志拼接（§4.1）。
6. `LhdcParameters` = 8 字节 `{sampleRate, channelMode, bitsPerSample, isLLEnabled}`，无版本字段（§4.4）。
7. PCM 数据面 = FMQ（HAL 写 / 栈读），无 `streamOut`（§5.3，符号表证据）。
8. 设备上无 AIDL 实现（服务表 / VINTF / /vendor 列表三重否定）（§6.2）。
9. `/vendor` = `dm-12 vendor-verity` erofs ro；pid 1006 的 mnt namespace == init 的（§7.3）。
10. 192 kHz 被 `IsSoftwarePcmConfigurationValid(_2_1)` 显式拒绝；能力宣告 `0x3cf` 不含 0x10/0x20；策略 `samplingRates` 上限 96000（§8）。

### 9.2 推断（证据支持但非直接观测）

- `CodecSpecific` 判别子顺序 `0=sbc,1=aac,2=ldac,3=aptx,(4=lhdc)`：由校验分支的 `cmp disc,#N` 与所调 getter 反推（§3.1），未直接观测 union 布局表。
- 卸载通路 codecType=32 走 `0x175ac` 返回 true：该地址落在 epilogue，`w0` 由分派前的 `mov w0,#1` 提供 —— 逻辑自洽，但属"跳进尾声"的编译器产物，**未在设备上实跑验证**。
- `BluetoothAudioPortOut::LoadAudioConfig` 里 `bitsPerSample/channelMode → audio_config->format/channel_mask` 的具体枚举值（观察到 format 取 0 或 3、channel_mask 取 1/3/6），未逐位确认其对应的 AOSP 宏名。
- 本机走软件通路：由 `BTAudioHalDeviceProxy: SetUp: session_type=A2DP_SOFTWARE_ENCODING_DATAPATH` 与 `LoadAudioConfig`(pcmConfig) 推断，未直接抓取 `AudioFlinger` 侧 output 的 format 字段。

### 9.3 未知

- 耳机侧 Redmi Buds 5 Pro 在 192 kHz 下的实际接受行为（本机不可能送达，未测）。
- 若走卸载通路（需改 `persist.bluetooth.a2dp_offload.cap`），LHDC 的 `codecType=32 → return true` 之后 DSP 侧是否能编码 —— 未验证，且本机 `support_lhdc=false`（`/product/etc/device_features/xaga.xml`）。
- `android.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default`（AOSP 包，同样在 pid 1006 注册）是否会在某些条件下被栈选中 —— 日志只显示选了厂商 @2.2，未穷举。

---

## 10. 对既有报告结论的核对与修正

| 既有报告的表述 | R3 复核结论 |
|---|---|
| "厂商侧**不存在 AIDL 实现**（全盘搜索确认），协议栈内的 AIDL 版 V5 代码是死代码" | ✅ **成立**。三重否定：`service list` 无该服务、VINTF 无 `format="aidl"`、/vendor 无 `-ndk` 实现库 |
| "设备走的是 HIDL 链路" | ✅ **成立**。`HalVersionManager` 探 AIDL 后落到 `hidl vendor.mediatek.hardware.bluetooth.audio@2.2` |
| "HIDL 的 `CodecSpecific` 根本没有 V5 字段" | ✅ **成立且更强**：`LhdcParameters` 实测仅 8 字节 `{sampleRate, channelMode, bitsPerSample, isLowLatencyEnabled}`，**连版本字段都没有** |
| "HAL 只有旧版 `lhdcConfig`，**上限 88200 Hz**" | ❌ **不准确**。HAL 里没有任何"LHDC 专用上限"：① 卸载校验函数**根本没有 LHDC 分支**（对 codecType=32 直接放行、不做参数校验）；② 软件通路的 PCM 白名单是 `{44100,48000,88200,96000,16000,24000}`，**含 96000**。卡住 96 kHz 的不是 HAL 而是……并没有卡住（实测 96 kHz 通过）。"88200"这个数字在 HAL 二进制里找不到依据 |
| "**192 kHz 不可能**（策略只声明到 96000）" | ✅ **成立，但理由要补全**：除了策略 `samplingRates`，HAL 的 `IsSoftwarePcmConfigurationValid(_2_1)` 会**显式拒绝** `sampleRate` 位 `0x20`；HAL 能力宣告 `0x3cf` 也不含 0x20 |
| "P2 伪装把 codec_type 12 改写为 10" | ✅ 成立；补充：改写只发生在**栈内部**，写进 HIDL 结构的 `codecType` 仍是 **32 = LHDC**，因此对 HAL 而言伪装前后的配置**逐字节等价**（HAL 不看 codec） |
| "阻断点：HIDL 代次的音频 HAL 接口没有 LHDC V5 结构 → 音频通路无法建立" | ⚠️ **需修正**：通路无法建立的直接原因是**栈侧** `a2dp_get_selected_hal_codec_config` 对 `codec_type=12` 没有分支（`a2dp_encoding_hidl.cc:359`），HAL 侧从未收到过该配置。HAL 的软件通路对 codec 完全无感知，**并不构成阻断** |

---

## 11. 对项目（V5 实现）的直接影响

1. **现状是自洽的**：HAL 在软件通路上与 codec 无关，因此 P0/P1/P2 伪装不会因为"HAL 不认 V5"而失效；96 kHz 能过是因为 `0x8` 恰在 HAL 白名单内。
2. **96 kHz 已是该 HAL 的软件通路天花板**；**192 kHz 在本 HAL 上无解**（除非替换 `libbluetooth_audio_session_mediatek.so`，把 `IsSoftwarePcmConfigurationValid` 的 mask 与 `kSoftwarePcmCapabilities` 常量一起改掉，并同步放开策略 `samplingRates`）。
   - 若要做，这是**唯一**需要动的 HAL 侧函数：`0x16e30`/`0x1a2f4`（校验）+ `.rodata 0x8580`（能力常量）+ `/vendor/etc/bluetooth_offload_audio_policy_configuration.xml`。
   - 且该 .so 在 `/vendor`（非 APEX），可用 bind-mount 替换（§7.3）。
3. **卸载通路反而"天生"接受 LHDC**（codecType=32 无条件放行），若将来要试卸载，瓶颈不在 HAL 而在 `persist.bluetooth.a2dp_offload.cap` 与 `device_features/xaga.xml` 的 `support_lhdc=false`。

---

## 附：原始 dump 索引（`d:/Cache/Hyperos/lhdcv5-tr/analysis/raw/`）

| 文件 | 内容 |
|---|---|
| `01_props_lhdc.txt` | bluetooth/audio 相关属性 |
| `02_lshal.txt` | lshal 全量 |
| `03_vendor_hw.txt` | /vendor/lib64/hw 列表（bluetooth/audio） |
| `04_ps.txt` | ps -A 过滤 |
| `05_vintf_manifest.xml` | /vendor/etc/vintf/manifest.xml |
| `07b_maps_1006_full.txt` | 音频 HAL 服务完整 maps |
| `08_vendor_bt_libs.txt` | /vendor lib64+lib 全 bluetooth 库列表 |
| `09_aidl_vendor.txt` | vendor 侧 AIDL 搜索结果（空） |
| `10_btservices_lib64.txt` | APEX btservices lib64 列表 |
| `13b_servicelist_full.txt` | binder 服务全量 |
| `14_maps_bt_full.txt` | com.android.bluetooth 完整 maps |
| `16_bt_offload_policy.xml` | bluetooth_offload_audio_policy_configuration.xml |
| `17_apm_xml_bt.txt` / `18_a2dp_policy.xml` / `26_apm_modules.txt` | 音频策略相关 |
| `19_mounts.txt` / `20_dm_names.txt` / `21_verity_props.txt` | 挂载 / dm 名 / AVB 状态 |
| `22_device_sha256.txt` | 设备侧 .so 校验值 |
| `23_ns.txt` | mount namespace + SELinux 域/标签 |
| `r3_elfinfo.txt` | 7 个目标 .so 的 SONAME/NEEDED/dynsym 全量 |
| `r3_offload_valid.txt` | `IsOffloadCodecConfigurationValid` 全反汇编 |
| `r3_offload_caps.txt` | `GetOffloadCodecCapabilities` 全反汇编 |
| `r3_swpcm_v21.txt` / `r3_swpcm_v22.txt` | 软件 PCM 校验（V2_1 / V2_2） |
| `r3_LAC_out.txt` | `BluetoothAudioPortOut::LoadAudioConfig` 全反汇编 |
| `r3_sw_provider_start.txt` / `r3_off_provider_start.txt` | 两个 provider 的 startSession |
| `r3_updatecfg.txt` | `UpdateAudioConfig`（V2_1/V2_2） |
| `r3_lhdcv3tohal.txt` | 栈侧 `A2dpLhdcV3ToHalConfig` |
| `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so` / `android.hardware.bluetooth.audio-V3-ndk.so` | APEX 内 AIDL 接口库 |
