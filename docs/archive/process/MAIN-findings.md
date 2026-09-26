# 核心发现（主调查员独立取证）

> 取证对象：`xaga-lhdcv5/artifacts/libs/libbluetooth_jni_orig.so`
> SHA256 `bedfcaa09b5246f4ddc610217a2a000425d21d581e59015fa6143639c9038347`
> 符号来源：`xaga-lhdcv5/analysis/bluetooth-stack/debugdata.elf`（纯符号表，17646 个函数，地址与 .so 的 VA 一致）
> 工具：`lhdcv5-tr/analysis/scripts/{dumpsyms,dynsyms,q,disasm,resolve,xref_bl}.py`
> 所有地址均为文件偏移 = VA（`sh_addr == sh_offset`）

---

## 结论 0（最重要）

**在本设备（xaga）上，"LHDC V5 路径"对音频通路没有可观测收益。**

原因是一条已实证的调用链（见 §3）：软件编码模式下，BT 栈送给音频 HAL 的**只有 PCM 参数**，
编解码器专用配置（含 V5 的 `Lhdcv5Configuration`）**根本不下发**——它只被用来做"是否走硬件卸载"的判定。

因此"把 V5 伪装成 V3"与"原生 V5"在 HAL 侧**完全等价**。

---

## 1. 栈内存在四套编解码器 → HAL 配置转换族（不是两套）

从 `.dynsym` 完整枚举（`grep ToHalConfig raw/dynsyms.txt`）：

| 族 | 命名空间 | HAL 类型 | 支持 LHDC |
|---|---|---|---|
| A | `bluetooth::audio::hidl::codec` | `android::hardware::bluetooth::audio::V2_0::CodecConfiguration` | 无 |
| B | `vendor::mediatek::bluetooth::audio::hidl::codec` | `vendor::mediatek::hardware::bluetooth::audio::V2_1::CodecConfiguration` | **V2 / V3**（`A2dpLhdcV2ToHalConfig` @0x82ab90、`A2dpLhdcV3ToHalConfig` @0x82a8b0）；**无 V5** |
| C | `vendor::mediatek::bluetooth::audio::aidl::codec` | `aidl::vendor::mediatek::hardware::bluetooth::audio::CodecConfiguration` | **V5**（`A2dpLhdcv5ToHalConfig` @0x83fd80，1476B）+ V2 |
| D | `bluetooth::audio::aidl::codec` | `aidl::android::hardware::bluetooth::audio::CodecConfiguration` | **V5**（`A2dpLhdcv5ToHalConfig` @0x870b80，1600B）+ V2 |

**关键**：HIDL 两族都**没有 V5 转换函数**。这就是 `codec_type=12` 在 HIDL 路径上无分支可走的根因，
与报告 §4 的判断一致，但报告未指出"这是 MIUI 只为 AIDL 实现了 V5"这一设计事实。

> 交叉验证：原生 AOSP（android14-release，已落盘 `reference/aosp-src/`）的
> `a2dp_encoding_hidl.cc` 与 `a2dp_encoding_aidl.cc` **都没有 LHDC 分支**（只有 SBC/AAC/aptX/LDAC/Opus）。
> 即 LHDC 全套是小米/MTK 自行加入的，且**只给 AIDL 加了 V5**。

### MTK AIDL 接口原生含 V5
`libbluetooth_jni.so` 的变体析构符号暴露了 MTK AIDL `CodecConfiguration::CodecSpecific` 的完整联合体成员：

```
SbcConfiguration, AacConfiguration, LdacConfiguration, AptxConfiguration,
AptxAdaptiveConfiguration, Lc3Configuration, CodecConfiguration::VendorConfiguration,
Lhdcv5Configuration, Lhdcv2Configuration
```

以及 `CodecCapabilities`：`…, Lhdcv5Capabilities`。
**`Lhdcv5Configuration` 是 MTK AIDL 接口的一等公民。**

---

## 2. 传输选择逻辑（完全解出）

### 2.1 存在两个 HalVersionManager
| 符号 | 地址 | 静态初始化 |
|---|---|---|
| `vendor::mediatek::bluetooth::audio::HalVersionManager::HalVersionManager()` | `0x861370` | `0x8618f0` |
| `bluetooth::audio::HalVersionManager::HalVersionManager()` | `0x87cb70` | `0x87cf30` |

### 2.2 MTK 版构造函数（0x861370）的判定顺序
```asm
0x861414  strh wzr, [x19, #0x28]        ; hal_version_ = 0, le_audio_hal_version_ = 0
0x861420  x0 = kDefaultAudioProviderFactoryInterface.c_str()   ; 全局 @0xff42a8
0x861424  bl checkService(x0)           ; → 0xf4f5b0
0x861428  cbz x0, 0x861534              ; 无此服务 → 下一个检查
0x86142c  mov w8, #3
0x861430  strb w8, [x19, #0x28]         ; hal_version_ = 3  ← MTK AIDL 命中
```
```asm
0x861534  x0 = <第二个字符串>.c_str()    ; 全局 @0xff42c0
0x86154c  bl checkService(x0)
0x861550  cbz x0, 0x861434
0x861554  mov w8, #0x404
0x861558  strh w8, [x19, #0x28]         ; hal_version_ = 4  ← 第二个 AIDL 命中
```
之后走 `defaultServiceManager1_2()` + `listManifestByInterface()`，
以 `vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory`（字符串 @0x2c5a9b）判定 → `hal_version_ = 2`，再以 @2.1 → `hal_version_ = 1`。

> `0xff42a8` / `0xff42c0` / `0xff4450` 均在 `.bss`（文件外），运行时由静态初始化构造
> `descriptor + "/default"`（`"/default"` 字面量 @0x27c342，已实证）。
> MTK 静态初始化（0x87cf30）写 `0xff4450`；0x8618f0 写 `0xff42a8`/`0xff42c0`。
> **注**：`0xff42a8` / `0xff42c0` 具体指向哪个 descriptor 尚未从静态数据中直接读出（见"未决"）。

### 2.3 GetHalTransport（0x860de0）—— 位掩码查表
```asm
0x860e0c  ldrb w20, [x8, #0x28]         ; w20 = hal_version_
0x860e14  lsl  x8, x20, #3              ; 移位 = v*8
0x860e18  mov  x9, #0x300
0x860e1c  movk x9, #0x203, lsl #16
0x860e24  movk x9, #4,     lsl #32      ; x9 = 0x00000004_02030300
0x860e20  cmp  x20, #5
0x860e28  lsr  x8, x9, x8
0x860e2c  csel w0, w8, wzr, lo
```
映射（`x9 >> (v*8)` 取低字节）：

| `hal_version_` | transport | 含义 |
|---|---|---|
| 0 | 0 | UNAVAILABLE |
| 1 | 3 | MTK HIDL @2.1 |
| 2 | 3 | MTK HIDL @2.2 |
| **3** | **2** | **MTK AIDL V1** |
| **4** | **4** | 第二 AIDL（AOSP AIDL V3） |

### 2.4 A2DP 传输分发器（已解析全部 PLT 目标）
`vendor::mediatek::bluetooth::audio::a2dp::setup_codec()` @ `0x824f90`：
```asm
bl  GetHalTransport()          ; 0xf4ebd0
cmp w0, #4  ; → b 0xf4ec30  = bluetooth::audio::a2dp::setup_codec()          (AOSP 分发器)
cmp w0, #3  ; → b 0xf4e6f0  = vendor::mediatek::…::hidl::a2dp::setup_codec()
else        ; → b 0xf4e0d0  = vendor::mediatek::…::aidl::a2dp::setup_codec()
```
`bluetooth::audio::a2dp::setup_codec()` @ `0x861c10`：
```asm
bl GetHalTransport()           ; 0xf4f600
cmp w0, #3  ; → b 0xf4f6b0 = bluetooth::audio::hidl::a2dp::setup_codec()
else        ; → b 0xf4f6c0 = bluetooth::audio::aidl::a2dp::setup_codec()
```

**→ 只要 MTK AIDL 服务在 `servicemanager` 里可被 `checkService` 找到，A2DP 通路就会切到 AIDL 实现。**

---

## 3. ★ 决定性证据：软件编码模式下 HAL 收不到 codecConfig

### 3.1 权威接口定义（AOSP `hardware/interfaces/bluetooth/audio/2.0/IBluetoothAudioProvider.hal`）
```hal
startSession(IBluetoothAudioPort hostIf, AudioConfiguration audioConfig)
            generates (Status status, fmq_sync<uint8_t> dataMQ);
```
> "The PCM parameters are set if software based encoding, otherwise the correct
>  codec configuration is used for hardware encoding."
> `dataMQ`：**PCM 数据经由 FMQ 从 provider 交给 BT 栈**。

### 3.2 MTK HIDL `setup_codec`（0x825ae0）反汇编
```asm
0x825d0c  ldr  x8, [x23, #0xde8]     ; active_hal_interface
0x825d10  ldr  x8, [x8, #0x90]       ; GetTransportInstance()
0x825d14  ldrb w8, [x8, #8]          ; session type
0x825d18  cmp  w8, #2                ; == A2DP_HARDWARE_OFFLOAD_DATAPATH ?
0x825d1c  b.ne #0x825d48             ; 否 → PCM 分支
0x825d28  bl   #0xf4ed50             ; audio_config.codecConfig(codec_config)
0x825d2c  bl   #0xf4e820             ; UpdateAudioConfig(audio_config)
```
PCM 分支（0x825d48）：
```asm
0x825d4c  bl #0xf45410               ; bta_av_get_a2dp_current_codec()
0x825d68  bl #0xf48170               ; A2dpCodecConfig::getCodecConfig()
0x825d6c  bl #0xf4e980               ; A2dpCodecToHalSampleRate
0x825d7c  bl #0xf4e990               ; A2dpCodecToHalBitsPerSample
0x825d8c  bl #0xf4e9a0               ; A2dpCodecToHalChannelMode
0x825dc0  bl #0xf4ed60               ; audio_config.pcmConfig(pcm_config)   ← 只发 PCM
```

### 3.3 MTK AIDL `setup_codec`（0x8378f0）结构完全相同
```asm
0x837d9c  cmp w8, #2
0x837da0  b.ne #0x837e30             ; 非 offload → PCM 分支
0x837de8  ldr x8, [x9, x8, lsl #3]   ; 跳转表 @0xf6d9a8（9 项）
0x837df4  blr x8                     ; → Sbc/Aac/Aptx/Ldac/AptxAdaptive/Lc3/Vendor/Lhdcv5/LhdcV2
0x837e10  bl #0xf4e2a0               ; UpdateAudioConfig(AudioConfiguration)
0x837e30  ... PCM 分支
```
跳转表含 `A2dpLhdcv5ToHalConfig`（GOT 0xf98ac0）——AIDL 路径确实原生支持 V5，
**但同样只在 offload 分支才下发 codecConfig**。

### 3.4 结论
- `a2dp_get_selected_hal_codec_config()` 的产物在**软件模式**下只被 `IsCodecOffloadingEnabled()` 消费。
- xaga 的 `persist.bluetooth.a2dp_offload.cap = sbc-aac`，日志亦确认为
  `A2DP_SOFTWARE_ENCODING_DATAPATH` → **永远走 PCM 分支**。
- **所以"伪装成 V3"对 HAL 不可见；"V5"也不会改变 HAL 收到的任何字节。**

---

## 4. 厂商侧音频 HAL 的形态（决定 AIDL 路线可行性）

设备实况（只读 `lshal` / `ps`）：

| 服务 | 提供进程 |
|---|---|
| `android.hardware.bluetooth.audio@2.0::IBluetoothAudioProvidersFactory/default` | PID 1006 |
| `android.hardware.bluetooth.audio@2.1::…/default` | PID 1006 |
| `vendor.mediatek.hardware.bluetooth.audio@2.1::…/default` | PID 1006 |
| `vendor.mediatek.hardware.bluetooth.audio@2.2::…/default` | PID 1006 |

PID 1006 = audio HAL 服务进程（`/vendor/bin/hw/android.hardware.audio.service.mediatek`，域 `mtk_hal_audio_exec`）。

**→ 厂商 BT 音频 HAL 提供者与 audioserver 同进程**；实现库位于 `/vendor/lib64/hw/`：
`vendor.mediatek.hardware.bluetooth.audio@2.1-impl.so`、`@2.2-impl.so`、
`android.hardware.bluetooth.audio@2.0-impl.so`、`@2.1-impl.so`。

**设备上不存在任何 AIDL 实现**（`lshal` 无 AIDL 条目；`/vendor/lib64/hw/` 无 `-V1-ndk` 实现）。

### 致命约束
`audio.bluetooth.default.so`（audioserver 侧的 BT 音频 HAL 模块）的 `DT_NEEDED` 只有：
```
vendor.mediatek.hardware.bluetooth.audio@2.1.so
vendor.mediatek.hardware.bluetooth.audio@2.2.so
libbluetooth_audio_session_mediatek.so
libfmq.so, libaudioutils.so, libbase.so, libcutils.so, libhidlbase.so, liblog.so, libutils.so, libc++.so
```
**它不链接任何 AIDL 变体**（既无 `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`，
也无 `android.hardware.bluetooth.audio-V3-ndk.so`）。

`BTAudioHalDeviceProxy`（报告失败链里的那个 tag）就在这个 `.so` 里
（`audio.bluetooth.default.so` 内 `"BTAudioHalDeviceProxy"` @0x4aa4、`"waiting for session type"`）。

`audio.bluetooth.default.so` 的 `BluetoothAudioPortOut::LoadAudioConfig` 调用
`V2_2::AudioConfiguration::getDiscriminator()` / `pcmConfig()` —— 即模块**只认 HIDL V2.2**。

**→ 若把 BT 栈切到 AIDL，厂商 HIDL 服务将收不到 `startSession`，
audioserver 侧模块会一直 `wait for session type timeout`，`openOutputStream` 依然失败。**

---

## 5. 对报告既有结论的修正

| 报告/文档的说法 | 本次复核 |
|---|---|
| `A2dpLhdcv5ToHalConfig（AIDL）0x83FD80（死代码）` | ✅ 地址与符号正确。完整符号为 `vendor::mediatek::bluetooth::audio::aidl::codec::A2dpLhdcv5ToHalConfig`，1476 字节。它并非"死代码"，而是 AIDL 传输的实现；本机因走 HIDL 而不被调用 |
| `A2dpLhdcV3ToHalConfig @0x82A8B0` | ✅ 正确，736 字节，属 **MTK HIDL** 族 |
| "HIDL 接口的 CodecSpecific 没有 V5 字段" | ✅ 成立，且更精确：**MIUI 根本没为 HIDL 写 V5 转换函数** |
| "厂商侧不存在 AIDL 实现（全盘搜索确认）" | ✅ 成立，并补充：audioserver 侧模块也**不链接 AIDL**，因此仅补一个 AIDL 服务不足以打通 |
| "音频通路无法建立 → 回落扬声器" | ✅ 成立，但**机制**需修正：不是"配置传不到 HAL 导致选错通路"，而是 `setup_codec()` 在 `a2dp_get_selected_hal_codec_config()` 返回 false 时**提前 return**，根本没走到发 PCM 的那一步 |

---

## 6. 未决项 —— 已全部解决

1. **`0xff42a8` / `0xff42c0` 的身份** → ✅ **已解决**。
   从 APEX 内接口库 `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`（@0xe744）与
   `android.hardware.bluetooth.audio-V3-ndk.so`（@0xcefe）读出 `descriptor` 字符串：
   - MTK：`vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory`
   - AOSP：`android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory`
   设备启动日志实证（`artifacts/logs/lhdc_param.log:8239-8240`）：
   ```
   HalVersionManager: aidl vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default
   HalVersionManager: hidl vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory
   ```
   → 栈先探 MTK AIDL（未命中）→ 再探第二个 AIDL（未命中）→ 回退 HIDL @2.2。

2. **`checkService` 是否受 VINTF 约束** → ✅ **已解决：不受约束**。
   AOSP `frameworks/native/libs/binder/ndk/service_manager.cpp:58` 原文：
   ```cpp
   AIBinder* AServiceManager_checkService(const char* instance) {
       sp<IServiceManager> sm = defaultServiceManager();
       sp<IBinder> binder = sm->checkService(String16(instance));
       ...
   }
   ```
   纯服务名查找，无 VINTF 检查（`AServiceManager_isDeclared` 是另一个独立 API）。

3. **192 kHz 钳制层** → ✅ **已解决：三道独立闸门**（详见
   `R3-厂商HAL与音频通路取证.md` §8）：
   ① 音频策略 `samplingRates` 上限 96000；
   ② `libbluetooth_audio_session_mediatek.so` 的 `IsSoftwarePcmConfigurationValid(_2_1)`
      掩码 `{0x1,0x2,0x4,0x8,0x40,0x80}` 显式拒绝 `0x10/0x20`；
   ③ 同库 `GetSoftwarePcmCapabilities_2_1` 常量 `0x3cf` 不含 `0x10/0x20`。
