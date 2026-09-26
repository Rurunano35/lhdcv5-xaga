# R1 — AOSP Android 14 蓝牙音频 HIDL 编码路径源码调查

> 调查日期：2026-09-25
> 目标分支：`android14-release`（= UP1A.231005.007 / android-14.0.0_r*）+ `android14-qpr3-release`
> 设备：Redmi Note 11T Pro (xaga / MT6805…) → MT6895，HyperOS OS2.0.12.0.ULOCNXM
> 方法：android.googlesource.com `?format=TEXT`（base64）原文落盘 + 本地 grep/diff + 与设备二进制反汇编对撞
> 落盘目录：`d:/Cache/Hyperos/lhdcv5-tr/reference/aosp-src/`

---

## 0. 三条最重要的纠正（推翻既有报告的隐含前提）

| # | 既有文档的说法 | 实测 | 证据 |
|---|---|---|---|
| 1 | 任务描述称路径为 `system/audio_hal/`，文件 `BluetoothAudioHalVersion.h` / `BluetoothAudioHal.cpp` | **AOSP 14 不存在这两个文件**，目录名是 `system/audio_hal_interface/`（HIDL 实现在 `.../hidl/`、AIDL 在 `.../aidl/`） | 递归遍历整个 Bluetooth 仓库（android14-release）匹配 `^BluetoothAudioHal.*` → **0 命中**；且 10/11/12/13/14/main 各分支直接探测均 404 |
| 2 | 「HIDL `CodecConfiguration::CodecSpecific` 唯一 LHDC 字段是 `lhdcConfig`」暗示这是 AOSP 定义 | **AOSP 14 的 HIDL `CodecSpecific` 只有 4 个成员，连 `lhdcConfig` 都没有**；`lhdcConfig` 是 MTK fork 加的 | `2.0/types.hal:240-245` 原文；设备符号 `_ZN6vendor8mediatek…V2_118CodecConfiguration13CodecSpecific10lhdcConfigE…` |
| 3 | 任务描述假设存在 `hardware/interfaces/bluetooth/audio/2.2/` | **AOSP 14 蓝牙音频 HIDL 只有 2.0 和 2.1，没有 2.2** | `bluetooth/audio/` 目录列表 = `2.0 / 2.1 / aidl / utils / OWNERS`；设备 VINTF 里 `@2.2` 属于 `vendor.mediatek.hardware.bluetooth.audio` |

**并且：AOSP 14 的蓝牙音频代码里 `lhdc` 出现次数 = 0（大小写不敏感，HIDL 与 AIDL 两侧都是）。**
LHDC 在这台设备上 100% 是 MediaTek/Xiaomi 的私有扩展。

```
$ grep -rn -i lhdc reference/aosp-src/android14-release/packages_modules_Bluetooth/system/audio_hal_interface/ | wc -l
0
```

旁证：AOSP 14 的 A2DP vendor codec 目录 `system/stack/a2dp/` 只有
`a2dp_vendor_{aptx,aptx_encoder,aptx_hd,aptx_hd_encoder,ldac,ldac_decoder,ldac_encoder,opus,opus_decoder,opus_encoder}.cc`
—— **没有 lhdc**。设备里的 `MiuiBluetooth/system/stack/a2dp/a2dp_vendor_lhdcv5.cc` 是小米/MTK 新增的。

---

## 1. 源码获取方式（可复现）

```
https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/heads/android14-release/<path>?format=TEXT
https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/android14-release/<path>?format=TEXT
```

- `android14-release` 蓝牙模块 commit = `cbb30d721ad3ec9550fc4fbcffd0c94c55e9acb1`
- `android14-release` hardware/interfaces commit = `40e9f1537e308ed49e3b561ce333e3f2bb64f31e`
- `android14-qpr3-release` hardware/interfaces commit = `5ecadeb354186260fbf2cb223eb712c79b640119`

脚本：`analysis/scripts/fetch.py`（单文件）、`batch.py`（批量）、`walk.py`（递归树遍历）、`xref_imm.py`（adrp+add 绝对地址交叉引用）、`xref_bl.py`、`pltres.py`（PLT→符号）、`syms2.py`、`disa.py`（注意不要命名为 `dis.py`，会与标准库冲突）。

> **陷阱**：gitiles 列目录时路径**必须以 `/` 结尾**，否则 404。文件路径不需要。

---

## (a) HIDL 的 CodecConfiguration / CodecSpecific / LhdcConfiguration 完整字段定义

### AOSP HIDL 2.0 — `hardware/interfaces/bluetooth/audio/2.0/types.hal`

```hal
enum CodecType : uint32_t {          // 位掩码（bitfield）
    UNKNOWN = 0x00,
    SBC     = 0x01,
    AAC     = 0x02,
    APTX    = 0x04,
    APTX_HD = 0x08,
    LDAC    = 0x10,
};

enum SampleRate : uint32_t {
    RATE_UNKNOWN = 0x00, RATE_44100 = 0x01, RATE_48000 = 0x02, RATE_88200 = 0x04,
    RATE_96000   = 0x08, RATE_176400 = 0x10, RATE_192000 = 0x20,
    RATE_16000   = 0x40, RATE_24000  = 0x80,
};

enum BitsPerSample : uint8_t { BITS_UNKNOWN = 0x00, BITS_16 = 0x01, BITS_24 = 0x02, BITS_32 = 0x04 };
enum ChannelMode   : uint8_t { UNKNOWN = 0x00, MONO = 0x01, STEREO = 0x02 };

struct CodecConfiguration {                     // 第 225-246 行
    CodecType codecType;
    uint32_t  encodedAudioBitrate;
    uint16_t  peerMtu;
    bool      isScmstEnabled;
    safe_union CodecSpecific {                  // 第 240-245 行 —— 封闭 safe_union
        SbcParameters  sbcConfig;
        AacParameters  aacConfig;
        LdacParameters ldacConfig;
        AptxParameters aptxConfig;
    } config;
};

safe_union AudioConfiguration {                 // 第 249-252 行
    PcmParameters    pcmConfig;
    CodecConfiguration codecConfig;
};
```

`CodecCapabilities` 同样是封闭 safe_union：`sbcCapabilities / aacCapabilities / ldacCapabilities / aptxCapabilities`（第 204-213 行）。

### AOSP HIDL 2.1 — `2.1/types.hal`（**唯一的 LHDC 相关增量位置，但没有 LHDC**）

```hal
enum CodecType : @2.0::CodecType { LC3 = 0x20; };        // 第 39-41 行
enum SampleRate : @2.0::SampleRate { RATE_8000 = 0x100; RATE_32000 = 0x200; };
struct PcmParameters { SampleRate sampleRate; ChannelMode channelMode; BitsPerSample bitsPerSample; uint32_t dataIntervalUs; };
struct Lc3Parameters { BitsPerSample pcmBitDepth; SampleRate samplingFrequency; Lc3FrameDuration frameDuration;
                       uint32_t octetsPerFrame; uint8_t blocksPerSdu; };
safe_union AudioConfiguration {                          // 第 106-110 行
    PcmParameters        pcmConfig;
    CodecConfiguration   codecConfig;                    // ← 复用 @2.0 的，未重新定义
    Lc3CodecConfiguration leAudioCodecConfig;
};
```

### 结论

| 问题 | 答案 |
|---|---|
| LHDC 在哪个 HIDL 版本加入？ | **AOSP 任何 HIDL 版本都没有 LHDC。** AOSP 只有 2.0 / 2.1 两个版本；2.1 只加了 LC3/LE Audio |
| `LhdcConfiguration` 类型？ | **AOSP 不存在**。设备上是 MTK fork 的 `vendor.mediatek.hardware.bluetooth.audio@2.1::CodecConfiguration::CodecSpecific::lhdcConfig`，类型 `LhdcParameters`（V2/V3 时代结构） |
| HIDL 能否携带 V5 参数？ | **不能。** ① AOSP safe_union 封闭；② MTK fork 也只加了一个 `lhdcConfig`（`LhdcParameters`），**没有 `lhdcv5Config`**（全符号表搜索确认） |

MTK HIDL `CodecSpecific` 成员（设备符号表实测，`libbluetooth_jni_orig.so` dynsym）：

```
_ZN6vendor8mediatek8hardware9bluetooth5audio4V2_118CodecConfiguration13CodecSpecific 9sbcConfigE…
_ZN6vendor8mediatek8hardware9bluetooth5audio4V2_118CodecConfiguration13CodecSpecific 9aacConfigE…
_ZN6vendor8mediatek8hardware9bluetooth5audio4V2_118CodecConfiguration13CodecSpecific10ldacConfigE…
_ZN6vendor8mediatek8hardware9bluetooth5audio4V2_118CodecConfiguration13CodecSpecific10aptxConfigE…
_ZN6vendor8mediatek8hardware9bluetooth5audio4V2_118CodecConfiguration13CodecSpecific10lhdcConfigE…   ← 唯一 LHDC 字段
（无 lhdcv5Config / Lhdcv5Parameters）
```

AOSP 侧同样结构（`android.hardware.bluetooth.audio::V2_0`）只有 sbcConfig/aacConfig/ldacConfig/aptxConfig 四个。

---

## (b) `a2dp_get_selected_hal_codec_config` 的完整跳转结构

**AOSP 原文**（`packages/modules/Bluetooth/system/audio_hal_interface/hidl/a2dp_encoding_hidl.cc:229-297`）：

```cpp
bool a2dp_get_selected_hal_codec_config(CodecConfiguration* codec_config) {
  A2dpCodecConfig* a2dp_config = bta_av_get_a2dp_current_codec();
  if (a2dp_config == nullptr) { ... *codec_config = kInvalidCodecConfiguration; return false; }
  btav_a2dp_codec_config_t current_codec = a2dp_config->getCodecConfig();
  switch (current_codec.codec_type) {
    case BTAV_A2DP_CODEC_INDEX_SOURCE_SBC:  [[fallthrough]];
    case BTAV_A2DP_CODEC_INDEX_SINK_SBC:    { if (!A2dpSbcToHalConfig(codec_config, a2dp_config))  return false; break; }
    case BTAV_A2DP_CODEC_INDEX_SOURCE_AAC:  [[fallthrough]];
    case BTAV_A2DP_CODEC_INDEX_SINK_AAC:    { if (!A2dpAacToHalConfig(codec_config, a2dp_config))  return false; break; }
    case BTAV_A2DP_CODEC_INDEX_SOURCE_APTX: [[fallthrough]];
    case BTAV_A2DP_CODEC_INDEX_SOURCE_APTX_HD: { if (!A2dpAptxToHalConfig(...)) return false; break; }
    case BTAV_A2DP_CODEC_INDEX_SOURCE_LDAC: { if (!A2dpLdacToHalConfig(codec_config, a2dp_config)) return false; break; }
    case BTAV_A2DP_CODEC_INDEX_MAX:         [[fallthrough]];
    default:
      LOG(ERROR) << __func__ << ": Unknown codec_type=" << current_codec.codec_type;
      *codec_config = ::bluetooth::audio::hidl::codec::kInvalidCodecConfiguration;
      return false;
  }
  codec_config->encodedAudioBitrate = a2dp_config->getTrackBitRate();
  ... peerMtu 计算 ...
}
```

| 问题 | 答案 |
|---|---|
| LHDC V2 / V3 走哪个函数？ | **AOSP 里没有 LHDC 分支，V2/V3/V5 全部落到 default → `Unknown codec_type=<n>`。** 设备上的 `A2dpLhdcV2ToHalConfig` / `A2dpLhdcV3ToHalConfig` 属于 MTK fork |
| 有没有 LHDC V5 分支？ | **没有。** 整个 AOSP 14 蓝牙音频代码里 `lhdc` 出现 0 次 |
| default 打印什么？ | `"<func>: Unknown codec_type=" << codec_type`，severity **ERROR**，并返回 `false` |

> AOSP 里 default 的**行号是 271-272**；设备日志里的 `(359)` 属于 MTK 的文件 `vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/mediatek/audio_hal_interface/hidl/a2dp_encoding_hidl.cc`（已用 file-path 字符串 xref 对撞确认，见 §(d)）。

**设备侧实测的跳转表**（`libbluetooth_jni_orig.so`，MTK 私有文件，与既有报告一致，本次独立复核通过）：

```
跳转表 @0x2c5620（15 字节）: 00 26 46 46 4b 5a 5a 5a 5a 50 55 5a 5a 00 26 00
分发代码 @0x825f10..0x825f30:  ldr w8,[sp,#0x20] / cmp w8,#0xe / b.hi 0x82609c
                               adrp x9,#0x2c5000 / add x9,x9,#0x620
                               adr  x10,#0x825f34 / ldrb w11,[x9,x8]
                               add  x10,x10,w11,lsl#2 / br x10
目标 = 0x825f34 + table[i]*4
```

PLT→符号对撞结果（本次复核，`pltres.py`）：

| idx | 目标 | 解析出的符号 | 结论 |
|---|---|---|---|
| 0 | 0x825f34 | `…hidl5codec18A2dpSbcToHalConfig` | SBC |
| 1 | 0x825fcc | `…hidl5codec18A2dpAacToHalConfig` | AAC |
| 2/3 | 0x82604c/0x826060 | `…hidl5codec19A2dpAptxToHalConfig` | aptX / aptX-HD |
| 4 | 0x826060 | `…hidl5codec19A2dpLdacToHalConfig` | LDAC |
| 5,6,7,8 | 0x82609c | — | **错误分支** |
| 9 | 0x826074 | `…hidl5codec21A2dpLhdcV2ToHalConfig` | **LHDC V2** |
| 10 | 0x826088 | `…hidl5codec21A2dpLhdcV3ToHalConfig` | **LHDC V3** |
| 11 | 0x82609c | — | **错误分支** |
| **12** | 0x82609c | — | **错误分支 ← LHDC V5（阻塞点）** |
| 13 | 0x825f34 | `A2dpSbcToHalConfig` | SINK_SBC |
| 14 | 0x825fcc | `A2dpAacToHalConfig` | SINK_AAC |

错误分支原文（独立复核）：

```
0x008260a8  adrp x1,#0x228000 ; add x1,x1,#0xb7e   → 0x228b7e = "…/system/mediatek/audio_hal_interface/hidl/a2dp_encoding_hidl.cc"
0x008260b4  mov  w2, #0x167                        → 359
0x008260b8  mov  w3, #2                            → severity ERROR
0x008260cc  add  x1,x1,#0xd00  → 0x241d00 = "a2dp_get_selected_hal_codec_config"
0x008260dc  add  x1,x1,#0x5fc  → 0x2b45fc = ": Unknown codec_type="
```

**→ 索引 12（LHDC V5）在 HIDL 路径上没有任何转换器**：MTK 只写了 V2/V3 的 HIDL 版本。AIDL 侧才写了 V5（见 (e)）。

---

## (c) `A2dpLhdcV3ToHalConfig` 完整源码

**AOSP 中不存在该函数**（0 命中）。以下是设备二进制实测反汇编（`vendor::mediatek::bluetooth::audio::hidl::codec::A2dpLhdcV3ToHalConfig` @ `0x82a8b0`，size 736）。

签名（mangled 还原）：
```cpp
bool A2dpLhdcV3ToHalConfig(
    vendor::mediatek::hardware::bluetooth::audio::V2_1::CodecConfiguration* codec_config, // x0
    A2dpCodecConfig* a2dp_config);                                                        // x1
```

关键指令（本次独立复核）：

```asm
0x82a8cc  mrs  x21, tpidr_el0
0x82a8d0  mov  x19, x0                 ; x19 = codec_config
0x82a8e0  mov  x20, x1                 ; x20 = a2dp_config
0x82a8f8  bl   #0xf48170               ; A2dpCodecConfig::getCodecConfig()
0x82a8fc  ldr  w8, [sp, #0x10]         ; w8 = btav_a2dp_codec_config_t.codec_type
0x82a900  cmp  w8, #0xa                ; == 10 (BTAV_A2DP_CODEC_INDEX_SOURCE_LHDC_V3)
0x82a904  b.ne #0x82ab5c               ; 不等 → return false（无日志、静默）
0x82a924  bl   #0xf48240               ; A2dpCodecConfig::getCodecSpecificConfig(tBT_A2DP_OFFLOAD*)
0x82a928  mov  w8, #0x20
0x82a938  str  w8, [x19], #0xc         ; codec_config->codecType = 0x20 ; x19 += 12 → &config
0x82a940  bl   #0xf4ef00               ; CodecSpecific::lhdcConfig()  (非 const getter)
0x82a948  bl   #0xf4ef10               ; CodecSpecific::lhdcConfig()  (再次，取地址用)
...
0x82a9d8  cmp  w9, #0x3f
0x82a9dc  b.hi #0x82aaa4               ; 采样率位掩码合法性检查
0x82a9ec  movk x10, #0x808b            ; 掩码 = 0x800000008000808B
0x82a9f4  b.eq #0x82aaa4
0x82a9fc  str  w8, [sp, #8]
0x82aa00  cmp  w9, #2                  ; 采样率单 bit 校验
0x82aa20  cmp  w8, #1  / cmp w8,#4 / cmp w8,#2   ; 位深 16/24/32 校验
0x82aa38  add  x1, sp, #8
0x82aa44  bl   #0xf4ef20               ; CodecSpecific::lhdcConfig(const LhdcParameters&)  ← 写入
```

### 逐条回答

| 问题 | 实测答案 |
|---|---|
| 校验什么？ | ① `btav_a2dp_codec_config_t.codec_type == 10`（内部 `btav_a2dp_codec_index_t` = LHDC_V3），不等直接 `return false`；② 采样率位掩码 ⊆ `0x800000008000808B` 且为单 bit；③ 位深 ∈ {16, 24, 32} |
| 填哪些字段？ | `codec_config->codecType = 0x20`（MTK HIDL `CodecType::LHDC`）、`encodedAudioBitrate = getTrackBitRate()`、`CodecSpecific::lhdcConfig(LhdcParameters)` |
| 有没有采样率钳位？ | **没有。** 位掩码原样透传，只做合法性判断（不合法则整体失败）。所以 96 kHz（`RATE_96000 = 0x8`，掩码含 0x8）能通过 —— 与既有报告的结论一致，本次复核确认 |
| 有没有位深钳位？ | 只判合法性，不钳位 |

> 附带确认：`A2dpLhdcV2ToHalConfig` @0x82ab90 的守卫是 `cmp w8, #9`（LHDC_V2），`A2dpLdacToHalConfig` @0x82a5c0 是 `cmp w8, #4`（LDAC）。这与 (b) 的跳转表索引完全自洽。

---

## (d) `btav_a2dp_codec_index_t` → HIDL CodecType 的映射（★ HIDL 边界丢版本信息的关键）

### 1. 分发用的是「内部索引」，不是 HIDL CodecType

`a2dp_get_selected_hal_codec_config` 的 switch 作用在 `current_codec.codec_type`，即 **`btav_a2dp_codec_index_t`（内部枚举）**。AOSP 的 case 标签就是 `BTAV_A2DP_CODEC_INDEX_*`。

### 2. 各转换函数写进 HIDL 结构体的 codecType 值（实测 `str w8,[x19],#0xc` 前的 `mov`）

| 转换函数 | 内部索引守卫 | 写入 HIDL `codecType` | 说明 |
|---|---|---|---|
| `A2dpSbcToHalConfig` | 0 或 13 | — | SBC=0x01 |
| `A2dpAacToHalConfig` | 1 或 14 | — | AAC=0x02 |
| `A2dpAptxToHalConfig` | 2,3(,4?) | — | APTX=0x04 / APTX_HD=0x08 |
| `A2dpLdacToHalConfig` | **4** | **0x10** | LDAC=0x10 ✓ 与 AOSP 一致 |
| `A2dpLhdcV2ToHalConfig` | **9** | **0x20** | MTK `CodecType::LHDC` |
| `A2dpLhdcV3ToHalConfig` | **10** | **0x20** | MTK `CodecType::LHDC` |
| （LHDC V5 = 索引 **12**） | — | **无转换函数** | 无任何 HIDL 表示 |

### 3. 结论（这就是「HIDL 边界丢失版本信息」的确切形式）

```
内部索引 9  (LHDC V2) ──┐
                        ├──► HIDL CodecType = 0x20  (同一个值！)
内部索引 10 (LHDC V3) ──┘

内部索引 12 (LHDC V5) ──► 无分支，直接 ERROR
```

- **HIDL 侧 LHDC V2 与 V3 被压成同一个 CodecType `0x20`**，版本差异只能藏在 `LhdcParameters` 内容里（或根本丢失）。
- **LHDC V5 在 HIDL 枚举里连一个值都没有**，所以既有方案的「伪装成 V3」在语义上是把 V5 参数塞进 V3 的 `LhdcParameters` 里。
- MTK 的 AIDL 侧则是**密集枚举**：`A2dpLhdcV2ToHalConfig` 写 `codecType = 0xa (10)`、`A2dpLhdcv5ToHalConfig` 写 `codecType = 0xb (11)` —— 版本区分在 AIDL 里是完整的。

---

## (e) AIDL 侧 V5 的处理

### 1. AOSP 原文：同样没有 LHDC

`aidl/a2dp_encoding_aidl.cc:240-295` 的 switch 只有 SBC / AAC / APTX / APTX_HD / LDAC / **OPUS**（AOSP 14 新增），default 同样是 `Unknown codec_type=` + ERROR + return false。

`aidl/codec_status_aidl.cc` 里 `codec_config->codecType = CodecType::{SBC,AAC,APTX,APTX_HD,LDAC,OPUS}`，无 LHDC。
`A2dpLhdcv5ToHalConfig` 在 AOSP 源码中**不存在**。

### 2. AIDL 的 Lhdcv5Configuration 字段定义

**AOSP 不存在 `Lhdcv5Configuration`。** 设备上它属于 MTK 私有 AIDL 包
`vendor.mediatek.hardware.bluetooth.audio`（接口库 `/apex/com.android.btservices/lib64/vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`，188,040 B）。

从该库的 dynsym + `writeToParcel`/`readFromParcel` 反汇编可恢复的字段序列（类型可判，**字段名无法从二进制恢复 → 未验证**）：

```
Lhdcv5Configuration::writeToParcel(AParcel*) @0x28080
  AParcel_getDataPosition
  AParcel_writeInt32      (1)
  AParcel_writeInt32      (2)
  AParcel_writeByte       (3)
  AParcel_writeByte       (4)
  AParcel_writeByte       (5)
  AParcel_writeInt32      (6)
  AParcel_writeInt32      (7)
  AParcel_writeInt32      (8)
  AParcel_writeByte       (9)
  AParcel_writeByte       (10)
  AParcel_writeByte       (11)
  AParcel_writeByte       (12)
  AParcel_writeByteArray  (13)   ← 唯一的数组
  AParcel_getDataPosition / AParcel_setDataPosition / AParcel_writeInt32  (AIDL 标准长度前缀回填)
```

同包内相关类型（dynsym 实测）：
`Lhdcv5Capabilities`、`Lhdcv2Configuration`、`Lhdcv5Version`、`Lhdcv5QualityIndex`、`Lhdcv5FrameDuration`、`Lhdcv5DataInterval`、`Lhdcv5Specific`
（`Lhdcv5Capabilities` 里这些是 `vector<...>`：存在 `ToString<vector<Lhdcv5Version>>` 等特化）

### 3. ★ 设备上的 AIDL V5 转换器：走 AOSP 的 vendor 逃生口

`bluetooth::audio::aidl::codec::A2dpLhdcv5ToHalConfig` @ `0x870b80`（1600 B，AOSP 命名空间）：

```asm
0x870bfc  bl   #0xf48240                ; A2dpCodecConfig::getCodecSpecificConfig()
0x870c00  ldr  w8, [sp, #0x30]          ; 内部索引
0x870c04  cmp  w8, #0xc                 ; 12 = LHDC_V5
0x870c08  b.eq #0x870c14
0x870c0c  cmp  w8, #0xa                 ; 10 = LHDC_V3
0x870c10  b.ne #0x870c1c
0x870c14  mov  w8, #7
0x870c18  str  w8, [x19]                ; codec_config->codecType = CodecType::VENDOR (7)
```

调用序列（PLT 对撞）：

```
AParcel_create / AParcel_reset / strlen / AParcel_writeString(descriptor)
Lhdcv5Configuration::writeToParcel(AParcel*)
AParcel_getDataSize / AParcel_appendFrom / AParcel_delete
→ 结果塞进 CodecConfiguration::CodecSpecific::VendorConfiguration::codecConfig (ParcelableHolder)
```

**这就是 AIDL 通路与 HIDL 通路的本质差别**：AOSP AIDL 从设计上提供了
```aidl
@VintfStability parcelable CodecConfiguration {
    @VintfStability parcelable VendorConfiguration {
        int vendorId;
        char codecId;
        ParcelableHolder codecConfig;     // ← 任意 vendor parcelable
    }
    @VintfStability union CodecSpecific {
        SbcConfiguration sbcConfig; AacConfiguration aacConfig;
        LdacConfiguration ldacConfig; AptxConfiguration aptxConfig;
        AptxAdaptiveConfiguration aptxAdaptiveConfig; Lc3Configuration lc3Config;
        VendorConfiguration vendorConfig;             // ← 逃生口
        @nullable OpusConfiguration opusConfig;
    }
    CodecType codecType;                  // ← CodecType::VENDOR = 7
    ...
}
```
（`hardware/interfaces/bluetooth/audio/aidl/android/hardware/bluetooth/audio/CodecConfiguration.aidl`；
`CodecType.aidl` = `UNKNOWN, SBC, AAC, APTX, APTX_HD, LDAC, LC3, VENDOR, APTX_ADAPTIVE, OPUS, APTX_ADAPTIVE_LE, APTX_ADAPTIVE_LEX`）

→ **AIDL 通路可以无损承载任意 vendor codec（含 LHDC V5），无需修改任何接口定义。** HIDL 通路没有这个机制（safe_union 封闭 + 版本冻结）。

MTK 另有一套自己的 AIDL 命名空间转换器 `vendor::mediatek::bluetooth::audio::aidl::codec::A2dpLhdcv5ToHalConfig` @ `0x83fd80`（1476 B），直接把 `codecType` 写成 MTK AIDL 枚举的 `0xb`。

---

## (f) `HalVersionManager::GetHalVersion()` 完整源码与选路条件

### AOSP 14 `android14-release`（`system/audio_hal_interface/hal_version_manager.cc`）

```cpp
using ::aidl::android::hardware::bluetooth::audio::IBluetoothAudioProviderFactory;

static const std::string kDefaultAudioProviderFactoryInterface =
    std::string() + IBluetoothAudioProviderFactory::descriptor + "/default";   // 第 34-35 行

BluetoothAudioHalVersion HalVersionManager::GetHalVersion() {                  // 第 40-43 行
  std::lock_guard<std::mutex> guard(instance_ptr->mutex_);
  return instance_ptr->hal_version_;
}

HalVersionManager::HalVersionManager() {                                       // 第 93-136 行
  if (AServiceManager_checkService(
          kDefaultAudioProviderFactoryInterface.c_str()) != nullptr) {
    hal_version_ = BluetoothAudioHalVersion::VERSION_AIDL_V1;                  // ← AIDL 优先级最高
    return;
  }

  auto service_manager = android::hardware::defaultServiceManager1_2();
  CHECK(service_manager != nullptr);
  size_t instance_count = 0;
  auto listManifestByInterface_cb =
      [&instance_count](const hidl_vec<android::hardware::hidl_string>& instanceNames) {
        instance_count = instanceNames.size();
      };
  auto hidl_retval = service_manager->listManifestByInterface(
      kFullyQualifiedInterfaceName_2_1, listManifestByInterface_cb);           // HIDL 2.1
  if (!hidl_retval.isOk()) { LOG(FATAL) << ...; return; }
  if (instance_count > 0) { hal_version_ = BluetoothAudioHalVersion::VERSION_2_1; return; }

  hidl_retval = service_manager->listManifestByInterface(
      kFullyQualifiedInterfaceName_2_0, listManifestByInterface_cb);           // HIDL 2.0
  if (!hidl_retval.isOk()) { LOG(FATAL) << ...; return; }
  if (instance_count > 0) { hal_version_ = BluetoothAudioHalVersion::VERSION_2_0; return; }

  hal_version_ = BluetoothAudioHalVersion::VERSION_UNAVAILABLE;
  LOG(ERROR) << __func__ << " No supported HAL version";
}
```

接口名常量（`hal_version_manager.h:32-35`）：
```cpp
constexpr char kFullyQualifiedInterfaceName_2_0[] =
    "android.hardware.bluetooth.audio@2.0::IBluetoothAudioProvidersFactory";
constexpr char kFullyQualifiedInterfaceName_2_1[] =
    "android.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory";
```

### 逐条回答

| 问题 | 答案 |
|---|---|
| 什么条件选 HIDL？ | AIDL 服务不存在 **且** VINTF manifest 声明了 `android.hardware.bluetooth.audio@2.1`（优先）或 `@2.0` 的 `IBluetoothAudioProvidersFactory` |
| 什么条件选 AIDL？ | `AServiceManager_checkService("android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default")` 返回非空 —— 即**运行时 servicemanager 里已注册**该 AIDL 服务 |
| 读系统属性吗？ | **不读。** HalVersionManager 完全不读 `ro.*` / `persist.*`。唯一的属性是 `persist.bluetooth.bluetooth_audio_hal.disabled`（`client_interface_{hidl,aidl}.h:30-33`），它会把整条 BluetoothAudio HAL 关掉（HIDL/AIDL 都关） |
| 依赖 VINTF manifest 吗？ | **HIDL 分支 100% 依赖**：`listManifestByInterface` 的实现是 `hwservicemanager/Vintf.cpp:90-107` 的 `getInstances()`，它读的是 **VINTF manifest**（`VintfObject::GetDeviceHalManifest()` + `GetFrameworkHalManifest()`），**不是运行时注册表**。<br>AIDL 分支用的是 `checkService`（**运行时注册**） |
| AIDL 与 HIDL 优先级？ | **AIDL 绝对优先，且是 early-return。** 只要 AIDL 服务在，永远选 AIDL（VERSION_AIDL_V1） |

### `android14-qpr3-release` 的差异（重要，OTA 后行为会变）

QPR3 重构了这部分：

```cpp
class BluetoothAudioHalVersion {                  // 不再是 uint8 enum
  BluetoothAudioHalVersion(BluetoothAudioHalTransport transport = UNKNOWN,
                           uint16_t major = 0, uint16_t minor = 0);
  bool isHIDL() const; bool isAIDL() const;
  // 定义了 operator< <= == !=  (按 (transport, major, minor) 字典序)
};
const BluetoothAudioHalVersion BluetoothAudioHalVersion::VERSION_AIDL_V1 = {AIDL, 1, 0};
... VERSION_AIDL_V2 / V3 / V4 ...
enum class BluetoothAudioHalTransport : uint8_t { UNKNOWN, HIDL, AIDL };  // HIDL < AIDL

BluetoothAudioHalVersion GetAidlInterfaceVersion() {   // 用 getInterfaceVersion() 问版本
  static auto aidl_version = []() {
    auto provider_factory = IBluetoothAudioProviderFactory::fromBinder(
        ::ndk::SpAIBinder(AServiceManager_waitForService(kDefaultAudioProviderFactoryInterface.c_str())));
    if (provider_factory == nullptr) { LOG_ERROR(...); return VERSION_UNAVAILABLE; }
    int version = 0;
    auto aidl_retval = provider_factory->getInterfaceVersion(&version);
    ...
  }();
  return aidl_version;
}

HalVersionManager::HalVersionManager() {
  hal_transport_ = BluetoothAudioHalTransport::UNKNOWN;
  if (AServiceManager_checkService(kDefaultAudioProviderFactoryInterface.c_str()) != nullptr) {
    hal_version_ = GetAidlInterfaceVersion();      // ← 新增：动态取 AIDL 版本
    hal_transport_ = BluetoothAudioHalTransport::AIDL;
    return;
  }
  ... listManifestByInterface(2_1) → listManifestByInterface(2_0) ...   // 逻辑不变
}
```

qpr3 的 `2.0/types.hal`、`2.1/types.hal`、`CodecType.aidl`、`CodecConfiguration.aidl` **与 release 完全一致**（diff 无输出）。
qpr3 的 `a2dp_encoding_hidl.cc` 只有 include 路径调整（`btif/include/...`），**没有 LHDC**。

---

## (g) 让栈走 AIDL 路径的最低条件（精确清单）

> 下面区分 **AOSP 通用条件** 与 **本机 MTK fork 的实际条件**（后者已用设备二进制/日志验证）。

### A. 本机栈（MTK fork）实际检查什么

MTK 把 HalVersionManager 移到了 `vendor::mediatek::bluetooth::audio`，源文件路径（二进制内字符串实测）：

```
vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/mediatek/audio_hal_interface/hal_version_manager.cc
```

反汇编 `vendor::mediatek::bluetooth::audio::HalVersionManager::HalVersionManager()` @ `0x861370`（1284 B）：

```asm
0x8613b0  adrp x20,#0xff4000 ; add x20,x20,#0x2a8      ; x20 = 0xff42a8 = 静态 std::string（AIDL 服务名）
0x8613b8  tbz  w0,#0,#0x861410                         ; if LOG_IS_ON(INFO) …
0x8613e0  … "HalVersionManager: aidl " (0x241fe0) + 服务名 …
0x861410  ldrb w8,[x20] / ldr x9,[x20,#0x10] / csinc x0,x9,x20,ne   ; libc++ std::string → data()
0x861424  bl   #0xf4f5b0   → AServiceManager_checkService            ; ★ AIDL 运行时探测
0x861428  cbz  x0, #0x861534                                           ; null → 走 HIDL 分支
0x86142c  mov  w8,#3 ; strb w8,[x19,#0x28]                             ; hal_version_ = 3 (AIDL_V1)
0x861434  … "HalVersionManager: hidl " (0x25bec4) + fqname 0x2c5a9b …
0x861490  bl   #0xf4f5c0   → defaultServiceManager1_2()
0x8614e0  bl   #0xf4f5d0   → hidl_string(fqname)
0x861514  blr  x9          → IServiceManager::listManifestByInterface(fqname, cb)   ; MTK 2.2
0x86162c  ldr  x8,[sp,#8]  ; instance_count
0x861634  mov  w8,#2 ; strb w8,[x19,#0x29] ; cbnz w9,→0x861820        ; 若 hal_version_!=0 则保留 3
0x861644  strb w8,[x19,#0x28]                                          ; 否则 = 2
0x86164c  … "HalVersionManager: hidl " + 0x2c5ae9 (MTK 2.1) …
0x86176c  … 若仍为 0 …
0x861534  bl AServiceManager_checkService(0xff42c0)                    ; ★ 第二个 AIDL 探测
0x861554  mov w8,#0x404 ; strh w8,[x19,#0x28]                          ; hal_version_=4, [0x29]=4
0x86175c  ldr x8,[sp,#8] ; cbz … ; mov w8,#1 ; b 0x861638              ; = 1 (HIDL 2.0)
```

静态字符串 0xff42a8 / 0xff42c0 由全局构造函数（`0x861930` 附近）初始化：
```asm
0x861934  adrp x1,#0x27c000 ; add x1,x1,#0x342   → 0x27c342 = "/default"
0x861954  bl   #0xf465c0                          ; std::string operator+
0x861958  adrp x8,#0xff4000 ; add x8,x8,#0x2a8    ; 存入静态 string
```
即 `descriptor + "/default"`，`descriptor` 由 APEX 内的 `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so` 提供（`libbluetooth_jni.so` 里是 **UND 符号** `_ZN4aidl6vendor8mediatek8hardware9bluetooth5audio30IBluetoothAudioProviderFactory10descriptorE`）。

**运行时日志实测**（`artifacts/logs/*.log`，行号与二进制地址一一对应：line 141 ↔ 0x8613e0，line 155 ↔ 0x861464）：

```
I/droid.bluetooth: [INFO:hal_version_manager.cc(141)] HalVersionManager: aidl vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default
I/droid.bluetooth: [INFO:hal_version_manager.cc(155)] HalVersionManager: hidl vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory
```

> 注意：这两行是 **checkService 之前** 打印的「将要查询的名字」，**不能**据此判断选了哪个；判据是后续 `strb` 写入。

MTK 的探测顺序：**MTK AIDL(3) → MTK HIDL 2.2(2) → MTK HIDL 2.1(1) → [另一个 AIDL(4)] → AOSP HIDL 2.1/2.0**。
（AOSP 名字 `android.hardware.bluetooth.audio@2.1/2.0::…` 只被 `bluetooth::audio::HalVersionManager` @0x87cb70 引用 —— 那是 AOSP 命名的另一份实现，与 MTK 的 @0x861370 并存；设备日志只出现 MTK 那份。）

### B. 最低条件清单

| # | 条件 | 必要性 | 证据 |
|---|---|---|---|
| 1 | **servicemanager 中注册名为 `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` 的 AIDL 服务**（`AServiceManager_addService`），且必须在 `com.android.bluetooth` 加载 `libbluetooth_jni.so` **之前**已注册 | **必需**（唯一决定版本选择的开关） | 0x861424 `AServiceManager_checkService` → `strb #3` |
| 2 | 该服务实现 MTK AIDL V1 接口（`vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so` 已在 APEX，接口定义现成） | **必需** | UND 符号 + APEX 内 188,040 B 接口库 |
| 3 | **VINTF manifest 声明**：`<hal format="aidl"><name>vendor.mediatek.hardware.bluetooth.audio</name><version>1</version><fqname>IBluetoothAudioProviderFactory/default</fqname></hal>` 加入 `/vendor/etc/vintf/manifest.xml` | **数据通路必需**（版本选择不需要） | MTK AIDL 客户端 `…aidl::BluetoothAudioClientInterface::GetAudioCapabilities` @0x84ddb0 与 `FetchAudioProvider` @0x84e0cc 调 `AServiceManager_isDeclared` + `AServiceManager_waitForService` |
| 4 | `/system/etc/vintf/compatibility_matrix.device.xml` 已含该 AIDL HAL 条目且 `optional="true"` | 已满足，**无需改动** | 实测第 474-480 行 |
| 5 | `persist.bluetooth.bluetooth_audio_hal.disabled` 必须为未设置/false | 必需（否则整条 HAL 被关） | 字符串 @0x2a22ac；`a2dp_encoding_{hidl,aidl}.cc:321/334` |
| 6 | 任何 `ro.*` / `persist.*` 属性？ | **不需要。** HalVersionManager 不读属性 | 0x861370-0x861874 全函数无 `__system_property_*` 调用 |
| 7 | 服务端 SELinux 域允许 `add` 到 servicemanager 且 framework 侧允许 `find` | 必需（平台机制） | 未在本轮验证（超出 R1 范围） |

**当前设备状态（实测）**：

```
$ adb shell su -c 'service list' | grep -i bluetooth
76  bluetooth_manager: [android.bluetooth.IBluetoothManager]        ← 只有这个，无 AIDL HAL
$ adb shell su -c 'ls /vendor/lib64/hw/ | grep -i bluetooth'
android.hardware.bluetooth.audio@2.0-impl.so                        ← 只有 HIDL 实现
android.hardware.bluetooth.audio@2.1-impl.so
vendor.mediatek.hardware.bluetooth.audio@2.1-impl.so
vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so
（无 *-service / 无 AIDL impl）
$ adb shell su -c 'grep -n vendor.mediatek.hardware.bluetooth.audio /vendor/etc/vintf/manifest.xml'
335:        <name>vendor.mediatek.hardware.bluetooth.audio</name>
336:        <transport>hwbinder</transport>              ← 只有 HIDL 声明，没有 format="aidl"
337:        <version>2.2</version>
```

→ **vendor 侧完全没有 AIDL 实现**，这是唯一硬缺口。

---

## (h) 从 HIDL 切到 AIDL 后，音频数据通路有什么不同？

### 相同点（关键：数据面基本同构）

| 项 | HIDL 2.0/2.1 | AIDL V1~V3 |
|---|---|---|
| 软件编码数据面 | `IBluetoothAudioProvider.startSession(hostIf, audioConfig) generates (Status, fmq_sync<uint8_t> dataMQ)` | `MQDescriptor<byte, SynchronizedReadWrite> startSession(in IBluetoothAudioPort hostIf, in AudioConfiguration audioConfig, in LatencyMode[] supportedLatencyModes)` |
| 都是 FMQ | ✅ `fmq_sync<uint8_t>` | ✅ `MQDescriptor<byte, SynchronizedReadWrite>` |
| 控制面 | `IBluetoothAudioPort.startStream/suspendStream/…` | 同 |
| 会话类型 | `A2DP_SOFTWARE_ENCODING_DATAPATH` / `A2DP_HARDWARE_OFFLOAD_DATAPATH` | 同（AIDL 名字为 `..._ENCODING_DATAPATH`） |

**软件编码（本机场景）下，HAL 侧拿到的都是 PCM over FMQ**；所以既有实现里 96 kHz 能跑通这一点，在 AIDL 下同样成立（PCM 参数来自 `a2dp_get_selected_hal_pcm_config`）。

### 不同点

| 维度 | HIDL | AIDL |
|---|---|---|
| 传输 | hwbinder（`hwservicemanager`） | binder（`servicemanager`） |
| 服务名 | `android.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default` | `android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` |
| 版本发现 | `listManifestByInterface` 读 **VINTF manifest** | `checkService` / `isDeclared` / `waitForService` + `getInterfaceVersion()`（qpr3） |
| 接口演进 | 冻结版本 2.0/2.1，`safe_union` 封闭 → **加不了 LHDC V5** | `@VintfStability` + `getInterfaceVersion()`，且有 **`CodecType::VENDOR` + `VendorConfiguration{ParcelableHolder}`** → **可承载任意 vendor codec** |
| 本机 fork 的服务名 | `vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory/default` | `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` |

### vendor 侧需要实现什么

1. 一个 binder 服务进程（如 `/vendor/bin/hw/vendor.mediatek.hardware.bluetooth.audio-service`），链接 `vendor.mediatek.hardware.bluetooth.audio-V1-ndk`，用 `AServiceManager_addService(factory->asBinder().get(), "vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default")` 注册（参照 AOSP `hardware/interfaces/bluetooth/audio/aidl/default/service.cpp`）。
2. `IBluetoothAudioProviderFactory.getProviderCapabilities(SessionType)` 与 `openProvider(SessionType)`。
3. 对 `A2DP_SOFTWARE_ENCODING_DATAPATH` 返回一个 `IBluetoothAudioProvider`，其 `startSession` 返回有效的 `MQDescriptor<byte, SynchronizedReadWrite>`（FMQ），并把 PCM 写进音频输出 —— 即 **`audio.bluetooth.default.so` / `audio.primary.mediatek.so` 必须支持 AIDL 版本的 session 接口**（现有的是 `libbluetooth_audio_session_mediatek.so`，HIDL 版）。
4. 对 `A2DP_HARDWARE_OFFLOAD_ENCODING_DATAPATH` 则需实现 codec offload（本机 `persist.bluetooth.a2dp_offload.cap=sbc-aac`，与 LHDC 无关）。
5. VINTF manifest 声明（见 (g)#3）。
6. `CodecSpecific::VendorConfiguration{vendorId, codecId, ParcelableHolder}` 中承载 `Lhdcv5Configuration`（`vendorId` 需与 stack 侧 `A2dpLhdcv5ToHalConfig` 写入的一致 —— 该值未在本轮定位，**未验证**）。

---

## 2. 对既有两份报告的独立验证结论

| 既有结论 | 复核结果 |
|---|---|
| P1 跳转表 `0x2c5620`，`table[12]` 由 `0x5a`→`0x55` | ✅ **成立**。表字节 `00 26 46 46 4b 5a 5a 5a 5a 50 55 5a 5a 00 26 00` 实测一致；`[9]`→`A2dpLhdcV2ToHalConfig`、`[10]`→`A2dpLhdcV3ToHalConfig`、`[12]`→错误分支 经 PLT 对撞独立确认 |
| 错误分支含 `mov w2,#0x167` = 359 | ✅ **成立**。`0x8260b4 mov w2,#0x167`，且文件路径字符串 = `…/system/mediatek/audio_hal_interface/hidl/a2dp_encoding_hidl.cc` |
| P2 校验 `codec_type == 10`（`0x82a900 cmp w8,#0xa` / `0x82a904 b.ne`） | ✅ **成立**。实测一致 |
| 「HIDL `CodecSpecific` 唯一 LHDC 字段是 `lhdcConfig`」 | ⚠️ **部分成立**：`lhdcConfig` 是 **MTK fork 加的**，AOSP 原文连这个都没有。且 MTK 也**没有** `lhdcv5Config` |
| 「`A2dpLhdcv5ToHalConfig`（AIDL）@0x83FD80 是死代码」 | ⚠️ **需修正表述**：`0x83fd80` 是 **MTK AIDL 命名空间**的版本。设备上还存在 **AOSP AIDL 命名空间**的 `bluetooth::audio::aidl::codec::A2dpLhdcv5ToHalConfig` @ `0x870b80`。两者都是死代码，但原因不同：MTK 那份因为 AIDL 服务不存在；AOSP 那份因为 `bluetooth::audio::HalVersionManager` 那份实现未被选中 |
| 「vendor 侧不存在 AIDL 实现（全盘搜索确认）」 | ✅ **成立**。`/vendor/bin/hw/`、`/vendor/lib64/hw/` 均无 AIDL 蓝牙音频实现；`service list` 无对应服务 |
| 「AIDL 接口 `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`（APEX）有 `Lhdcv5Configuration`」 | ✅ **成立**。dynsym + `writeToParcel` 实测确认（字段序列见 (e)） |
| 「阻断点是 HIDL 接口定义里没有 V5 结构」 | ✅ **成立**，但更精确：不是「没有 V5 结构」，而是 ①AOSP HIDL safe_union 封闭 ②MTK fork 只加了 V2/V3 用的 `lhdcConfig` ③HIDL 侧 V2/V3 甚至被压成同一个 `CodecType = 0x20` |

---

## 3. 明确标注

**已验证事实**：本文件所有带地址/偏移/命令输出的结论。

**推断**：
- 静态字符串 `0xff42c0`（第二个 AIDL 探测）对应的服务名 —— 由日志中只出现一个 aidl 名 + 二进制中只有两个 `/default` 拼接点推断，**未定位其字面值**。
- `hal_version_ = 4` 的语义（MTK 新增的更高 AIDL 版本）—— 由 `GetHalTransport` 的位图 `0x4_0203_0300` 反推（index4 → transport 4），**枚举名未知**。

**未知**：
- `Lhdcv5Configuration` 的**字段名**（只能从 `.aidl` 源码获得，二进制不可恢复）。
- `VendorConfiguration.vendorId` 的取值。
- MTK `btav_a2dp_codec_index_t` 中索引 5,6,7,8,11,13,14 的枚举名（只知 13/14 = SINK_SBC/SINK_AAC，9/10/12 = LHDC V2/V3/V5）。
- MTK HIDL `CodecType` 完整枚举（只知 LDAC=0x10、LHDC=0x20；LC3 是否仍是 0x20 未验证）。
- SELinux 侧对新增 AIDL 服务域的约束。

---

## 4. 落盘文件清单

`reference/aosp-src/android14-release/`
- `packages_modules_Bluetooth/system/audio_hal_interface/hidl/a2dp_encoding_hidl.cc` / `.h`
- `…/audio_hal_interface/aidl/a2dp_encoding_aidl.cc` / `.h`
- `…/audio_hal_interface/hal_version_manager.cc` / `.h`
- `…/audio_hal_interface/hidl/{client_interface_hidl.cc,client_interface_hidl.h,codec_status_hidl.cc,codec_status_hidl.h}`
- `…/audio_hal_interface/aidl/{client_interface_aidl.cc,client_interface_aidl.h,codec_status_aidl.cc,codec_status_aidl.h}`
- `…/audio_hal_interface/{Android.bp,a2dp_encoding.cc,a2dp_encoding.h}`
- `hardware_interfaces/bluetooth/audio/{2.0,2.1}/{types.hal,IBluetoothAudioProvider.hal,IBluetoothAudioProvidersFactory.hal}`
- `hardware_interfaces/bluetooth/audio/aidl/android/hardware/bluetooth/audio/{CodecConfiguration.aidl,CodecType.aidl,AudioConfiguration.aidl,AudioCapabilities.aidl,CodecCapabilities.aidl,SessionType.aidl,LdacConfiguration.aidl,IBluetoothAudioProvider.aidl,IBluetoothAudioProviderFactory.aidl}`
- `hardware_interfaces/bluetooth/audio/aidl/default/{service.cpp,bluetooth_audio.xml,Android.bp}`
- `hardware_interfaces/bluetooth/audio/2.0/default/BluetoothAudioProvidersFactory.cpp`
- `hardware_interfaces/bluetooth/audio/utils/session/BluetoothAudioSession.h`
- `system_hwservicemanager/{ServiceManager.cpp,ServiceManager.h,Vintf.cpp,Vintf.h,HidlService.h}`

`reference/aosp-src/android14-qpr3-release/` — 同名差异文件 8 个

`analysis/scripts/` — `fetch.py` `batch.py` `batch2.py` `walk.py` `xref_imm.py` `xref_bl.py` `pltres.py` `syms2.py` `disa.py`
`analysis/raw/` — `v3_halconfig.txt`
`artifacts/` — `mtk-audio-V1-ndk.so`（从设备 pull，188,040 B）

> 注意：`reference/aosp-src/system/audio_hal/*`、`hwif/*`、`fwnative/*` 是**另一个 agent 留下的 404 占位文件**（内容为 `404: Not Found`），不代表 AOSP 中存在 `BluetoothAudioHalVersion.h` / `BluetoothAudioHal.cpp`。
