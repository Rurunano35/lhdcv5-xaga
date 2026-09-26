# xaga「真·LHDC V5 通路」前置条件分析

> **【最终结果】** 本文的分析已全部落地实施并端到端验证通过。
> 真·LHDC V5 通路（`codec_type=12` 原生送达 HAL）+ **192 kHz** 已在设备上跑通，
> 实测 PCM 速率 1,152,457 B/s（误差 0.04%）。实现细节见
> [LHDC-V5-真通路-实现报告.md](LHDC-V5-真通路-实现报告.md)。
>
> 本文的价值在于：**为什么只能这样做** —— HIDL 边界的硬约束论证、白名单机型固件的实证、
> 以及三条候选路线（含被否决的两条）的评估过程。文中 §5.10 记录了一次失败的开机测试，
> 其根因（`mv` 改变 ld.config inode）已在实现阶段定位并解决。

> 设备：Redmi Note 11T Pro（xaga / MT6895 / 天玑 8100）
> 系统：Android 14 / HyperOS `OS2.0.12.0.ULOCNXM`
> 目标：分析"不伪装、真正实现 LHDC V5 路径"需要哪些前提
> 日期：2026-09-25
> 工作目录：`d:/Cache/Hyperos/lhdcv5-tr/`
>
> **证据分级**：本文每条结论都标注了取证方式。
> `【反汇编】`= 离线反汇编 + 重定位解析；`【源码】`= AOSP 官方源码原文；
> `【设备】`= 设备只读命令实测；`【推断】`= 由证据推导但未直接观测。

---

## 0. 结论（先读这一节）

**在本设备上，"真 V5 路径"不存在一个既有功能收益、又可行的实现形态。**

原因不是工程难度，而是三条**已实证的硬约束**同时成立：

| # | 硬约束 | 后果 |
|---|---|---|
| **C1** | 设备走的 **HIDL** 链路上，LHDC 配置结构体 `LhdcParameters` **只有 8 字节且没有版本字段**；V5 与 V3 在该接口上**逐字节同构** | 在 HIDL 链路上，无论怎么实现，"V5 配置"与"V3 配置"在物理上不可区分 —— **"伪装"无法被消除** |
| **C2** | 设备使用 `A2DP_SOFTWARE_ENCODING_DATAPATH`（软件编码）；该通路下 BT 栈送给 HAL 的**只有 PCM 参数**，编解码器专用配置**永不送达 HAL** | 换到有 V5 结构的 AIDL 链路，**功能收益为零** |
| **C3** | 设备**没有任何 AIDL 蓝牙音频 HAL 实现**；且 audioserver 侧的 BT 音频 HAL 模块 `audio.bluetooth.default.so` **只链接 HIDL** | 想换 AIDL，不仅要自建 AIDL 服务，还必须同时为 audioserver 侧提供 HIDL 桥 —— 工作量极大而收益为零 |

**而当前"V5 伪装 V3"实现之所以工作良好，恰恰因为它没有真正"伪装"任何东西**：
协商是 V5、编码器是 V5、送到 HAL 的 `lhdcConfig` 里装的也是 V5 的实际参数（采样率/位深/声道），
只是挂着一个 V3 也会用的标签（`CodecType = LHDC = 32`）。
**"伪装"发生在协议栈内部的一处校验改写上，对 HAL 完全不可见。**

> 一句话：**在 HIDL 接口的物理约束下，V3 与 V5 的配置结构本就同形；所谓"真 V5"在这条链路上没有可观测的差异。**

**若目标是"做点有实际收益的事"**，方向不是"真 V5"，而是 **192 kHz**（见 §5）——
那是当前唯一被明确阻断、且技术上可解的能力。

---

## 1. 「真 V5」的语义澄清

"真正实现 LHDC V5 路径"至少有四种含义，收益差别极大：

| 语义 | 含义 | 当前状态 | 备注 |
|---|---|---|---|
| **甲** | 与耳机**协商**使用 LHDC V5（A2DP CIE 层面） | ✅ **已达成** | 实测 `mCodecConfig: {codecName:LHDC V5, mCodecType:12, mCodecPriority:8003}` |
| **乙** | 实际使用 **V5 编码器**编码 | ✅ **已达成** | 实测 `lhdcv5_encoder_new: LHDC 5.0 Encode Library @Copyright SAVITECH 2022` + `lhdcv5BT_init_encoder: success!` |
| **丙** | **HAL 接口层**原生携带 V5 信息（不做 12→10 改写） | ⚠️ **物理上不可能在 HIDL 链路实现** | 见 C1 |
| **丁** | HAL 能**区分** V5 并启用不同音频通路 / 格式 / 低延迟模式 | ❌ 但**无收益** | 见 C2；且 HAL 只有 `AUDIO_FORMAT_LHDC` / `AUDIO_FORMAT_LHDC_LL` 两个格式，与 V3/V5 无关 |

**当前实现（P0/P1/P2 内存补丁）已经完整覆盖了甲与乙**，并在丙上做到了 HIDL 接口允许的极限。

### 1.1 V5 能够跑起来的既有前提（本机已全部满足）

这些是"移植"意义上的硬前提，缺一不可；记录在此以便评估其他机型的可行性【反汇编，R2 §8】：

| 前提 | 本机状态 | 位置 |
|---|---|---|
| 厂商固件打包了 V5 编码器库 | ✅ | `/apex/com.android.btservices/lib64/liblhdcv5.so`(3.65 MB) + `liblhdcv5BT_enc.so`(31 KB) |
| 栈内有 V5 协议实现（CIE 解析/构建、能力交集、编码器驱动） | ✅ | `A2DP_ParseInfoLhdcV5` @0x795f30、`A2DP_BuildInfoLhdcV5` @0x798e00、`a2dp_vendor_lhdcv5_*` |
| `createCodec` 白名单放行（**门禁 1**） | ❌→ 由 P0 绕过 | `A2dpCodecConfig::createCodec` @0x763280，比对 `ro.product.name` 与 5 个代号 |
| `A2dpCodecConfigLhdcV5Source::init()` 通过（**门禁 2**） | ✅ | `init()` @0x799270 = `isValid() && A2DP_VendorLoadEncoderLhdcV5()`；后者加载 `liblhdcv5BT_enc.so` / 接口名 `LHDCv5_Encoder` |
| HIDL 分发能处理 `codec_type=12`（**门禁 3**） | ❌→ 由 P1+P2 绕过 | `a2dp_get_selected_hal_codec_config` @0x825ec0，跳转表 `0x2c5620` table[12] |
| 平台 LHDC 开关 | ✅ | `vendor.bluetooth.lhdc_codec.supported`（未设置时运行时=1，`btif_lhdc_codec_is_supported` @0xc417d8） |

> **门禁 2 值得注意**：即使白名单命中，若 `liblhdcv5BT_enc.so` 缺失或加载失败，V5 仍会被静默丢弃。
> 这意味着"移植到其他机型"时，**编码器库的存在与可加载性是第一前提**。

**另有几处 codename 相关的分支，但都不是阻断点**（R4 全量扫描 `ro.product.name` / `ro.product.device` 的引用点）【反汇编】：

| 位置 | 属性 | codename 集合 | 对 xaga 的影响 |
|---|---|---|---|
| `BtifAvSource::Init` @0x6ec02c | `ro.product.name` | 长名单（含 **xaga**） | ✅ 命中，LHDC（V2/V3）使能 |
| `_GLOBAL__sub_I_a2dp_vendor_lhdcv5.cc` @0x79c1dc | `ro.product.device` | `corot`→0x15、`rothko`→0x35、**其它→0x15** | ✅ 不阻断；xaga 取默认值 0x15，**与 corot 同值** |
| `_GLOBAL__sub_I_a2dp_vendor_lhdcv3.cc` @0x795d10 | `ro.product.device` | `corot`→5、其它→0xf | ✅ 不阻断 |

**还有一个独立的门控：LHDC 低延迟（LL）模式**（Java 层，`Bluetooth.apk`）【dex 反编译】：
```
CLASS Lcom/android/bluetooth/a2dp/MiuiBluetoothLatencyMode;
  const-string 'ro.product.device'  → SystemProperties.get
  const-string 'corot duchamp rothko degas malachite'  → String.indexOf   ← 子串匹配，非 equals
```
xaga 不在此名单 → **LHDC 低延迟模式对本机不可用**。
注意这份名单与 native 名单**不同**（含 `degas` 而非 `zircon`），且读的是 `ro.product.device`
（P0 改写的是 `ro.product.name`，**帮不上忙**）。
若"完整 V5 功能"包含 LL 模式，这是**第四道门禁**。

---

## 2. 硬约束 C1：HIDL 链路在结构上无法区分 V3 与 V5

### 2.1 事实：栈内四套转换函数族，只有 AIDL 两族有 V5

`libbluetooth_jni.so`（SHA256 `bedfcaa0…`）`.dynsym` 完整枚举 `*ToHalConfig`【反汇编】：

| 族 | 命名空间 | HAL 类型 | LHDC 支持 |
|---|---|---|---|
| A | `bluetooth::audio::hidl::codec` | `android::hardware::bluetooth::audio::V2_0::CodecConfiguration` | 无 |
| **B** | `vendor::mediatek::bluetooth::audio::hidl::codec` | `vendor::mediatek::hardware::bluetooth::audio::V2_1::CodecConfiguration` | **V2** `0x82ab90` / **V3** `0x82a8b0`；**无 V5** |
| C | `vendor::mediatek::bluetooth::audio::aidl::codec` | `aidl::vendor::mediatek::hardware::bluetooth::audio::CodecConfiguration` | **V5** `0x83fd80`(1476B) + V2 `0x840350` |
| D | `bluetooth::audio::aidl::codec` | `aidl::android::hardware::bluetooth::audio::CodecConfiguration` | **V5** `0x870b80`(1600B) + V2 `0x8711c0` |

**设备实际使用的分发函数是 B 族的 HIDL V2_1 版**：
`(anonymous namespace)::a2dp_get_selected_hal_codec_config(vendor::mediatek::hardware::bluetooth::audio::V2_1::CodecConfiguration*)` @ `0x825ec0`【反汇编】

> 交叉验证：**原生 AOSP 的 HIDL/AIDL 分发里根本没有 LHDC**（只有 SBC/AAC/aptX/LDAC/Opus），
> 且 AOSP HIDL 2.0 的 `CodecSpecific` = `{sbcConfig, aacConfig, ldacConfig, aptxConfig}`，
> 2.1 只加了 LE Audio 的 `Lc3CodecConfiguration`。
> **LHDC 全套是小米/MTK 自行 fork 加入的，且只为 AIDL 加了 V5。**【源码】
> （落盘：`reference/aosp-src/hwif/bluetooth/audio/{2.0,2.1}/types.hal`、
> `reference/aosp-src/system/audio_hal_interface/{hidl,aidl}/a2dp_encoding_*.cc`）

### 2.2 关键：`LhdcParameters` 只有 8 字节，且无版本字段

由 `A2dpLhdcV3ToHalConfig` @ `0x82a8b0` 的写入序列反推【反汇编，见 `analysis/R3-厂商HAL与音频通路取证.md` §4.4】：

```asm
0x82a928  mov  w8, #0x20            ; HIDL CodecType = 32 = LHDC（位枚举）
0x82a938  str  w8, [x19], #0xc      ; 写入 CodecConfiguration.codecType
0x82a940  bl   CodecSpecific::lhdcConfig(const LhdcParameters&)
0x82a9fc  str  w8,  [sp, #8]        ; +0x0  uint32 sampleRate（btav 位掩码）
0x82aa14  strb w9,  [sp, #0xc]      ; +0x4  uint8  channelMode  (1=MONO, 2=STEREO)
0x82aa40  strb w8,  [sp, #0xd]      ; +0x5  uint8  bitsPerSample(1=16, 2=24, 4=32)
0x82a960  strb w20, [sp, #0xe]      ; +0x6  uint8  isLLEnabled
```

```
struct LhdcParameters {   // 共 8 字节，5 个字段
    uint32_t sampleRate;       // +0x0
    uint8_t  channelMode;      // +0x4  (1=MONO, 2=STEREO)
    uint8_t  bitsPerSample;    // +0x5  (1=16, 2=24, 4=32)
    uint8_t  isLLEnabled;      // +0x6
    uint8_t  isLLSupported;    // +0x7
};
```
（第 5 个字段 `isLLSupported` 由 D3 独立反汇编确认；R3 报为 4 字段，以 5 字段为准。）

**没有版本号、没有码率、没有 AR / JAS / LOSSLESS / META 等 V5 特性位。**

**推论（这是本分析最重要的一条）**：
即使我们在协议栈里写一个"真正的 HIDL 版 `A2dpLhdcv5ToHalConfig`"，
它填出来的 `LhdcParameters` 与 V3 转换函数填出来的**逐字节同构**——
因为结构体里根本没有能区分二者的字段。
**在 HIDL 链路上，"消除伪装"在物理上不可实现。**

补充证据：`hl_vendor.mediatek.hardware.bluetooth.audio@2.2.so`（HIDL 接口库）中
`lhdcv5` 字符串计数 = **0**【反汇编】。

### 2.3 对比：MTK AIDL 的 `Lhdcv5Configuration` 有 40 字节

由 `aidl::vendor::mediatek::hardware::bluetooth::audio::Lhdcv5Configuration::writeToParcel`
（`vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so` @0x28080）反解字段序列【反汇编，R4 §6.2】：

```
+0x00 int32   +0x04 byte   +0x05 byte   +0x06 byte
+0x08 int32   +0x0c int32  +0x10 int32
+0x14 byte    +0x15 byte   +0x16 byte   +0x17 byte
+0x18 vector<uint8_t>（begin/end 指针）           → 结构体 0x28 = 40 字节
```

即 **11 个标量 + 1 个变长字节数组**（可推断为 `{版本/采样率掩码, 位深, 声道模式, 码率, JAS/AR/LL/META 特性位, 帧长, 扩展数据}`；
字段名无法从二进制恢复）。**这才是能承载 V5 全量参数的结构**，与 HIDL 的 8 字节不可同日而语。

**但前提是走 AIDL 链路**——而设备上没有 AIDL 实现（C3），且走了也无收益（C2）。

### 2.4 重要：AOSP AIDL 接口**根本没有 LHDC**

`android.hardware.bluetooth.audio-V3-ndk.so`（APEX 内，183792 B）中
`Lhdcv5Configuration` / `Lhdcv5Capabilities` / `Lhdcv2Configuration` / `Lhdc` 字符串计数 **全部为 0**
→ 该接口是**原生 AOSP**（只有 SBC/AAC/aptX/aptX-HD/LDAC/LC3/OPUS/VENDOR）。

因此：
- **唯一能原生承载 LHDC V5 的 AIDL 接口是 MTK 的** `vendor.mediatek.hardware.bluetooth.audio-V1-ndk`。
- 一个反常现象：栈内 `bluetooth::audio::aidl::codec::A2dpLhdcv5ToHalConfig`（AOSP AIDL 命名空间，@0x870b80）
  却调用了 **MTK 的** `aidl::vendor::mediatek::…::Lhdcv5Configuration::writeToParcel`
  （以及 MTK 私有的 `A2dpCodecConfig::getCodecSpecificConfig(tBT_A2DP_OFFLOAD*)`）【反汇编】。
  即 AOSP AIDL 那条 V5 分支引用了设备上 AOSP AIDL 接口并不具备的类型 —— 该分支**自洽性存疑**，
  进一步说明 **MTK AIDL 才是唯一连贯的"真 V5"链路**。

---

## 3. 硬约束 C2：软件编码通路下，HAL 根本收不到编解码器配置

### 3.1 AOSP 权威逻辑

`system/audio_hal_interface/hidl/a2dp_encoding_hidl.cc` 的 `setup_codec()`【源码】：

```cpp
if (active_hal_interface->GetTransportInstance()->GetSessionType() ==
    SessionType::A2DP_HARDWARE_OFFLOAD_DATAPATH) {
    audio_config.codecConfig(codec_config);        // 卸载：下发 codec 配置
} else {
    PcmParameters pcm_config{};
    a2dp_get_selected_hal_pcm_config(&pcm_config); // 软件：只算 PCM 参数
    audio_config.pcmConfig(pcm_config);            // ← 只下发 PCM
}
```

`a2dp_get_selected_hal_pcm_config()` 的三项全部来自 `A2dpCodecToHalSampleRate / BitsPerSample / ChannelMode`，
**与编解码器类型无关**。

### 3.2 设备实测同一逻辑

MTK HIDL `setup_codec()` @ `0x825ae0`【反汇编】：

```asm
0x825d0c  ldr  x8, [x23, #0xde8]     ; active_hal_interface
0x825d10  ldr  x8, [x8, #0x90]       ; GetTransportInstance()
0x825d14  ldrb w8, [x8, #8]          ; session type
0x825d18  cmp  w8, #2                ; == A2DP_HARDWARE_OFFLOAD_DATAPATH ?
0x825d1c  b.ne #0x825d48             ; 否 → PCM 分支
0x825d28  bl   #0xf4ed50             ; AudioConfiguration::codecConfig(codec_config)
0x825d2c  bl   #0xf4e820             ; UpdateAudioConfig(audio_config)
```
PCM 分支：
```asm
0x825d4c  bl #0xf45410               ; bta_av_get_a2dp_current_codec()
0x825d68  bl #0xf48170               ; A2dpCodecConfig::getCodecConfig()
0x825d6c  bl #0xf4e980               ; A2dpCodecToHalSampleRate
0x825d7c  bl #0xf4e990               ; A2dpCodecToHalBitsPerSample
0x825d8c  bl #0xf4e9a0               ; A2dpCodecToHalChannelMode
0x825dc0  bl #0xf4ed60               ; AudioConfiguration::pcmConfig(pcm_config)
```

MTK AIDL `setup_codec()` @ `0x8378f0` 结构完全相同（`0x837d9c cmp w8,#2` / `0x837da0 b.ne`），
其跳转表含 `A2dpLhdcv5ToHalConfig`（GOT `0xf98ac0`）——
**AIDL 路径确实原生支持 V5，但同样只在 offload 分支才下发 codecConfig。**

### 3.3 HAL 侧：`lhdcConfig` 对 HAL 是死数据

【反汇编，见 R3 报告 §4】
- `A2dpSoftwareAudioProvider::startSession` 只做两件事：① `audioConfig.getDiscriminator() == 0`（即必须是 `pcmConfig`）；
  ② `IsSoftwarePcmConfigurationValid(pcmConfig)`。**从不读取 `codecType` / `codecSpecific`**。
- HAL/session 库中 `CodecSpecific::lhdcConfig()` 的 **7/7 调用点全部在 `toString()` 调试字符串拼接里**，无一参与判定。

### 3.4 设备确实走软件通路

`persist.bluetooth.a2dp_offload.cap = sbc-aac`【设备】；日志
`BTAudioHalDeviceProxy: SetUp: session_type=A2DP_SOFTWARE_ENCODING_DATAPATH`【设备】。

**→ 结论：在 xaga 上，HAL 收到的字节里没有任何"V3 还是 V5"的信息，且它也不需要。**

---

## 4. 硬约束 C3：切到 AIDL 需要自建整套实现，且必须为 audioserver 侧补 HIDL 桥

### 4.1 传输选择逻辑（已完全解出）【反汇编】

两个 `HalVersionManager`（AOSP 命名空间 `0x87cb70` / MTK 命名空间 `0x861370`），
构造函数均**先探测 AIDL 服务，失败才回退 HIDL VINTF 查询**。

`vendor::mediatek::bluetooth::audio::HalVersionManager::HalVersionManager()` @ `0x861370`：
```asm
0x861420  x0 = kDefaultAudioProviderFactoryInterface.c_str()   ; 全局 @0xff42a8
0x861424  bl checkService(x0)
0x861428  cbz x0, 0x861534
0x86142c  mov w8, #3
0x861430  strb w8, [x19, #0x28]      ; hal_version_ = 3   ← MTK AIDL 命中
0x861534  ... checkService(第二个 AIDL 名 @0xff42c0)
0x861554  mov w8, #0x404
0x861558  strh w8, [x19, #0x28]      ; hal_version_ = 4   ← AOSP AIDL 命中
（之后 defaultServiceManager1_2() + listManifestByInterface() 判定 HIDL @2.2 → 2，@2.1 → 1）
```

`GetHalTransport()` @ `0x860de0` 用位掩码 `0x00000004_02030300` 查表：
`hal_version_ = 1,2 → transport 3（MTK HIDL）；3 → 2（MTK AIDL）；4 → 4（AOSP AIDL）；0 → 0`

A2DP 分发器 `vendor::mediatek::bluetooth::audio::a2dp::setup_codec()` @ `0x824f90`：
`transport==4 → bluetooth::audio::a2dp::setup_codec()`；`==3 → MTK HIDL impl`；`else → MTK AIDL impl`

**两个 AIDL 服务名**（从 APEX 内接口库的 `descriptor` 字符串读出）【反汇编】：
- MTK：`vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default`
- AOSP：`android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default`

**设备日志实证**了这条路径【设备】：
```
I/droid.bluetooth: [hal_version_manager.cc(141)] HalVersionManager: aidl vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default
I/droid.bluetooth: [hal_version_manager.cc(155)] HalVersionManager: hidl vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory
```
→ 栈**先探 AIDL（未命中），再回退 HIDL**。即：**只要注册上述任一 AIDL 服务，A2DP 通路就会切到 AIDL。**

### 4.2 但 audioserver 侧只认 HIDL

【设备 + 反汇编】
- `lshal`：`android.hardware.bluetooth.audio@2.0/@2.1`、`vendor.mediatek.hardware.bluetooth.audio@2.1/@2.2`
  **全部由 PID 1006（`android.hardware.audio.service.mediatek`，音频 HAL 服务）提供**。
- `audio.bluetooth.default.so`（audioserver 侧的 BT 音频 HAL 模块，**同在 PID 1006**）的 `DT_NEEDED` 只有
  `vendor.mediatek.hardware.bluetooth.audio@2.1.so` / `@2.2.so` / `libbluetooth_audio_session_mediatek.so` /
  `libfmq.so` … —— **不链接任何 AIDL 变体**。
- `BluetoothAudioPortOut::LoadAudioConfig` 调用的是 `V2_2::AudioConfiguration::getDiscriminator()/pcmConfig()`。
- 报告失败链里的 `BTAudioHalDeviceProxy` 就在这个 `.so` 里。

**→ 若把栈切到 AIDL，厂商 HIDL provider 将收不到 `startSession`，
audioserver 侧模块会一直 `wait for session type timeout`，`openOutputStream` 依然失败。**
除非自建的服务**同时**实现 AIDL（对栈）与 HIDL（对模块）并做双向适配。

### 4.4 注册 AIDL 服务**必须**有 VINTF 声明（易被忽略的硬门槛）

客户端侧 `AServiceManager_checkService()` **不检查** VINTF（纯服务名查找）【源码：
`frameworks/native/libs/binder/ndk/service_manager.cpp:58`】。
**但注册侧强制检查**：

```cpp
// frameworks/native/cmds/servicemanager/ServiceManager.cpp:336
Status ServiceManager::addService(...) {
    ...
#ifndef VENDORSERVICEMANAGER
    if (!meetsDeclarationRequirements(binder, name)) {
        return Status::fromExceptionCode(Status::EX_ILLEGAL_ARGUMENT, "VINTF declaration error.");
    }
#endif
}
// :223
static bool meetsDeclarationRequirements(const sp<IBinder>& binder, const std::string& name) {
    if (!Stability::requiresVintfDeclaration(binder)) return true;
    return isVintfDeclared(name);
}
// frameworks/native/libs/binder/Stability.cpp:68
bool Stability::requiresVintfDeclaration(const sp<IBinder>& binder) {
    return check(getRepr(binder.get()), Level::VINTF);
}
```

而 MTK 与 AOSP 两个 AIDL 接口库中都导入了 `AIBinder_markVintfStability`
（`vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so` @0x6aa0；`android.hardware.bluetooth.audio-V3-ndk.so` @0x6639）
→ **两个接口都是 `@VintfStability`**，其 `BnXxx` 构造时会把 stability 置为 `VINTF`
→ **注册时必须能在 VINTF manifest 中查到该实例名**。

设备现状：`/vendor/etc/vintf/manifest.xml` 中 `format="aidl"` 出现 **0 次**，
`/vendor/etc/vintf/manifest/` 下 45 个 fragment 里也没有相关条目。
→ 必须**新增**一条 AIDL HAL 声明。该文件在 `/vendor`（erofs ro + dm-verity），
只能 bind-mount 替换，且**必须早于 servicemanager 首次读取 VINTF manifest**
（libvintf 懒加载并缓存；servicemanager 属 `class core`，启动极早）——**时序风险很高**。

> 注：`VENDORSERVICEMANAGER`（`/dev/vndbinder`）编译掉了这个检查，
> 但 `AServiceManager_checkService` 走的是 `defaultServiceManager()` = 系统 servicemanager（`/dev/binder`），
> 因此**绕不开**。

### 4.5 还有第三道闸门：栈自己会再查一次 VINTF

D1 独立反汇编发现：`checkService` 命中之后，栈还会调用
**`AServiceManager_isDeclared`**（@ `0x8621e4` / `0x8623d0`）二次确认。
缺声明时的日志是 **`init: BluetoothAudio AIDL implementation does not exist`**，
随后 A2DP 音频**整条死掉**（比走 HIDL 更糟）。

即：**服务注册（servicemanager 侧）+ 栈侧二次确认，两处都要求 VINTF 声明**。

### 4.6 SELinux：MTK 服务名**完全无法注册**

D1 解析 plat/vendor CIL 后得到【已验证】：

| 注册用的名字 | `service_contexts` | `add` 所需域 | 结论 |
|---|---|---|---|
| **AOSP 名** `android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` | 有条目 | 需调用域 ∈ `hal_audio_server`（**仅 `mtk_hal_audio`**）；`find` 已对 `bluetooth` 放行 | 需把注册进程放进 `mtk_hal_audio` 域，或加 sepolicy |
| **MTK 名** `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` | **无条目** → 落 `default_android_service` | **全策略无任何 allow 规则** | **add/find 全被拒 → 不可行** |

**→ 若走 AIDL 路线，只能用 AOSP 名**，而 AOSP AIDL 接口**不含 LHDC**（§2.4）——
即"真 V5"在该路线上**根本落不了地**。

### 4.7 落地工程障碍

- `/vendor`、`/system`、`/product`、`/odm` **全部只读**（erofs + dm-verity）。
- D1 实测：**本机 KernelSU 的模块文件覆盖当前未生效**（负面证据）——
  即"用模块 bind-mount 覆盖只读分区文件"这条常规手段**在本机需要先解决**。

### 4.3 PCM 数据面是 FMQ，不是 IPC 回调

`IBluetoothAudioProvider::startSession(...) generates (Status, fmq_sync<uint8_t> dataMQ)`【源码】
→ provider 创建 FMQ 并把描述符回传栈；`audio.bluetooth.default.so` 的 `out_write` →
`BluetoothAudioPortOut::WriteData` → `BluetoothAudioSession::OutWritePcmData` → **FMQ 写**；
栈从同一 FMQ **读**【反汇编 + 符号表】。栈侧导入的是
`MessageQueueBase<MQDescriptor<uint8_t>>::read`，**不存在** `IBluetoothAudioHost::streamOut`。

FMQ 本身支持跨进程传递，因此"自建服务在独立进程"在数据面上不是障碍；
障碍在 §4.2 的双语适配与 §2 的零收益。

---

## 5. 唯一有实际收益的方向：192 kHz

【反汇编 + 设备，详见 R3 报告 §8】

当前 96 kHz 已可用。**192 kHz 被三道独立闸门锁死**：

| 闸门 | 位置 | 内容 |
|---|---|---|
| 1 | `/vendor/etc/bluetooth_offload_audio_policy_configuration.xml` | A2DP devicePort 的 `samplingRates="44100 48000 88200 96000"` |
| 2 | `libbluetooth_audio_session_mediatek.so` `IsSoftwarePcmConfigurationValid(_2_1)` @ `0x16e30` / `0x1a2f4` | 允许的 `sampleRate` 位掩码 = `{0x1,0x2,0x4,0x8,0x40,0x80}`（+V2_2 的 `0x100/0x200`）→ **显式拒绝 `0x10`(176400) 与 `0x20`(192000)** |
| 3 | 同库 `GetSoftwarePcmCapabilities_2_1` @ `0x1a244` → 常量 @ `.rodata 0x8580` | `sampleRate = 0x3cf`，**不含 0x10/0x20** |

**前置条件（若要做）**——D2 给出了比"改 session 库"更干净的形态：
**bind-mount 覆盖 `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so`，
用自建 provider 放宽 `IsSoftwarePcmConfigurationValid`**（该函数**只被 provider 调用**，
且自建 provider 与音频 HAL module 同进程、同名、零 VINTF / 零 sepolicy / 零新进程）【D2 已验证时序】。

| 步骤 | 内容 | 备注 |
|---|---|---|
| 1 | 自建 HIDL provider，复用 `libbluetooth_audio_session_mediatek.so` 的 `OnSessionStarted`，放宽采样率校验 | D2 §3 给出完整接口面：Factory 5 方法 + Provider 5 方法 + `IBluetoothAudioPort` 6 方法 |
| 2 | 改 `/vendor/etc/bluetooth_offload_audio_policy_configuration.xml` 的 `samplingRates` | 闸门 1 |
| 3 | 确认栈侧 `A2dpLhdcV3ToHalConfig` 的采样率校验掩码包含 `0x20` | 报告称"原样透传，无钳位" |

> **前置的工程障碍**：本机 KernelSU 的模块文件覆盖当前**未生效**（D1 负面证据），
> 需先解决"如何覆盖只读分区文件"（R3 指出 PID 1006 与 init 同 mount namespace，理论可行，
> 但需实测；且需 `mount --context=u:object_r:vendor_file:s0` 或 sepolicy 补丁）。

**可行性**：`/vendor` 是 `dm-12 vendor-verity` erofs（ro）+ BL 锁定 + `verifiedbootstate=green`，
**磁盘不可改**；但 **PID 1006 与 init 处于同一 mount namespace**（`mnt:[4026533766]`），
用 KernelSU 模块在 `post-fs-data` 阶段 bind-mount 覆盖**对该服务可见**
（与报告里"BT 进程侧 bind-mount 被 Zygisk Next 剥离"的困境不同——
BT 进程是 zygote fork 的应用进程，音频 HAL 是 init 直接 fork 的原生服务）。
注意：需 `mount --context=u:object_r:vendor_file:s0` 或 `sepolicy.rule`，
否则 `/data` 来源的文件标签会被 `mtk_hal_audio` 域拒绝。

> **但需先评估价值**：192 kHz PCM 输入对 LHDC 只是"更多无用的输入样本"
> （编码器会压缩，A2DP 带宽由码率档位决定，与 PCM 采样率无关），
> 且耳机端极可能自行降采样。这是"指标好看"而非"音质提升"。

---

## 5.5 补充仓库分析（用户后续提供）

| 仓库 | 内容 | 层次 | 对"真 V5 通路"的价值 |
|---|---|---|---|
| `sprlightning/liblhdc-collections` | LHDC 编解码器源码集合（见下） | 编码器 | **零** |
| `DBeidachazi/liblhdcv5` | **Google Rust 版 V5 编码器** + Linux 构建封装（`Makefile`/`PKGBUILD`/`.pc`），源自 AOSP 17 `system/audio/codecs/lhdcv5`（Apache-2.0） | 编码器 | **不能直接用于 xaga**（见下） |
| `TheXPerienceProject/android_vendor_savitech_lhdc` | **Savitech 预编译库打包树**（内核 5.4/5.10/5.15/6.1 四套），`cc_prebuilt_library_shared` + `apex_available: com.android.btservices`，提取自 OnePlus Ace 2 Pro | 编码器 | **零**；但提供了多个 `liblhdcv5.so` 构建 |
| `LineageOS/android_hardware_libhardware` | 传统 HAL 头文件树（`include/hardware/{audio,audio_policy,bluetooth}.h` + `modules/audio_remote_submix`、`usbaudio` 参考实现） | HAL 接口定义 | 无 LHDC 内容；仅在"**自建 BT 音频 HAL 模块**"（R-B/R-C）时有参考价值 |

### ★ 关键否定结论：Google Rust 版编码器**不能**替换 xaga 上的 Savitech 实现

栈通过 `dlopen` + `dlsym` 加载编码器（`A2DP_VendorCodecLoadExternalLib`），
`libbluetooth_jni.so` 内**内嵌了 16 个 `lhdcv5BT_*` 符号名字符串**（即 dlsym 目标）【反汇编】：

```
lhdcv5BT_free_handle      lhdcv5BT_adjust_bitrate     lhdcv5BT_init_encoder
lhdcv5BT_get_bitrate      lhdcv5BT_set_min_bitrate    lhdcv5BT_set_ext_func_state
lhdcv5BT_get_block_Size   lhdcv5BT_get_handle         lhdcv5BT_get_user_exApiver
lhdcv5BT_encode           lhdcv5BT_set_user_exconfig  lhdcv5BT_set_user_exdata
lhdcv5BT_enc              lhdcv5BT_set_max_bitrate    lhdcv5BT_get_user_exconfig
lhdcv5BT_set_bitrate
```

对比两版胶水层源码的导出集：

| 版本 | 导出 `lhdcv5BT_*` | 缺失 |
|---|---|---|
| Savitech（`liblhdc-collections/AOSP/liblhdcv5/src/lhdcv5BT_enc.c`） | 17 个 | — |
| 设备实际编译产物（`/apex/.../liblhdcv5BT_enc.so`，31448 B） | 15 个 | — |
| **Google Rust 版**（`liblhdcv5/aosp/src/lhdcv5BT_enc.c`） | **10 个** | **`get_user_exApiver` / `get_user_exconfig` / `set_user_exconfig` / `set_user_exdata` / `set_ext_func_state`** |

缺失的 5 个正是 MIUI/MTK 的**扩展 API**（被 `BtifAvSource::UpdateLHDCData` @0x700500、
`lhdc_getApiVer_src` @0x6fea10 等使用）。

**→ 直接换用 Rust 版会导致 dlsym 失败 → `A2DP_VendorLoadEncoderLhdcV5` 返回 false →
V5 codec 被 `createCodec` 的第二道门禁丢弃（§1.1）。**
若要采用，必须先为 Rust 胶水补齐这 5 个扩展函数。

### 附：Savitech 各构建版本对照

| 来源 | 版本串 | 大小 |
|---|---|---|
| `android_vendor_savitech_lhdc/5.4`、`5.10` | `LHDC_V5-5.0.4_220426_114542` | 3,542,504 B |
| `android_vendor_savitech_lhdc/5.15` | `LHDC_V5-5.0.5` | 3,542,384 B |
| `android_vendor_savitech_lhdc/6.1` | `LHDC_V5-5.0.5` | 3,132,072 B |
| `liblhdc-collections/AOSP/liblhdc-hyperos2_0_211_0` | `LHDC_V5-5.0.4_220426_114542` | — |
| **设备（xaga）** | **`LHDC_V5-5.0.5_8c9d77`** | **3,652,400 B** |

**设备上的 5.0.5 与仓库中的任何一份都不同构建**（大小与哈希均不同）。

---

## 5.6 参考仓库 `liblhdc-collections` 的作用边界（重要澄清）

用户指定的参考仓库 `https://github.com/sprlightning/liblhdc-collections`
（本地 commit `09a74e70…`）经完整分析后，**对"真 V5 通路"问题的帮助为零**【R5 报告】：

| 仓库内容 | 性质 | 对通路问题的价值 |
|---|---|---|
| `AOSP/liblhdcv5/`（`lhdcv5BT_enc.c` 等） | **纯胶水层**（2387 行 C，零算法），算法全在预编译 `liblhdcv5.so` 内 | 无 —— 本机该库已存在且工作正常 |
| `lhdcv5/`（Google Rust 版编码器） | 闭源 `.so` 的**功能替代实现** | 无 —— 且导出符号名不同（`lhdcv5_enc_ffi_*` ≠ `lhdcv5_util_*`），**砍掉了 lossless/JAS/META/AR/VBR/MTU 全部扩展 API**，不能直接替换 |
| `AOSP/liblhdc-hyperos2_0_211_0/` | HyperOS 2.0.211.0 的 `liblhdcv5.so` | 无 —— 那是 **5.0.4**（`LHDC_V5-5.0.4_220426_114542`），本机是 **5.0.5**（`LHDC_V5-5.0.5_8c9d77`） |
| `ESP-IDF/`、`BES-IHC/` | ESP32 / BES 平台的 **Sink 侧解码器**移植 | 无 —— 与 Android 编码通路无关（CIE 字节布局有参考价值） |
| HAL / 协议栈侧代码 | **完全不含** | — |

**结论**：该仓库打开了"编码器算法"这个黑盒，但**通路问题不在编码器层**。
设备缺的是厂商 HAL 对 `Lhdcv5Configuration` 的实现，以及 HIDL 接口对 V5 的表达能力 —— 仓库对此零帮助。

---

## 5.6 唯一真实的功能缺口：低延迟（LL）控制面 —— 但它不是"伪装"造成的

R8 通过全库符号普查与分发器反汇编定位到一个**真实缺失**，值得单列：

**（a）HIDL 通路上没有 LL 控制协议。** 分发器
`vendor::mediatek::bluetooth::audio::a2dp::set_audio_low_latency_mode_allowed(bool)` @ `0x8253b0`【反汇编】：

```asm
0x8253c4  bl  HalVersionManager::GetHalTransport()
0x8253cc  cmp w8, #4
0x8253d0  b.ne 0x8253e8
0x8253e4  b   bluetooth::audio::a2dp::set_audio_low_latency_mode_allowed     ; AOSP AIDL
0x8253e8  bl  HalVersionManager::GetHalTransport()
0x8253f0  cmp w8, #2
0x8253f4  b.ne 0x82540c
0x825408  b   vendor::mediatek::…::aidl::a2dp::set_low_latency_mode_allowed  ; MTK AIDL
0x82540c  ret                                    ; ★ transport ∈ {0,1,3} → 空操作
```

本机 `hal_version_ = 2` → `transport = 3` → **走到 `0x82540c` 直接返回，什么都不做**。

**（b）HIDL 接口里根本没有 LL 方法**：`hl_vendor…@2.2.so` 与 `hal22.so` 中
`setLatencyMode` / `LatencyMode` / `LowLatencyModeAllowed` 字符串计数**全部为 0**；
栈侧这三个符号**只存在于 AIDL 后端**。

**（c）切到 AIDL 反而会丢 LL 标志**：MTK AIDL `setup_codec` 的 PCM 分支
```asm
0x837e9c  stur xzr, [x24, #6]     ; ★ +6..+13 全部清零 → isLowLatencyEnabled 恒为 0
```

**（d）Java 侧还有独立机型门禁**：`MiuiBluetoothLatencyMode` 的名单不含 xaga（见 §1.1）。

> **判定**：LL 是本机型上唯一真实的功能缺口，**但它是 HIDL transport 的结构性缺口，
> 不是"V5 伪装 V3"造成的** —— 即使写一个"原生 HIDL V5 转换函数"，同样拿不到 LL。
> 修复它需要**同时**打通三层（vendor AIDL 实现 + HAL 侧 LL 逻辑 + Java 机型门禁），
> 且 AIDL 的 PCM 结构还会把 LL 标志清零。**不值得投入。**

---

## 5.7 ★ 专项：「移植其他机型的 HAL」可行性评估

**问题**：能否移植白名单机型的 HAL，以解锁 192kHz + 原生 LHDC V5 + 提升稳定性？

### 5.7.1 好消息：白名单机型**全部是联发科平台**

来源：`MiCode/MTK_kernel_modules` README 的分支表（该仓库本身只是占位 README，价值在于这张表）：

| codename | 机型 | 平台分支 |
|---|---|---|
| **corot** | Redmi K60 Ultra | MTK `t-alps-release-t0.mp1.tc8sp2` |
| **zircon** | Redmi Note 13 Pro+ | MTK `t-alps-release-t0.mp1.tc8sp2` |
| **duchamp** | Redmi K70E | MTK `t-alps-release-u0.mp1.tc8sp1` |
| **rothko** | Redmi K70 Ultra | MTK `alps-mp-u0.mp1.tc8sp3` |
| **malachite** | Redmi Note 14 Pro | MTK `t-alps-release-u0.mp1.tc8sp3` |
| （xaga） | Redmi Note 11T Pro | MTK（本机） |

**→ 5 个白名单机型与 xaga 同属 MTK，用同一个 `vendor.mediatek.hardware.bluetooth.audio` 接口族。**
"移植它们的 AIDL HAL"在**接口层面是自洽的**——这正是白名单的工程含义。

### 5.7.2 坏消息：要移植的不是"一个 HAL"，而是一个**耦合簇**

已查清的耦合面【反汇编，符号表】：

| 组件 | 从 session 库导入的符号数 | 类型味道 |
|---|---|---|
| `audio.bluetooth.default.so`（音频 HAL 模块） | **15**（`BluetoothAudioSession_2_1::GetSessionInstance/IsSessionReady/GetAudioConfig`、`BluetoothAudioSession::OutWritePcmData/StartStream/…`） | 全部 **V2_1/V2_2 HIDL 类型** |
| `hal22.so`（HIDL provider） | **6**（`OnSessionStarted`、`OnSessionEnded`、`ReportControlStatus`、`EnterGameMode`、`GetAudioSession`、`GetSessionInstance`） | 全部 **V2_1/V2_2 HIDL 类型** |
| **xaga 的 `libbluetooth_audio_session_mediatek.so`** | 导出上述全部 —— 但 **`aidl`/`ndk`/`AidlMQDescriptorShim` 字符串计数 = 0** | **纯 HIDL** |

**→ 要让 AIDL HAL 工作，必须换掉 session 库（换成 AIDL 版）；
而 session 库 ABI 一变，`audio.bluetooth.default.so` 就会链接失败 → 必须连音频 HAL 模块一起换。**

**最小移植集 = 3 个库**：

| # | 库 | 目标位置 | 为什么必须 |
|---|---|---|---|
| 1 | `vendor.mediatek.hardware.bluetooth.audio-V1-ndk` **实现** | 新增（无先例） | 提供 AIDL HAL |
| 2 | `libbluetooth_audio_session_mediatek.so`（AIDL 版） | `/vendor/lib64/` | 需 AIDL 符号集 |
| 3 | `audio.bluetooth.default.so`（匹配版） | `/vendor/lib64/hw/` | 必须匹配 #2 的新 ABI |

外加：VINTF 声明（**两处**：servicemanager `addService` + 栈侧 `isDeclared`）、
SELinux 策略（MTK 服务名当前**完全不可注册**，见 §4.6）、
服务注册与开机时序、**P0 白名单仍需绕过**（R4 已验证：白名单在任何 HAL 交互之前生效）。

### 5.7.3 三个目标逐个评估

| 目标 | 移植能否达成 | 依据 |
|---|---|---|
| **原生支持 LHDC V5** | ✅ 接口层达成；**功能收益为零** | 软件编码通路下 HAL 只收 `pcmConfig`（C2）。`Lhdcv5Configuration` 送达与否**不改变任何音频字节** |
| **解锁 192kHz** | ❌ **大概率不能** | MTK 软件 PCM 校验掩码 `{44100,48000,88200,96000,16000,24000(,8000,32000)}` **不含 176400/192000**，能力常量 `0x3cf` 同样不含。这是**平台级策略**，白名单机型大概率一致【**推断**，未验证】。offload 路线亦不通（xaga DSP 无 LHDC 编码器） |
| **提高传输稳定性** | ⚠️ **无证据支持** | 伪装是协议栈内一处类型校验的等值改写，不改变送给 HAL 的任何字节，也不影响 L2CAP/AVDTP。真正的稳定性风险是**另一件事**：硬编码偏移在 APEX 升级后失效（§7.1） |

### 5.7.4 更好的替代方案（按目标分派）

| 目标 | 推荐路线 | 工作量 |
|---|---|---|
| **192kHz** | **D2 路线**：bind-mount 替换 `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so` 为自建 provider（放宽 `IsSoftwarePcmConfigurationValid`）+ 改音频策略 `samplingRates` | **替换 1 个库 + 改 1 个 xml**，远小于移植 3 个库 |
| **稳定性** | 把硬编码偏移改为**符号/特征定位**（本库未做可见性收敛，`A2dpLhdcV3ToHalConfig` 等全部导出，可直接从 `.dynsym` 取址） | 小，且收益明确 |
| **原生 V5** | 只有移植 AIDL 一条路，**且收益为零** | 极大 |

### 5.7.5 内核仓库与本问题的关系：**无关**

两个内核仓库（`vendor_qcom_opensource_audio-kernel`、`MTK_kernel_modules`）都只是 **README 占位**
（MiCode 通过 `repo` manifest 分发真实源码）。更根本的是：
**A2DP 软件编码的 PCM 通路不经过内核** —— 已实证 `audio.bluetooth.default.so` 与 session 库
**零个**内核/PCM 设备符号（无 `pcm_open`/`tinyalsa`/`/dev/snd`/`hw_get_module`/`adev_*`），
PCM 走 `AudioFlinger → 音频 HAL 模块 → FMQ → BT 栈`。**内核侧不是闸门。**

---

## 5.8 ★★ 白名单机型固件实证 —— 结论修正

> 用户提供了 5 个线刷包：Android 14 的 **zircon / malachite / corot**，Android 16 的 zircon / malachite。
> 提取方法：`tar --wildcards` 取 `super.img` → 7-Zip 解 LP 得 `vendor_a.img` → **WSL(`wsl -u root` + `modprobe erofs`) 挂载 EROFS** 取文件。
> 脚本：`analysis/scripts/{rom_extract.sh, wsl_erofs_pull.sh, scan_samplerate.py}`

### 5.8.1 白名单机型**确实带 AIDL 蓝牙音频 HAL 实现**（已验证）

| 机型 | AIDL 实现库 | AIDL session 库 | VINTF AIDL 声明 |
|---|---|---|---|
| **zircon** | `vendor.mediatek.hardware.bluetooth.audio-impl.so` | `libbluetooth_audio_session_aidl.so` + `libbluetooth_audio_session_aidl_mediatek.so` | `vendor.mediatek.hardware.bluetooth.audio` |
| **corot** | 同上（与 zircon **字节级相同**） | 同上 | 同上 |
| **malachite** | `android.hardware.bluetooth.audio-impl-mediatek.so` | `libbluetooth_audio_session_aidl.so` + `libbluetooth_audio_session_aidl_mtk.so` | `android.hardware.bluetooth.audio` v3 |

即：**存在两代实现**——zircon/corot 用 MTK 命名的 AIDL 接口，malachite 用 AOSP 命名的 AIDL 接口（v3）。
两者都提供 `BluetoothAudioCodecs::IsSoftwarePcmConfigurationValid` / `GetSoftwarePcmCapabilities`。

### 5.8.2 ★ 关键修正：**AIDL 通路确实支持 192 kHz**

对 `IsSoftwarePcmConfigurationValid` 逐指令追踪到其采样率向量，再定位静态初始化器与 `.rodata` 源数组：

| 库 | 采样率向量源 | 允许的软件 PCM 采样率 |
|---|---|---|
| **xaga** `libbluetooth_audio_session_mediatek.so`（HIDL） | 位掩码 `{0x1,0x2,0x4,0x8,0x40,0x80}` | 44.1k 48k 88.2k 96k 16k 24k —— **无 176.4k/192k** |
| **zircon/corot** `_aidl_mediatek.so` | `.rodata 0xcc98`（8×int32） | 16k 24k 44.1k 48k 88.2k 96k **176.4k 192k** |
| **malachite** `_aidl_mtk.so` | `.rodata 0x13164`（8×int32） | 16k 24k 32k 44.1k 48k 88.2k 96k **192k** |

**取证链**（以 zircon 为例，全部逐指令可复现）：
```
IsSoftwarePcmConfigurationValid @0x154b0
  0x154d4  adrp+add -> 0x340b8        ; sampleRate 向量（.bss）
初始化器 @0x1d6bc（匿名命名空间全局构造）
  0x1d6b0  adrp x9, #0xc000
  0x1d6b8  add  x9, x9, #0xc98        ; 源 = .rodata 0xcc98
  0x1d6bc  add  x20, x20, #0xb8       ; 目标 = 0x340b8
  0x1d6c0  add  x8, x0, #0x20         ; 32 字节 = 8 个 int32
  0x1d6c8  ldp  q0, q1, [x9]
  0x1d6d4  stp  q0, q1, [x0]
.rodata 0xcc98 = 16000 24000 44100 48000 88200 96000 176400 192000
```
malachite 同形（初始化器 @0x2943c → `.rodata 0x13164`，8 项含 192000）。

> **这推翻了 §5.7.3 中"移植大概率不能解锁 192kHz"的推断。**
> 结论修正为：**移植白名单机型的 AIDL HAL，是解锁 192kHz 的可行路径。**

### 5.8.3 移植仍需解决的问题（前置条件）

| # | 项 | 说明 | 难度 |
|---|---|---|---|
| 1 | **AIDL session 库** | 必须换上 `libbluetooth_audio_session_aidl_mediatek.so`（或 `_aidl_mtk.so`） | 低（有现成文件） |
| 2 | **AIDL HAL 实现** | 换 `vendor.mediatek.hardware.bluetooth.audio-impl.so`（或 AOSP 版 `android.hardware.bluetooth.audio-impl-mediatek.so`） | 中 |
| 3 | **音频 HAL 模块** | xaga 的 `audio.bluetooth.default.so` **`aidl` 字符串计数 = 0**（纯 HIDL）；白名单机型的为 **56** → 必须一并替换 | 中 |
| 4 | **VINTF 声明** | 需新增 `format="aidl"` 片段（白名单机型就有独立的 `etc/vintf/manifest/bluetooth_audio.xml`）；且 servicemanager `addService` + 栈侧 `isDeclared` **双重检查** | 高（时序） |
| 5 | **SELinux** | MTK 服务名当前无 `service_contexts` 条目 → **完全不可注册**；AOSP 名需 `hal_audio_server` 域 | 高 |
| 6 | **服务注册** | AIDL 实现需在 PID 1006（音频 HAL 服务）内注册 | 中 |
| 7 | **白名单绕过** | `createCodec` 仍会拦截 V5 → P0 仍需保留 | 已有方案 |
| 8 | **音频策略** | `/vendor/etc/*audio_policy_configuration.xml` 的 `samplingRates` 需放宽到含 192000 | 中 |

**关键风险**：白名单机型的库是为**不同 MTK 平台**（D7200/D9200+/D7300）与**不同音频 HAL 服务**构建的；
`audio.bluetooth.default.so` 与 session 库之间的 ABI 必须整体匹配，跨平台移植存在符号/结构体不兼容风险。

---

## 5.9 ★★★ 移植实施方案（基于固件实证）

### 5.9.1 移植源的选择：**zircon（或 corot，二者字节级相同）**

对比两个白名单机型的音频 HAL 服务可执行文件与 xaga 的依赖差异：

| 服务二进制 | 大小 | 相对 xaga 的**额外**依赖 |
|---|---|---|
| **zircon / corot** | 19,784 B（`92f5362fe3708739`） | **仅 2 个**：`android.hardware.bluetooth.audio-impl.so`、`vendor.mediatek.hardware.bluetooth.audio-impl.so` —— **全部是蓝牙音频 AIDL 库** |
| malachite | 28,864 B | **5 个**，含 `android.hardware.soundtrigger3-V1-ndk.so`、`android.hardware.soundtrigger3-impl.so`、`vendor.mediatek.hardware.audio-V1-ndk.so`、`vendor.mediatek.hardware.audio-impl.so` —— **平台耦合严重** |

xaga 与 zircon 服务二进制的**共同依赖**：`android.hardware.audio@6.0/7.0/7.1.so`、`android.hardware.audio.common@6.0/7.0.so`、
`android.hardware.audio.effect@6.0/7.0.so`、**`android.hardware.soundtrigger@2.3.so`（同为 HIDL）**、
`vendor.mediatek.hardware.audio@6.1/7.1/8.1.so`、`vendor.mediatek.hardware.bluetooth.audio@2.1/2.2.so`。

> **结论：zircon 的服务二进制对 xaga 是"超集 + 纯蓝牙音频扩展"，零平台音频 HAL 牵连。**
> 这是移植路线可行的关键前提，也是**必须选 zircon/corot 而非 malachite** 的原因。

### 5.9.2 移植文件集（源：zircon A14；corot A14 对应文件字节级相同）

| # | 文件 | 大小 | SHA256(前16) | 目标路径 |
|---|---|---|---|---|
| 1 | `android.hardware.audio.service.mediatek` | 19,784 | `92f5362fe3708739` | `/vendor/bin/hw/` |
| 2 | `audio.bluetooth.default.so` | 152,648 | `6bc04153a1eb31de` | `/vendor/lib64/hw/` |
| 3 | `libbluetooth_audio_session_aidl_mediatek.so` | 215,472 | `1d451e357cfba65e` | `/vendor/lib64/` |
| 4 | `libbluetooth_audio_session_aidl.so` | 207,232 | `063645e47cb280ce` | `/vendor/lib64/` |
| 5 | `libbluetooth_audio_session_mediatek.so` | 124,656 | `2d34e39c10ff72f9` | `/vendor/lib64/` |
| 6 | `vendor.mediatek.hardware.bluetooth.audio-impl.so` | 151,064 | `9e6d07bda1f94440` | `/vendor/lib64/` |
| 7 | `android.hardware.bluetooth.audio-impl.so` | 139,008 | `902a06eb4bb569f6` | `/vendor/lib64/` |
| 8 | `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so` | 179,728 | `853a44f452cc7718` | `/vendor/lib64/` |
| 9 | `bluetooth_audio.xml`（VINTF AIDL 声明） | 212 | `282c4095f4ee0712` | `/vendor/etc/vintf/manifest/` |

> #4 的 AOSP 版 session 库**不含 192k**，但 #6 的 MTK 实现链接的是 #3（**含 192k**）；
> 且 zircon 的 VINTF 声明的是 **MTK 名**（`vendor.mediatek.hardware.bluetooth.audio`）→ 实际走 #3 那条路。✓

### 5.9.3 仍需解决的事项

| # | 事项 | 说明 |
|---|---|---|
| 1 | **SELinux 策略** | MTK AIDL 服务名 `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` 在 xaga 的 `service_contexts` 中**无条目** → 注册被拒。需 `sepolicy.rule` 或 `magiskpolicy` 补规则 |
| 2 | **VINTF 时序** | 声明文件需早于 servicemanager 读取；且栈侧还有 `AServiceManager_isDeclared` 二次确认 |
| 3 | **音频策略** | `/vendor/etc/*audio_policy_configuration.xml` 的 `samplingRates` 需加入 `192000` |
| 4 | **白名单绕过** | `createCodec` 仍会拦截 V5 → 现有 P0 补丁**必须保留** |
| 5 | **`/vendor` 覆盖能力** | D1 实测本机 KernelSU 的模块文件覆盖**当前未生效**，需先解决（bind-mount + `--context=u:object_r:vendor_file:s0`） |
| 6 | **P1/P2 补丁** | 走 AIDL 后 P1/P2 **可移除**（AIDL 分发表 `[12]` 已正确指向 V5 转换器）；仅保留 P0 |

### 5.9.4 风险与验证步骤

**风险**：
- 替换的是**音频 HAL 服务可执行文件**（核心系统服务）。虽依赖差异显示零平台耦合，但**必须实测**。
- 跨 SoC（zircon D7200 vs xaga D8100）：服务二进制只通过 `hw_get_module` 加载平台 HAL 模块（xaga 用自己的 `audio.primary.mt6895.so`），**SoC 耦合在模块层而非服务层** —— 这是风险可控的技术依据。

**建议的验证顺序**（每步都可回退）：
1. 先只替换 9 个文件 + 补 sepolicy + VINTF，**不启用 P0 白名单绕过** → 验证设备**普通音频功能不受影响**（扬声器/麦克风/通话/A2DP SBC）
2. 确认无回归后，启用 P0 → 验证 LHDC V5 协商成功且走 AIDL（日志出现 `HalVersionManager: aidl …` 与 `a2dp_encoding_aidl.cc`）
3. 最后改音频策略 `samplingRates` → 验证 192kHz（实测 PCM 速率 = 192000×3×2 = 1,152,000 B/s）

---

## 5.10 ★★★ 实测失败记录：KernelSU 模块导致无法开机（2026-09-25）

### 事实经过

| 时间 | 事件 |
|---|---|
| 18:50:29 | 模块 `post-fs-data.sh` 执行**成功**（脚本自带日志证明：载荷落地 15 文件、ld.config 已打补丁、3 项挂载完成） |
| 18:50–18:52 | **设备无法进入系统** |
| 18:52 | 用户创建 `/data/adb/modules/lhdcv5-aidl/disable` 禁用模块后重启，系统恢复正常 |
| 事后 | 设备状态已确认：无残留挂载、ld.config 已还原、audio-hal 正常 |

**失败那次开机的日志已被覆盖**（`logcat -L` 与 `/sys/fs/pstore/console-ramoops-0` 均只含恢复后的那次启动），**无法取得直接的失败证据**。

### 已排除：VINTF manifest 不是启动阻断

静态核查设备的框架兼容矩阵，**AOSP 名 AIDL 是被允许的**：

```xml
<!-- /system/etc/vintf/compatibility_matrix.8.xml -->
<hal format="aidl" optional="true">
    <name>android.hardware.bluetooth.audio</name>
    <version>3</version>
    <interface><name>IBluetoothAudioProviderFactory</name><instance>default</instance></interface>
</hal>
```

（对照：MTK 名 `vendor.mediatek.hardware.bluetooth.audio` AIDL 在 **DCM** 中有，但**不在 FCM** 中 —— 所以"改用 MTK 名以规避 manifest 改动"这条路**不可行**。）

### 剩余嫌疑（未验证）

| # | 改动 | 爆炸半径 | 评估 |
|---|---|---|---|
| 1 | **`/linkerconfig/ld.config.txt` 补丁** | **所有 vendor 进程** | 嫌疑最大。其中 `+= /apex/com.android.btservices/${LIB}` 把 APEX 路径加进 vendor 命名空间，可能触发 linkerconfig 的命名空间冲突校验。运行中测试时新进程（audio-hal/audioserver）能正常启动，但**开机时 init 会用它启动全部厂商进程**，覆盖面远比测试时大 |
| 2 | `audio.bluetooth.default.so`（malachite / D7300 版） | 音频 HAL 服务 | 跨 SoC 移植件；脚本日志显示它被挂上了，开机早期音频 HAL 服务若因此失败，影响面大 |
| 3 | shim（`@2.2-impl.so`） | 仅 HIDL 蓝牙音频 | 运行中实测正常（含 HIDL 无回归） |

### 方法论教训

**三项改动应当逐项、逐次重启验证，而不是一次性全部启用。** 尤其 ld.config 补丁的影响面是"此后所有厂商进程的库解析"，运行中重启单个服务**不足以**验证其开机安全性。

### 结论：AIDL 路线本质上必须开机期改动，无 ADB-only 路径

因为 **servicemanager 在开机时缓存 VINTF**（其二进制含 `Could not find %s.%s/%s in the VINTF manifest.` / `VintfObject::GetInstance()`，且无运行时禁用开关），
AIDL 服务注册**只能在开机期完成**。而开机期改动一旦出错就是无法进入系统。

**继续推进的正确方式**（若决定继续）：按上表 3→1→2→(manifest) 的顺序，**每次只启用一项并重启**，确认能开机后再加下一项。

---

## 6. 三条候选路线的前置条件汇总

| | **R-A：栈内真 V5 转换** | **R-B：切 AIDL 传输** | **R-C：改 /vendor HAL** |
|---|---|---|---|
| 做法 | 把 `A2dpLhdcV3ToHalConfig` 的 GOT 槽重定向到模块内的自建 V5 转换函数，原生接受 `codec_type=12` | 自建 MTK AIDL `IBluetoothAudioProviderFactory` 服务 + AIDL↔HIDL 双语桥 | 替换 `@2.2-impl.so` + `libbluetooth_audio_session_mediatek.so` |
| 前置 1 | 注入点：**`A2dpLhdcV3ToHalConfig` 的 GOT 槽 `0xf98d80`**（全库唯一调用点 `0x826090`，即 table[10]/table[12] 共用 stub）——重定向它即可让 table[12] 走到自建实现，**无需分配新可执行内存** | AIDL 接口定义（**只有编译后的 .so，需逆向**） | `/vendor` bind-mount 能力（**已证明可行**，见 §5） |
| 前置 2 | 了解 `A2dpCodecConfig` 内部 56 字节布局（**已有**） | 服务注册：**必须新增 VINTF `format="aidl"` 声明**（接口为 `@VintfStability`，servicemanager 强制检查，见 §4.4）+ SELinux 策略 + 极早时序的 `/vendor` bind-mount | 改 HAL 判定逻辑 |
| 前置 3 | — | **为 audioserver 侧同时提供 HIDL 服务**（`audio.bluetooth.default.so` 只认 HIDL） | — |
| 前置 4 | — | FMQ 跨进程传递（FMQ 原生支持） | — |
| **产出** | 去掉 P2 的 `getCodecConfig` 钩子；`LhdcParameters` 仍 8 字节 | HAL 收到 `Lhdcv5Configuration`（**但仅 offload 分支**） | HAL 认识 V5 |
| **功能收益** | **零**（C2；且 HIDL 边界的 `codecType` 对 V3/V5 都是 `0x20`，12 从未到达 HAL） | **零**（C2 + 设备走软件通路） | **零**（C2） |
| **工程收益** | 补丁点从 2 个 GOT 槽减到 1 个，但多出 1 个结构体偏移依赖 → **净收益≈0** | 可去掉 P1/P2（**P0 白名单仍需处理**：`createCodec` 在任何 HAL 交互之前就丢弃 V5） | 无 |
| 难度 | **低** | **极高** | 高 |
| 建议 | 仅当目标是"语义诚实"；**不建议** | **不建议** | **不建议** |

**两条对既有报告的重要修正**（D3 独立复核得出）：

| 原说法 | 实际 | 影响 |
|---|---|---|
| "bluetooth 域无 `execmem`/`execmod` 规则，故 `.text` 完全不动" | **`execmem` 是允许的**（设备策略 `(allow appdomain self (process (execmem)))`，`bluetooth ∈ appdomain`）；被禁的**只有 `execmod`** | 原结论的**理由**不准确，但**结论仍成立**：GOT 方案更优（不涉及可执行内存） |
| 可用 `table[12]` 直接指向自建函数 | **物理上不可行**：跳转表表项是**无符号字节**，目标 = `0x825f34 + 表项×4`，**最多向前 1020 字节**，够不到模块代码 | 必须走 GOT 重定向 |

---

## 7. 对当前实现的评价（结论）

现有 P0/P1/P2 内存补丁方案**已经是本设备上能达到的最优解**：

| 层 | 现状 | 评价 |
|---|---|---|
| 协商（甲） | LHDC V5 / 96 kHz / 24 bit 实测通过 | ✅ 真 V5 |
| 编码器（乙） | `LHDC_V5-5.0.5_8c9d77` 实测加载 | ✅ 真 V5 |
| HAL 接口（丙） | 传 `CodecType=LHDC(32)` + 8 字节 `LhdcParameters`（内含 V5 实际参数） | ✅ **在 HIDL 物理约束下的极限**；C1 证明无法更"真" |
| 副作用 | 无（C2 证明 HAL 不读该结构） | ✅ |

**"V5 伪装 V3"这个命名有误导性**：实现并没有让 V5 降级为 V3 运行，
而是**在一处协议栈内部的类型校验上做了等值改写**，使得 HIDL 分发函数能够返回成功。
被送出的配置参数（采样率/位深/声道/低延迟位）**全部是 V5 协商得到的真实值**。

**若一定要消除这个改写**，唯一有意义的是 R-A（低成本、零功能变化、纯工程整洁度），
其余两条路线（R-B / R-C）投入巨大而收益为零。

### 7.1 当前实现的真实风险：可维护性，而非功能

R8 的结论与本分析一致，并指出**唯一值得投入的方向**：

> 当前实现最大的真实风险是**可维护性**：4 个硬编码文件偏移 + 3 个 GOT 槽偏移，
> **APEX 一升级即整体失效**（有身份校验兜底，不会变砖，但会静默退回 V3）。

这确实是本方案唯一的工程隐患。**可选的改进方向**（按性价比排序）：

| 方向 | 做法 | 收益 |
|---|---|---|
| **A. 提高偏移定位的鲁棒性** | 用**符号/特征**定位代替硬编码偏移：从 `.dynsym` 找 `A2dpLhdcV3ToHalConfig` 等导出符号（本库未做可见性收敛，全部导出），再在其内部按指令特征定位跳转表与校验点 | APEX 升级后大概率仍可用；改动局限在模块内 |
| **B. 扩展身份校验** | 现有校验只比对 3 处原始字节；可扩展为"符号存在性 + 指令模式"多重校验，失配时**明确报错**而非静默失效 | 可观测性 |
| **C. 合并补丁点（R-A）** | 用自建 V5 转换函数替换 P2 的 `getCodecConfig` 钩子 | 补丁从 3 处减到 2 处 |
| D. 追求"真 V5" | R-B / R-C | **零收益，不建议** |

> 结论：**下一步值得做的是 A + B（鲁棒性），而不是"真 V5"。**

---

## 8. 证据索引与验证状态

| 结论 | 取证方式 | 状态 |
|---|---|---|
| 四套转换函数族，仅 AIDL 两族有 V5 | `.dynsym` 全枚举 + 符号 demangle | ✅ 已验证 |
| AOSP 原生无 LHDC，MTK 自行 fork HIDL 加 `LhdcParameters` | AOSP `types.hal` / `a2dp_encoding_*.cc` 原文 | ✅ 已验证 |
| `LhdcParameters` = 8 字节无版本字段 | `A2dpLhdcV3ToHalConfig` @0x82a8b0 反汇编写入序列 | ✅ 已验证 |
| 软件通路只下发 `pcmConfig` | AOSP 源码 + 设备 `setup_codec` @0x825ae0 / @0x8378f0 反汇编 | ✅ 已验证（两条独立证据） |
| HAL 不读 codec 配置 | `A2dpSoftwareAudioProvider::startSession` 反汇编 + `lhdcConfig()` 7/7 日志调用点 | ✅ 已验证 |
| 传输选择逻辑（AIDL 优先，HIDL 回退） | 两个 `HalVersionManager` ctor + `GetHalTransport` 位掩码 + 设备日志 | ✅ 已验证（静态+动态一致） |
| AIDL 服务名 | APEX 内接口库 `descriptor` 字符串 | ✅ 已验证 |
| 设备无 AIDL 实现 | `lshal` / `service list` / VINTF / `/vendor` 列表 四重否定 | ✅ 已验证 |
| audioserver 侧模块只认 HIDL | `DT_NEEDED` + `LoadAudioConfig` 反汇编 | ✅ 已验证 |
| PCM 走 FMQ | `IBluetoothAudioProvider.hal` 原文 + 栈侧 `MessageQueueBase::read` 导入符号 | ✅ 已验证 |
| 192 kHz 三道闸门 | 策略 xml + `IsSoftwarePcmConfigurationValid` + 能力常量 | ✅ 已验证 |
| `/vendor` 可 bind-mount（pid 1006 同 init namespace） | `/proc/*/ns/mnt` + mounts + dm 名 | ✅ 已验证 |
| `checkService`（客户端）无 VINTF 检查 | AOSP `libs/binder/ndk/service_manager.cpp` 原文 | ✅ 已验证 |
| `addService`（注册侧）**强制** VINTF 声明（`@VintfStability` 接口） | AOSP `cmds/servicemanager/ServiceManager.cpp` + `libs/binder/Stability.cpp` 原文；两个 AIDL 接口库均导入 `AIBinder_markVintfStability` | ✅ 已验证 |
| V5 编码器库加载是 `createCodec` 的第二道门禁 | `A2dpCodecConfigLhdcV5Source::init()` @0x799270 → `A2DP_VendorLoadEncoderLhdcV5` → `liblhdcv5BT_enc.so` / `LHDCv5_Encoder` | ✅ 已验证（R2） |
| offload 通路对 LHDC 无条件放行 | `IsOffloadCodecConfigurationValid` 跳转表 | ⚠️ 推断（未实跑） |
| 耳机在 192 kHz 下的实际行为 | — | ❓ 未知（本机无法送达，未测） |

**复现入口**：
- 反汇编工具：`lhdcv5-tr/analysis/scripts/{dumpsyms,dynsyms,q,disasm,resolve}.py`
- 符号索引：`lhdcv5-tr/analysis/raw/{symbols,dynsyms}.txt`
- 主调查员发现：`lhdcv5-tr/analysis/MAIN-findings.md`
- 厂商 HAL 取证：`lhdcv5-tr/analysis/R3-厂商HAL与音频通路取证.md`
- 原始 dump：`lhdcv5-tr/analysis/raw/`

**工作流验证状态**：本结论已由 8 路并行侦察 + 3 路独立方案设计 + 3 路对抗性证伪交叉验证
（见 `analysis/` 下各编号报告与 `analysis/V*.md`）。
