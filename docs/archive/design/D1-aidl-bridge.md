# D1 — 路线设计：AIDL 桥接服务（补上本机缺失的 AIDL 蓝牙音频 HAL 实现）

> 任务：不碰 `libbluetooth_jni.so`，通过补齐 AIDL 蓝牙音频 HAL 实现，让 `HalVersionManager` 选 AIDL 通路，
> 使栈内既有的 `A2dpLhdcv5ToHalConfig`（现为死代码）原生跑通 LHDC V5。
>
> 方法：本地反汇编（capstone + pyelftools）+ AOSP 源码 + **只读** adb 查询。
> 所有地址基于 `d:/Cache/Hyperos/xaga-lhdcv5/artifacts/libs/libbluetooth_jni_orig.so`
> （SHA256 `bedfcaa09b5246f4ddc610217a2a000425d21d581e59015fa6143639c9038347`，**VA == 文件偏移**）。
>
> 脚本：`analysis/scripts/d1/*.py`；原始输出：`analysis/raw/d1_*.txt`、`analysis/raw/d1/`。

---

## 0. 结论速览

| 问题 | 结论 | 证据强度 |
|---|---|---|
| 栈选 AIDL 需要探测到什么 | servicemanager 中出现 **`android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default`**（AOSP 名）即可。`HalVersionManager` 只调 `AServiceManager_checkService`，**不读属性、不查 VINTF** | **已验证**（反汇编 0x861370） |
| 选中后走哪条后端 | `hal_version_=4` → transport 4 → **`bluetooth::audio::aidl::a2dp::*`**（AOSP AIDL **V3** 接口） | **已验证**（0x824ed0 分发器 + 0x860de0 映射表） |
| 数据面第二道闸门 | `AServiceManager_isDeclared`（**VINTF manifest**）。缺它 → 日志 `init: BluetoothAudio AIDL implementation does not exist`，A2DP 音频整条死掉 | **已验证**（0x8621e4 / 0x8623d0） |
| 能否做纯转发 shim | **能**。PCM 生产者（`audio.bluetooth.default.so`）是 HIDL-only，所以 FMQ 必须由 pid 1006 内的 HIDL provider 创建；shim 只需把该描述符原样转给栈 | **架构已验证**；含 1 处描述符转换需实现（§2.4） |
| V5 配置映射 | 软件编码通路**根本不把 codec 配置发给 HAL**（只发 pcmConfig）→ 映射无损也无意义；卸载通路 AIDL `VendorConfiguration` ↔ HIDL `lhdcConfig` 转换会丢版本/特性位 | **已验证** |
| 能否去掉 P0 白名单补丁 | **不能**。白名单在 `A2dpCodecConfig::createCodec` @0x763428，与 HAL 代次完全解耦（`ro.product.name` 全库仅 2 个读取点，已复核） | **已验证** |
| 能否去掉 P1/P2 | **能** —— 这是本路线**唯一实质收益** | **已验证**（MTK AIDL 跳转表 `[12]` 已正确指向 V5 转换器） |
| 落地最大障碍 | **VINTF 声明**：`/vendor` `/system` `/product` `/odm` 均只读；需要 root 方案的**文件覆盖**能力，而本机实测 KernelSU 的模块文件覆盖**当前未生效**（负面证据，§4.3） | **已验证（负面）** |
| SELinux | 用 **AOSP 名**注册：`add` 需要调用域 ∈ `hal_audio_server`（仅 `mtk_hal_audio`）；`find` 已对 `bluetooth` 放行。用 **MTK 名**注册：`service_contexts` 无条目 → 落 `default_android_service` → **全策略无任何 allow 规则，add/find 全被拒** | **已验证**（plat/vendor CIL 解析） |

**一句话结论**：路线**技术上成立**，但代价 ≈ 一个常驻 binder 服务 + sepolicy 补丁 + VINTF 文件覆盖 + 开机时序竞争；
换来的是**去掉 P1/P2 两个硬编码偏移**，而"让 HAL 原生携带 V5"这个目的在软件编码通路下**收益为零**（§2.3）。
若目的是 D3（消除硬编码偏移/提升可维护性）→ 值得做；若目的是 (丙)"HAL 原生 V5" → 不值得做。

---

## 1. (a) 栈要选 AIDL，需要探测到什么

### 1.1 选路开关：`vendor::mediatek::bluetooth::audio::HalVersionManager::HalVersionManager()` @0x861370

我自己反汇编的完整控制流（`scripts/d1/d1_halver.py`，输出 `raw/d1_halver.txt`）：

```asm
; ---- 1) 探测 #1：MTK AIDL 名 ----
0x861410  strh     wzr, [x19, #0x28]                 ; hal_version_ = 0, [0x29] = 0
0x861424  bl       #0xf4f5b0    ; AServiceManager_checkService   <-- 运行时注册表
0x861428  cbz      x0, #0x861534                      ; 未注册 -> 去探测 #2
0x86142c  mov      w8, #3
0x861430  strb     w8, [x19, #0x28]                  ; hal_version_ = 3  （MTK AIDL）
0x861434  ...                                          ; 继续走 HIDL 探测（只写 [0x29]，见 0x861634 cbnz w9 保留 3）

; ---- 2) 探测 #2：AOSP AIDL 名（仅在探测 #1 失败时到达）----
0x861534  adrp/add x8, #0xff42c0                      ; 静态 std::string（AOSP 名）
0x86154c  bl       #0xf4f5b0    ; AServiceManager_checkService
0x861550  cbz      x0, #0x861434                      ; 未注册 -> 走 HIDL 2.2 探测
0x861554  mov      w8, #0x404
0x861558  strh     w8, [x19, #0x28]                  ; hal_version_ = 4, [0x29] = 4（AOSP AIDL）
0x86155c  b        #0x861844                          ; ★ 立即 return

; ---- 3) HIDL 兜底 ----
0x861490  bl defaultServiceManager1_2()
0x861514  blr x9   ; IServiceManager::listManifestByInterface("…mediatek…@2.2::IBluetoothAudioProvidersFactory", cb)
0x861634  mov w8,#2 ; strb w8,[x19,#0x29] ; cbnz w9,->0x861820   ; [0x28] 已非 0 则保留
0x861644  strb w8,[x19,#0x28]                          ; 否则 hal_version_ = 2
0x86164c  … listManifestByInterface("…mediatek…@2.1::…")   ; 命中 -> hal_version_ = 1
0x8617c8  … "No supported HAL version"
```

**两个 AIDL 服务名的字面值 —— 独立解析**（`scripts/d1/d1_gsub.py` / `d1_gsub2.py`）：

静态初始化 `_GLOBAL__sub_I_hal_version_manager.cc` @0x8618f0 用 GOT 槽取 `descriptor` 指针再 `append("/default")`：

```
$ llvm-readelf -r libbluetooth_jni_orig.so | grep -E "f8e860|f8e898"
0x00f8e860 R_AARCH64_GLOB_DAT  _ZN4aidl6vendor8mediatek8hardware9bluetooth5audio30IBluetoothAudioProviderFactory10descriptorE
0x00f8e898 R_AARCH64_GLOB_DAT  _ZN4aidl7android8hardware9bluetooth5audio30IBluetoothAudioProviderFactory10descriptorE
```

| 静态 std::string | 构造点 | 字面值 |
|---|---|---|
| `0xff42a8`（探测 #1） | 0x861918–0x861958 ← GOT 0xf8e860 | `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` |
| `0xff42c0`（探测 #2） | 0x8619b4–0x8619fc ← GOT 0xf8e898 | `android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` |

> 这解决了 R1 遗留的"未验证：`0xff42c0` 第二个 AIDL 探测的服务名"。

**结论（a-1）**：**注册 AOSP 名的 AIDL 服务 → `hal_version_ = 4`，且是 early-return**。
注册 MTK 名 → `hal_version_ = 3`。两者都注册 → **MTK 名优先**（探测 #1 在前），所以**只注册 AOSP 名**。

### 1.2 ★ 关键修正：`hal_version_` → transport 映射（R1/R2 此处有误）

`vendor::mediatek::bluetooth::audio::HalVersionManager::GetHalTransport()` @0x860de0（`scripts/d1/d1_transport2.py`）：

```asm
0x860e0c  ldrb  w20, [x8, #0x28]          ; w20 = hal_version_
0x860e14  lsl   x8, x20, #3               ; x8 = hal_version_ * 8
0x860e18  mov   x9, #0x300
0x860e1c  movk  x9, #0x203, lsl #16
0x860e24  movk  x9, #4,     lsl #32       ; x9 = 0x00000004_02030300
0x860e20  cmp   x20, #5
0x860e28  lsr   x8, x9, x8                ; 字节抽取（调用方 & 0xff）
0x860e2c  csel  w0, w8, wzr, lo
```

逐字节：`hal_version_ = 0→0x00, 1→0x03, 2→0x03, 3→0x02, 4→0x04`（≥5 → 0）。

分发器 `vendor::mediatek::bluetooth::audio::a2dp::init()` @0x824ed0（同一模式出现在 `setup_codec`/`is_hal_enabled`/`is_hal_offloading`/…）：

```asm
0x824ee4  bl GetHalTransport ; and w8,w0,#0xff ; cmp w8,#4 ; b.ne 0x824f08
0x824f04  b  #0xf4ec10   ; transport==4 -> bluetooth::audio::a2dp::init            （AOSP AIDL）
0x824f14  cmp w8,#3 ; b.ne 0x824f2c
0x824f28  b  #0xf4e6c0   ; transport==3 -> vendor::mediatek::…::hidl::a2dp::init    （HIDL）
0x824f38  b  #0xf4e0a0   ; else(0/2)    -> vendor::mediatek::…::aidl::a2dp::init    （MTK AIDL）
```

| `hal_version_`(+0x28) | 含义 | transport | 后端（同一命名空间的整套 a2dp 实现） |
|---|---|---|---|
| 1 | HIDL 2.0 | 3 | `vendor::mediatek::bluetooth::audio::hidl::a2dp` |
| 2 | HIDL 2.1 / MTK 2.2 | 3 | 同上（`setup_codec` @0x825ae0，P1 跳转表所在） |
| **3** | **MTK AIDL** | **2** | `vendor::mediatek::bluetooth::audio::aidl::a2dp`（`setup_codec` @0x8378f0） |
| **4** | **AOSP AIDL** | **4** | `bluetooth::audio::aidl::a2dp`（`setup_codec` @0x862750） |

> **修正 R1 §(g)A**：R1 写"`hal_version_ = 3 (AIDL_V1)`"是对的，但没写 3/4 各自对应**不同的两套 AIDL 后端**；
> 也没指出 transport 值（3=HIDL、2=MTK AIDL、4=AOSP AIDL），因而无法判断"注册哪个名字会走哪条后端"。

**结论（a-2）**：注册 **AOSP 名** → 走 `bluetooth::audio::aidl::*`，即 AOSP 标准 AIDL 后端，
其 V5 转换器是 `bluetooth::audio::aidl::codec::A2dpLhdcv5ToHalConfig` @0x870b80（`CodecType::VENDOR` + `ParcelableHolder` 逃生口）。

### 1.3 数据面第二道闸门：`AServiceManager_isDeclared`（VINTF）

`is_aidl_available()` 是两个 28 字节的尾调用（`scripts/d1/d1_aidl_avail.py`）：

```asm
0x84dc00  adrp x8,#0xf8e000 ; ldr x8,[x8,#0x790]   ; MTK: kDefaultAudioProviderFactoryInterface @0xff3f70
0x84dc18  b #0xf4f2d0                              ; AServiceManager_isDeclared      ← MTK AIDL
0x869210  adrp x8,#0xf8e000 ; ldr x8,[x8,#0x8a0]   ; AOSP: kDefaultAudioProviderFactoryInterface @0xff42e0
0x869228  b #0xf4f2d0                              ; AServiceManager_isDeclared      ← AOSP AIDL
```

两个静态服务名各自的构造点（`scripts/d1/d1_gotusers.py`）：
- `__cxx_global_var_init.7` @0x8371a0 ← GOT 0xf8e860（**MTK** descriptor）→ 0xff3f70
- `__cxx_global_var_init.3` @0x861fa0 ← GOT 0xf8e898（**AOSP** descriptor）→ 0xff42e0

→ **每个 AIDL 后端用自己包名的 descriptor + "/default"**，与 §1.1 的探测名一一对应（自洽）。

`AServiceManager_isDeclared` 的语义（AOSP 源码，本地副本 `reference/aosp-src/fwnative/`）：

```cpp
// ndk_service_manager.cpp:165
bool AServiceManager_isDeclared(const char* instance) { return defaultServiceManager()->isDeclared(String16(instance)); }
// svcmgr.cpp:518
Status ServiceManager::isDeclared(const std::string& name, bool* outReturn) {
    auto ctx = mAccess->getCallingContext();
    if (!mAccess->canFind(ctx, name)) return Status::fromExceptionCode(Status::EX_SECURITY, "SELinux denied.");
    *outReturn = isVintfDeclared(name);        // ← 读 VINTF manifest（device + framework）
}
```

即：**`isDeclared` = SELinux `find` 放行 ∧ VINTF manifest 里存在该 `<pkg>.<iface>/<instance>`**。

**失败模式（已验证）**：`bluetooth::audio::aidl::a2dp::init()` @0x8621e4：

```asm
0x8621e4  bl is_aidl_available()
0x8621e8  tbz w0,#0,#0x8623d0
0x8623d0  … logging::LogMessage(…, 0x1ce /*=462*/, WARNING)   ; "init" + ": BluetoothAudio AIDL implementation does not exist"
0x862424  b 0x862548                                           ; source = nullptr
```

字符串实证：`0x1efd1a` = `": BluetoothAudio AIDL implementation does not exist"`，
文件路径串 `0x25bedd` = `vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/audio_hal_interface/aidl/a2dp_encoding_aidl.cc`。

→ **若只让 `checkService` 成功而不做 VINTF 声明，栈会选中 AIDL 通路但音频 HAL 初始化失败，A2DP 直接没声音**（比现状更糟）。
这是本路线**最危险的失败模式**。

### 1.4 服务端：`addService` 也要求 VINTF 声明

```cpp
// fwnative/svcmgr.cpp:221
static bool meetsDeclarationRequirements(const sp<IBinder>& binder, const std::string& name) {
    if (!Stability::requiresVintfDeclaration(binder)) return true;
    return isVintfDeclared(name);
}
// svcmgr.cpp:357  ServiceManager::addService(...) { ... if (!meetsDeclarationRequirements(binder, name)) return EX_ILLEGAL_ARGUMENT; }
// fwnative/Stability.cpp:68  requiresVintfDeclaration = check(getRepr(binder), Level::VINTF)
```

AIDL 生成代码对 `@VintfStability` 接口的 `BnXxx` 构造会自动 mark VINTF ⇒ 用官方接口库实现的 shim
**必然**是 VINTF-stable ⇒ `addService` 必然要求 manifest 条目。**VINTF 无法绕过（除非自己手搓非 VINTF binder，风险见 §4.3）。**

### 1.5 (a) 条件清单

| # | 条件 | 必要性 | 证据 |
|---|---|---|---|
| C1 | servicemanager 中存在 AIDL 服务 `android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default`，且**在 `com.android.bluetooth` 加载 `libbluetooth_jni.so` 之前**完成注册 | 必需（选路） | 0x861534 `checkService` → `strh #0x404` |
| C2 | 该服务在 **VINTF manifest** 中声明为 `format="aidl"`，`<name>android.hardware.bluetooth.audio</name>`，`<fqname>IBluetoothAudioProviderFactory/default</fqname>` | 必需（数据面 + addService） | `isDeclared`；`addService`→`meetsDeclarationRequirements` |
| C3 | 服务实现 AOSP AIDL **V3** 接口（`android.hardware.bluetooth.audio-V3-ndk.so`，APEX 内现成） | 必需 | `libbluetooth_jni.so` 的 `DT_NEEDED` 实测含 `android.hardware.bluetooth.audio-V3-ndk.so` |
| C4 | 调用域对 `hal_audio_service` 有 `service_manager add`（`bluetooth` 侧已有 `find`） | 必需（SELinux） | CIL L9758/L9759/L19892 |
| C5 | `persist.bluetooth.bluetooth_audio_hal.disabled` 未设/为 false | 必需 | 字符串 @0x2a22ac；设备实测为空 |
| C6 | 任何 `ro.*`/`persist.*` 属性？ | **不需要** | ctor 0x861370–0x861874 无属性调用 |
| C7 | **不**注册 MTK 名（否则 MTK AIDL 优先，走 transport 2 的另一套后端 + 无 service_contexts 条目） | 建议 | 0x861424 早于 0x861534 |

---

## 2. (b) AIDL 服务要实现什么 / 纯转发 shim 可行性

### 2.1 两个候选接口的方法集（从接口库 dynsym 实测）

**方案 A（推荐）：AOSP 名 + AOSP AIDL V3** —— 接口库 `android.hardware.bluetooth.audio-V3-ndk.so`（APEX 内，183792 B）

`IBluetoothAudioProviderFactory`（2 个业务方法）：
```aidl
AudioCapabilities[] getProviderCapabilities(in SessionType sessionType);
IBluetoothAudioProvider openProvider(in SessionType sessionType);
```
`IBluetoothAudioProvider`（6 个，AOSP 源码 `hwif/bluetooth/audio/IBluetoothAudioProvider.aidl` 原文）：
```aidl
void endSession();
MQDescriptor<byte, SynchronizedReadWrite> startSession(in IBluetoothAudioPort hostIf,
        in AudioConfiguration audioConfig, in LatencyMode[] supportedLatencyModes);
void streamStarted(in BluetoothAudioStatus status);
void streamSuspended(in BluetoothAudioStatus status);
void updateAudioConfiguration(in AudioConfiguration audioConfig);
void setLowLatencyModeAllowed(in boolean allowed);
```
`IBluetoothAudioPort`（**由栈实现，shim 只调用**）：`startStream(bool)`、`suspendStream()`、`stopStream()`、
`getPresentationPosition()`、`updateSourceMetadata()`、`updateSinkMetadata()`、`setLatencyMode()`。

**方案 B：MTK 名 + MTK AIDL V1** —— 接口库 `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`（APEX 内，188040 B）
实测导出（`llvm-readelf --dyn-syms` + `llvm-cxxfilt`）：

```
IBluetoothAudioProviderFactoryDefault::getProviderCapabilities(SessionType, vector<AudioCapabilities>*)
IBluetoothAudioProviderFactoryDefault::openProvider(SessionType, shared_ptr<IBluetoothAudioProvider>*)
IBluetoothAudioProviderDefault::startSession(shared_ptr<IBluetoothAudioPort>, AudioConfiguration,
        vector<LatencyMode>, MQDescriptor<int8_t,SynchronizedReadWrite>*)
IBluetoothAudioProviderDefault::streamStarted(BluetoothAudioStatus)
IBluetoothAudioProviderDefault::streamSuspended(BluetoothAudioStatus)
IBluetoothAudioProviderDefault::updateAudioConfiguration(AudioConfiguration)
IBluetoothAudioProviderDefault::setLowLatencyModeAllowed(bool)
IBluetoothAudioProviderDefault::endSession()
IBluetoothAudioProviderDefault::enterGameMode(bool)        ← MTK 私有扩展
IBluetoothAudioProviderDefault::updataConnParam(ConnParam)  ← MTK 私有扩展（MTK 自己的拼写错误）
```
`IBluetoothAudioPortDefault`（MTK）：`startStream(bool)`、`suspendStream()`、`stopStream()`、
`getPresentationPosition()`、`updateSourceMetadata()`、`updateSinkMetadata()`、`setLatencyMode()`、`enterGameMode(bool)`。

> **两套接口都是"~8 个方法"量级**，实现成本低。方案 A 的优势：
> ① `service_contexts` 已有 `hal_audio_service` 条目（方案 B 的 MTK 名落 `default_android_service`，全策略无 allow）；
> ② 接口 `.aidl` 公开可查（MTK 的 parcelable 布局只能反推）。

### 2.2 转发映射（AIDL → 现有 HIDL 厂商服务）

shim 内部持有 `vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory/default`
（HIDL，hwservicemanager，注册在 **pid 1006**）的代理对象。

| AIDL（栈 → shim） | HIDL（shim → 厂商服务） | 说明 |
|---|---|---|
| `getProviderCapabilities(sessionType)` | `getProviderCapabilities_2_1(sessionType)` | HIDL `AudioCapabilities_2_1` → AIDL `AudioCapabilities`（`pcmCapabilities`/`codecCapabilities` 逐字段搬） |
| `openProvider(sessionType)` | `openProvider(sessionType)` | 返回 `V2_2::IBluetoothAudioProvider` 代理，包装成 AIDL provider |
| `startSession(hostIf, cfg, latencies)` | `startSession_2_1(hidlHostIf, hidlCfg)` | **`hostIf` 需要方向转换**：shim 实现一个 HIDL `IBluetoothAudioPort`，把回调转发给栈的 AIDL port（`startStream`/`suspendStream`/`stopStream`/`getPresentationPosition`/`updateMetadata`） |
| `endSession()` | `endSession()` | 1:1 |
| `streamStarted/st.../updateAudioConfiguration/setLowLatencyModeAllowed` | 无对应（HIDL 2.1 接口没有） | 记录/忽略；`setLowLatencyModeAllowed` 在 HIDL 侧本来就是空操作（R8 D1） |
| `MQDescriptor<byte,SRW>` 返回值 | HIDL `fmq_sync<uint8_t>` 出参 | **需描述符转换**（§2.4） |

### 2.3 ★ V5 的 `Lhdcv5Configuration` 如何映射到 HIDL `lhdcConfig` —— 会丢什么

先要澄清一个**前提性问题**：软件编码通路下**根本不会发生这个映射**。

R8 的决定性结论（我复核了调用链）：
- `setup_codec()` 的 SW 分支只把 `pcmConfig` 装进 `AudioConfiguration` 发给 HAL；`codecConfig` 只用于 `IsCodecOffloadingEnabled()` 判定。
- 而本机 `persist.bluetooth.a2dp_offload.cap` 为空 / `a2dp_source_offload_capability_mask: 0`（R8 实测），走的是 `A2DP_SOFTWARE_ENCODING_DATAPATH`。

所以：

| 通路 | 送进 HAL 的东西 | AIDL vs HIDL 差异 |
|---|---|---|
| **软件编码（本机实际）** | 仅 `pcmConfig{sampleRate, channelMode, bitsPerSample}` | **逐字节相同**。V5 的 `Lhdcv5Configuration` 从不进入 HAL |
| 硬件卸载（本机不适用） | `codecConfig` | AIDL 走 `CodecType::VENDOR(7)` + `VendorConfiguration{vendorId, codecId, ParcelableHolder(Lhdcv5Configuration)}`；HIDL 只能映射到 `LhdcParameters{sampleRate, channelMode, bitsPerSample, isLLEnabled}`（8 字节，无版本字段）→ **版本、码率档、Lossless/JAS/META/AR 特性位全丢** |

**结论**：本路线的价值**不在**"V5 配置进 HAL"（软件通路下那是伪需求，R8 已证），
而在于**栈侧不再需要把 V5 伪装成 V3**：

- 现状（P1+P2）：`a2dp_get_selected_hal_codec_config` 用 HIDL 版，`codec_type=12` 无分支 → 必须
  P1 把 `table[12]` 改指向 `A2dpLhdcV3ToHalConfig`、P2 把 `codec_type` 12→10 才骗过它。
- AIDL 通路：MTK AIDL 跳转表 `@0x2c577d` 的 `[12]` **本来就是** `A2dpLhdcv5ToHalConfig`（§2.5 复核），
  AOSP AIDL 更是 if/else 链直调 V5 → **P1、P2 都不再需要**。

### 2.4 音频数据通路：HIDL 厂商 HAL 自己创建 FMQ，AIDL shim 如何让它继续工作

**数据通路实测拓扑（R3/R7 + 本轮复核）**：

```
audioserver (pid 1109, audioserver)
   │ HIDL audio 7.1 IDevicesFactory::openDevice("bluetooth")
   ▼
android.hardware.audio.service.mediatek (pid 1006, mtk_hal_audio)
   ├─ /vendor/lib64/hw/audio.bluetooth.default.so   ← 音频 HAL module = PCM 生产者
   ├─ /vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so (=hal22.so) ← HIDL provider
   └─ /vendor/lib64/libbluetooth_audio_session_mediatek.so  ← 进程内会话/FMQ 单例
   ▲ hwbinder
com.android.bluetooth (pid 2688, bluetooth)  ← libbluetooth_jni.so = PCM 消费者
```

**关键实测（本轮新取证，`llvm-readelf -d`）**：

```
audio.bluetooth.default.so NEEDED:
  vendor.mediatek.hardware.bluetooth.audio@2.1.so
  vendor.mediatek.hardware.bluetooth.audio@2.2.so
  libbluetooth_audio_session_mediatek.so      ← ★ HIDL 版会话库
  libfmq.so  libhidlbase.so  libutils.so …
  （无 libbinder_ndk.so、无 android.hardware.bluetooth.audio-V3-ndk.so、无 libbluetooth_audio_session_aidl.so）
```

```
$ adb shell su -c "ls /apex/com.android.btservices/lib64/ | grep -i session"   → （空）
$ adb shell su -c "ls /vendor/lib64/ | grep -i session"
libbluetooth_audio_session.so
libbluetooth_audio_session_mediatek.so
```

→ **本机不存在任何 AIDL 版会话库；音频 HAL module 是 HIDL-only 硬绑定。**

**FMQ 三方流向（AOSP 源码 + 符号双重确认）**：

| 角色 | 谁 | 依据 |
|---|---|---|
| FMQ **创建者** | HIDL provider（hal22.so，pid 1006） | `2.1/IBluetoothAudioProvider.hal:60` `startSession_2_1(...) generates (Status, fmq_sync<uint8_t> dataMQ)`；AIDL `IBluetoothAudioProvider.aidl` 的 `startSession` 同样**返回** MQDescriptor |
| FMQ **交给 module** | 进程内函数调用 | hal22.so 的 `UND` 符号实测：`android::bluetooth::audio::BluetoothAudioSession_2_1::OnSessionStarted(sp<V2_1::IBluetoothAudioPort>, const MQDescriptor<uint8_t,kSynchronizedReadWrite>*, const V2_2::AudioConfiguration&)` |
| FMQ **写入者** | 音频 HAL module | `device_port_proxy.cc:527` `BluetoothAudioPortAidlOut::WriteData → BluetoothAudioSessionControl::OutWritePcmData`；HIDL 版 `device_port_proxy_hidl.cc:510` 同形；设备侧 `BluetoothAudioSession::OutWritePcmData` @0xf044 |
| FMQ **读取者** | BT 栈 | 栈内 `MessageQueueBase<…>::read` 两个实例化实测存在：`…<MQDescriptor,unsigned char,1>::read` @0x832a50（HIDL）与 `…<AidlMQDescriptorShim,signed char,1>::read` @0x8509a0（AIDL） |

**★ 这就是"纯转发 shim"可行的原因**：

```
BT 栈 ──AIDL startSession──▶ shim ──HIDL startSession_2_1──▶ hal22.so (pid 1006)
                                                              ├─ 创建 FMQ (DataMQ)
                                                              ├─ 进程内 OnSessionStarted(hostIf_hidl, &mqDesc, cfg)
                                                              │     └─▶ module 之后从会话单例拿到同一 FMQ → 写 PCM
                                                              └─ 返回 mqDesc ──▶ shim
BT 栈 ◀──AIDL 返回 MQDescriptor（同一 ashmem 区域）──────────────── shim（仅做描述符重打包）
```

- shim **不需要**自己创建 FMQ，**不需要**碰音频输出流，**不需要**和 audioserver 打交道。
- 它唯一要做的"数据面"工作是：把 HIDL `MQDescriptor<uint8_t,kSynchronizedReadWrite>` **重打包**成
  AIDL `MQDescriptor<int8_t,SynchronizedReadWrite>`（字段：`handle`(fd) / `quantum` / `flags` / `grantors[]`）。
- **可行性证据**：libfmq 自己提供了 `android::details::AidlMQDescriptorShim` —— 设备栈里同时存在
  `MessageQueueBase<MQDescriptor,…>` 与 `MessageQueueBase<AidlMQDescriptorShim,…>` 两个实例化，
  说明两种描述符**在 `MessageQueueBase` 层面结构可互换**（同一 `libfmq.so`，被 `libbluetooth_jni.so` 与
  `audio.bluetooth.default.so` 共同 NEEDED）。设备侧 `android.hardware.common.fmq-V1-ndk.so` 里唯一导出的
  类型是 `GrantorDescriptor{fdIndex, offset, extent}`（实测），印证 AIDL MQDescriptor 的 grantors 字段。
- **残留风险（中等）**：FMQ 的 grantor / event-flag 语义在跨描述符重打包时是否完整保留 —— 需要真机验证。
  缓解：优先用 libfmq 自身的构造路径（`AidlMessageQueue` 从 fd 构造），而不是手写 parcel。

### 2.5 复核：AIDL 通路里 codec_type=12 被正确路由（无需任何补丁）

我自己解码了两张跳转表（`scripts/d1/d1_table.py`）：

**MTK AIDL** `setup_codec` @0x8378f0：`cmp w8,#0xe` / 表 `@0x2c577d` / anchor `0x83798c` / `target = anchor + b*4`

```
bytes: 00 34 39 39 43 48 48 48 48 5e 3e 48 3e 00 34
 [ 0] → A2dpSbcToHalConfig     [ 4] → A2dpLdacToHalConfig    [ 9] → A2dpLhdcV2ToHalConfig
 [ 1] → A2dpAacToHalConfig     [ 5..8] → 错误分支            [10] → A2dpLhdcv5ToHalConfig  ★
 [ 2][3] → A2dpAptxToHalConfig [11] → 错误分支               [12] → A2dpLhdcv5ToHalConfig  ★
 [13][14] → SBC/AAC 回落
```

**HIDL（对照）** `setup_codec` @0x825ae0：表 `@0x2c5620` / anchor `0x825f34`

```
bytes: 00 26 46 46 4b 5a 5a 5a 5a 50 55 5a 5a 00 26
 [10] → A2dpLhdcV3ToHalConfig   [12] → 0x82609c 错误分支（line 359）   ← 这就是 P1 要打补丁的位置
```

**AOSP AIDL** `bluetooth::audio::aidl::a2dp::setup_codec` @0x862750（2232 B）—— **无跳转表，是平坦 if/else 链**
（`scripts/d1/d1_aosp2.py`）：

```asm
0x862928  bl  #0xf4f840   ; bluetooth::audio::aidl::codec::A2dpLhdcv5ToHalConfig(aidl::android::…::CodecConfiguration*, …)
0x86292c  tbz w0,#0,#0x8628a8
（同段内并列：A2dpAptx / A2dpAac / A2dpLdac / A2dpOpus / A2dpLhdcV2 ToHalConfig）
```

→ **两条 AIDL 通路 `codec_type=12` 都原生指向 V5 转换器，P1/P2 完全不需要**。
（AOSP AIDL 的 V5 转换器 @0x870b80 的签名实测为
`A2dpLhdcv5ToHalConfig(aidl::android::hardware::bluetooth::audio::CodecConfiguration*, …)`，
即写入 AOSP 标准 `CodecConfiguration`，配合 `CodecType::VENDOR(7)` + `VendorConfiguration` 逃生口。）

### 2.6 (b) 小结

| 子问题 | 答案 |
|---|---|
| 能做成纯转发 shim 吗 | **能**（对软件编码通路而言是完整的）。需要额外实现：AIDL 侧 10 个方法 + HIDL 侧 1 个 `IBluetoothAudioPort` 回调转发 + 1 处 MQDescriptor 重打包 |
| V5 配置映射丢什么 | 软件通路**不传** codec 配置（无损也无意义）；卸载通路会丢版本/码率/特性位（但本机不走卸载） |
| 数据通路怎么办 | **完全不用管**。FMQ 仍由 pid 1006 的 HIDL provider 创建并进程内交给 module，shim 只是把描述符原样转给栈 |

---

## 3. (c) 不能纯转发的部分 / 最小实现范围

**能纯转发的部分**（≈95%）：工厂 + provider 的 10 个方法、会话生命周期、控制回调。

**不能纯转发、必须自己实现的**：

| # | 项 | 为什么必须自己做 | 最小实现 |
|---|---|---|---|
| I1 | AIDL 侧 `IBluetoothAudioPort` **不需要**实现（栈提供） | —— | —— |
| I2 | HIDL 侧 `V2_1::IBluetoothAudioPort` **需要 shim 实现** | HIDL `startSession_2_1` 的入参是 HIDL port；module/HAL 会拿它回调 | 一个转发类，5 个方法转发到栈的 AIDL port（`startStream`/`suspendStream`/`stopStream`/`getPresentationPosition`/`updateMetadata`） |
| I3 | `MQDescriptor` 重打包 | HIDL 出参类型 ≠ AIDL 返回类型 | fd + quantum + flags + grantors 逐字段搬（§2.4） |
| I4 | 服务注册 + 生命周期 | `addService` / 死亡监听 / 重启 | `AServiceManager_addService`；BT 侧重启后 `checkService` 已缓存，shim 必须比 BT 进程活得久 |
| I5 | **SELinux 放行** | 见 §4.2 | sepolicy 补丁 |
| I6 | **VINTF 声明** | 见 §4.3 | 文件覆盖 |
| I7 | `getInterfaceVersion`/`getInterfaceHash` | AIDL 生成代码自带（若用官方 `BnXxx` 则自动） | 免费 |
| I8 | 音频输出流 / 与 audioserver 的关系 | **完全不需要**。audioserver 只与 pid 1006 的音频 HAL module 打交道，与 AIDL 蓝牙 HAL 无直接关系 | —— |

**最小实现范围**：一个 `/data/adb/…` 下的可执行文件（或注入 pid 1006 的 .so），
链接 `android.hardware.bluetooth.audio-V3-ndk.so` + HIDL `vendor.mediatek…@2.2.so` + `libbinder_ndk` + `libhidlbase`，
代码量估计 **600–1200 行 C++**（含 parcelable 映射）。

---

## 4. (d) 落地工程问题

### 4.1 服务进程放哪

| 方案 | 可行性 | 评价 |
|---|---|---|
| **D-a. 独立进程（`/data/adb/.../lhdcv5-aidlshim`）** | ✔ 推荐 | 最简单、可调试、可重启。转发路径：`binder`(栈↔shim) + `hwbinder`(shim↔pid 1006)。**SELinux 需补丁**（域不是 `hal_audio_server`） |
| D-b. 注入 pid 1006（音频 HAL 服务） | ✔ 更优雅但更难 | 域天然是 `mtk_hal_audio` → `add` 免补丁；且可省掉 hwbinder 一跳（直接进程内调 `hal22.so` 的 provider）。落地手段：KernelSU 模块 bind-mount 一个改过的 `libbluetooth_audio_session_mediatek.so`（pid 1006 与 init 同 mount ns，R3 已证），在其 `__attribute__((constructor))` 里注册服务。**风险：改厂商 .so + 依赖文件覆盖能力** |
| D-c. 注入 BT 进程 | ✘ | 与"不碰 libbluetooth_jni.so"的初衷冲突 |
| D-d. 复用现有进程（`android.hardware.bluetooth@1.1-service-mediatek`, pid 1007） | ✘ | 域 `mtk_hal_bluetooth`，且与 pid 1006 不同进程 → 拿不到会话单例；无收益 |

> 注意：**不能**把 shim 做成"自己创建 FMQ"的独立实现 —— 那样 module 拿不到 FMQ（会话单例在 pid 1006）。
> 这是"必须转发给 HIDL provider"的**硬约束**。

### 4.2 SELinux（实测）

`plat_service_contexts`（设备实测，R7 已落盘）：

```
android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default   u:object_r:hal_audio_service:s0
*                                                                        u:object_r:default_android_service:s0
```

CIL 规则（我自己解析 `analysis/raw/r7_{plat,vendor}_sepolicy.cil`，正则 `\(allow (\S+) (default_android_service|hal_audio_service|hal_bluetooth_service)\S* \(service_manager \(([^)]*)\)\)`）：

```
plat: allow hal_audio_client   -> hal_audio_service (service_manager (find))
plat: allow hal_audio_server   -> hal_audio_service (service_manager (add find))
plat: allow bluetooth          -> hal_audio_service (service_manager (find))     ← 栈侧 find 已放行
plat/vendor: （default_android_service 的 allow 规则 = 0 条，只有 neverallow）
```

- **AOSP 名**：命中 `hal_audio_service`。`add` 需要调用域 ∈ `hal_audio_server`（本机 = `mtk_hal_audio`，R7 vendor CIL L592）。
  独立进程（magisk/su 域）→ **需补 `(allow <域> hal_audio_service (service_manager (add find)))`**。
- **MTK 名**：只命中通配 `default_android_service`，而**全策略（plat + vendor）没有任何 allow 规则** →
  `add` 和 `find` **双双被拒**，连注册都过不去。→ 这是选择方案 A 的第二个理由。

补丁手段：KernelSU `sepolicy.rule` —— **本机已在用**（`tricky_store` / `LibNoActive` / `zygisk_vector` 三个在用模块均有该文件，实测）。

### 4.3 VINTF 声明（本路线最大障碍）

**要求**：`/vendor/etc/vintf/manifest.xml` 或 `/vendor/etc/vintf/manifest/*.xml`（fragment 目录**存在**，实测）
中加入：
```xml
<hal format="aidl">
    <name>android.hardware.bluetooth.audio</name>
    <fqname>IBluetoothAudioProviderFactory/default</fqname>
</hal>
```
（`/system/etc/vintf/manifest/` 也有 fragment 目录；framework manifest 同样会被 `isVintfDeclared` 查询。
`/apex/com.android.btservices/etc/vintf/` **不存在**，无 APEX 侧入口。）

**候选手段**：

| 手段 | 状态 | 说明 |
|---|---|---|
| M1. KernelSU 模块 `system/vendor/etc/vintf/manifest/xxx.xml`（magic mount 覆盖） | ⚠ **未验证，有负面证据** | 本机唯一带 `system/` 目录的模块 `systemless-fcm-hosts` **实测未生效**：`/system/etc/hosts` 仍是原版 56 B（模块版 443 B）；且 adbd/init/servicemanager 同属 `mnt:[4026533766]`，不存在命名空间遮蔽的解释。**必须先单独验证 KernelSU 文件覆盖在本机是否可用** |
| M2. 模块 `post-fs-data.sh` 里显式 `mount --bind`（新文件 bind 到 `/vendor/etc/vintf/manifest/lhdcv5.xml`） | ⚠ 未验证 | 关键：mount 必须作用在**全局挂载命名空间**（init 的 `4026533766`）。servicemanager(pid 482) 与 pid 1006 **共享**该 ns（实测），故一旦挂上，**已启动的 servicemanager 也能立刻看到** |
| M3. 走 `/odm` 或 `/product` 的 vintf 目录 | ✘ | 同样只读；`/product` 已是 mi_ext overlayfs，lowerdir 不可改 |
| M4. 在 shim 里手搓**非 VINTF-stable** binder 以绕过 `addService` 的 manifest 检查 | ✘/⚠ | 需放弃官方 `BnXxx`（自己 `AIBinder_Class_define`）。但栈侧仍会调 `isDeclared`（VINTF）→ **数据面还是过不去**；且 libbinder 的 stability 检查可能拒绝。**不解决问题** |
| M5. 内存补丁 `AServiceManager_isDeclared` 的 GOT 槽（类似 P0 手法） | ✔ 一定能成，但违背本路线初衷 | 只留 1 个补丁点替代 P1+P2；但如果已经要打补丁，P1+P2 方案更省事 |

**时序**：`isVintfDeclared` 读的 manifest 由 servicemanager 缓存（`VintfObject` 单例），
但首次读取发生在第一次 `isDeclared`/`addService`（VINTF 类）调用 —— 即 BT 进程启动时（开机后 ~22 s，实测见 §4.4），
**远晚于** post-fs-data（模块挂载时机）。⇒ **只要 M1/M2 能挂上，时序不是问题**。

### 4.4 开机时序（实测）

```
$ adb shell su -c "ps -A -o PID,ETIME,NAME | grep -E '(^ *1 |com.android.bluetooth|servicemanager)'"
    1  01:35:05 init
  482  01:35:00 servicemanager
 1006  01:34:55 android.hardware.audio.service.mediatek
 2688  01:34:43 com.android.bluetooth
```

- `com.android.bluetooth` 比 init 晚 **~22 s** 启动；`libbluetooth_jni.so` 的静态初始化
  （`_GLOBAL__sub_I_hal_version_manager.cc` @0x8618f0 → ctor @0x861a64）在这一刻执行 → **这就是探测时刻**。
- KernelSU 模块 `service.sh`（late_start）通常在开机数秒内执行 → **有 15 s 以上余量**；
  用 `post-fs-data.sh` + 后台 `nohup` 更稳。
- shim 必须**先于** BT 进程注册；且必须在 BT 进程重启（`com.android.bluetooth` 崩溃/被系统重启）时仍然存活
  —— 否则 BT 重启后会退回 HIDL（hal_version_ 重新探测为 2），行为静默改变。

---

## 5. (e) 可行性结论 + 前置条件清单

### 5.1 结论

| 维度 | 判定 |
|---|---|
| **技术可行性** | **可行**。选路条件清晰且可满足；接口只有 ~10 个方法；数据面无需自建音频通路 |
| **架构风险** | 低-中。唯一实质技术不确定点是 MQDescriptor 重打包（§2.4 I3） |
| **工程风险** | **高**。VINTF 文件覆盖在本机**未验证且有负面证据**（§4.3 M1） |
| **收益** | 去掉 P1、P2 两个硬编码偏移；可能打开 LL 控制面（`setLowLatencyModeAllowed` 在 AIDL 下非空操作）。**但 P0 白名单补丁仍然必须保留** |
| **代价** | 新增常驻进程 + 600–1200 行 C++ + sepolicy 补丁 + VINTF 覆盖 + 时序守护 |
| **与"不改挂载"约束的兼容性** | **不兼容**。sepolicy 与 VINTF 都需要 root 方案改动系统分区视图 |
| **对比现状** | 现有 P0/P1/P2 内存补丁：3 个偏移、零新增进程、零 SELinux 改动。**在"少改动"这个维度上，现状方案更优** |

### 5.2 前置条件清单（逐项：难度 / 证据强度）

| # | 前置条件 | 难度 | 证据强度 | 备注 |
|---|---|---|---|---|
| P1 | 实现 AOSP AIDL V3 接口（工厂 + provider，10 方法） | 中 | **已验证**（接口库与方法集实测） | 可用官方 `BnXxx` 自动获得 `getInterfaceVersion` |
| P2 | 实现 HIDL `IBluetoothAudioPort` 转发类 | 低 | 推断 | HIDL 2.0/2.1 port 方法少 |
| P3 | MQDescriptor（HIDL ↔ AIDL）重打包 | 中 | 推断（`AidlMQDescriptorShim` 佐证） | 需真机验证 grantor/event-flag |
| P4 | 独立进程 + 自启动 + 存活守护 | 低 | — | `/data/adb` 可执行文件 |
| P5 | **sepolicy 放行** `add`/`find` `hal_audio_service` | 低 | **已验证**（CIL 实测 + 本机已有 3 个模块在用 `sepolicy.rule`） | KernelSU 支持 |
| P6 | **VINTF manifest 条目** | **高** | **已验证为必需**（源码 + 反汇编），**手段未验证**（负面证据） | 全路线唯一硬障碍 |
| P7 | 注册时机早于 BT 进程（开机 22 s 内） | 低 | **已验证**（进程 ETIME） | |
| P8 | 不注册 MTK 名（避免走 transport 2） | 低 | **已验证** | |
| P9 | `persist.bluetooth.bluetooth_audio_hal.disabled` 保持未设 | 低 | **已验证** | 设备实测为空 |
| P10 | **保留 P0 白名单补丁**（或改用 resetprop 伪造 `ro.product.name`） | —— | **已验证** | `ro.product.name` 全库仅 2 个读取点（0x6ec02c、0x76342c），与 HAL 代次解耦 |
| P11 | 保留 liblhdcv5 / liblhdcv5BT_enc 提供（KernelSU 模块） | 低 | 已有 | `A2dpCodecConfigLhdcV5Source::init()` 要求 `A2DP_VendorLoadEncoderLhdcV5()` |

### 5.3 建议

1. **不要为"让 HAL 原生携带 V5"做这条路线** —— 软件编码通路下 HAL 收不到 codec 配置，收益为零（§2.3）。
2. **若目标是消除硬编码偏移（D3）**：先做 **P6 的可行性验证**（单独测 KernelSU 文件覆盖），
   这是 go/no-go 判定点；其余 10 项都是常规工程量。
3. **更省的替代**：只把 P1/P2 的"表字节 + cmp 立即数"换成**基于模式扫描的定位**（在 libbluetooth_jni.so
   加载后按特征串/跳转表结构定位），可同时获得"抗 APEX 升级"和"零新增进程/SELinux/VINTF 改动"两个好处。
   —— 这条建议不在本任务范围，但它是 §5.1 权衡的直接推论。
4. **若接受 M5**（内存补丁 `isDeclared`）：则 VINTF 障碍消失，但此时补丁点从 2 个变成 1 个 + 一个常驻服务，
   综合仍不如现状。

---

## 6. 对既有报告的修正

| 既有结论 | 本轮复核 |
|---|---|
| R1 §(g)A "`hal_version_ = 3 (AIDL_V1)`" | ✅ 数值对，但**未区分两套 AIDL 后端**。实测：3 → transport 2 → `vendor::mediatek::…::aidl::*`；4 → transport 4 → `bluetooth::audio::aidl::*` |
| R1 "未知：`0xff42c0` 第二个 AIDL 探测的服务名" | ✅ **已解析**：`android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default`（GOT 0xf8e898 = AOSP descriptor） |
| R1 §(g)#3 "VINTF 声明：数据通路必需（版本选择不需要）" | ✅ **成立且更强**：`addService` **本身**也要求 VINTF 声明（`meetsDeclarationRequirements`），不只是客户端 `isDeclared` |
| R1 §(h) "vendor 侧需实现什么：…`audio.bluetooth.default.so` 必须支持 AIDL 版本的 session 接口" | ⚠ **修正**：**不需要**。纯转发 shim 下 FMQ 仍由 HIDL provider 在 pid 1006 创建并进程内交给现有 HIDL-only module；module 无需任何改动 |
| R7 §3.3 "`isDeclared` 才是 AIDL 服务能否被使用的闸门" | ✅ **成立**，且失败模式已精确到日志行：`a2dp_encoding_aidl.cc:462` `init: BluetoothAudio AIDL implementation does not exist`（`0x8623d0`） |
| R7 §3.2 "MTK 名注册会被 SELinux 拒" | ✅ **成立且更强**：`default_android_service` 在 plat+vendor CIL 中**连 `find` 的 allow 规则都没有**，不只 `add` |
| R2 §"AIDL MTK 表 0x2c577d [12]→V5" | ✅ **独立复算一致**（bytes `00 34 39 39 43 48 48 48 48 5e 3e 48 3e 00 34`） |
| R2/R4 "白名单与 HAL 代次解耦" | ✅ **独立复核一致**（`ro.product.name` 全库 2 个 xref） |
| R8 "最小充分改动集：栈层仅 table[12]→V3 转换函数 + 转换函数接受 12" | ✅ 成立。本报告补充：**若走 AIDL，这两处补丁都不需要**，但要多付一个服务进程 + SELinux + VINTF |

---

## 7. 已验证 / 推断 / 未知

**已验证（可复现的命令或反汇编）**
- 两个 AIDL 服务名的字面值与构造点（GOT 0xf8e860/0xf8e898 → 0xff42a8/0xff42c0）
- `hal_version_` → transport → 后端 的三级映射（0x860de0 表 + 0x824ed0 分发器）
- `is_aidl_available()` 两个实例化都尾调 `AServiceManager_isDeclared`（0xf4f2d0）
- `isDeclared` = SELinux find ∧ VINTF manifest（`svcmgr.cpp:518` / `ndk_service_manager.cpp:165`）
- `addService` 要求 VINTF 声明（`svcmgr.cpp:221/357` + `Stability.cpp:68`）
- 失败日志与行号（0x8623d0 → `a2dp_encoding_aidl.cc:462`）
- 两套 AIDL 接口的完整方法集（接口库 dynsym）
- `audio.bluetooth.default.so` 为 HIDL-only（DT_NEEDED 实测）
- 设备上无 `libbluetooth_audio_session_aidl.so`、无 AIDL BT audio 服务、无 APEX vintf 目录
- SELinux：`hal_audio_service` 的 add/find 归属；`default_android_service` 零 allow
- servicemanager / pid 1006 与 init 同 mount namespace；adbd 亦同
- 进程启动时序（BT 比 init 晚 22 s）
- `ro.product.name` 全库仅 2 个读取点
- 两张 codec_type 跳转表的完整解码

**推断（证据支持但非直接观测）**
- MQDescriptor 重打包的可行性（依据：libfmq 自带 `AidlMQDescriptorShim`；设备栈内两个 `MessageQueueBase` 实例化）
- HIDL `IBluetoothAudioPort` 的完整方法集（本地无 `2.0/IBluetoothAudioPort.hal`，据 AOSP 惯例与 2.1 注释推断）
- 独立进程方案下 hwbinder 转发的额外延迟可忽略
- KernelSU `sepolicy.rule` 在本机可用（依据：3 个在用模块持有该文件；**未实测生效**）

**未知 / 未验证**
- **KernelSU 模块文件覆盖在本机是否可用**（唯一 go/no-go 判定点；`systemless-fcm-hosts` 的负面证据）
- 本机 KernelSU 变体（`ksud 3.3.0`）的 magic mount 具体机制与失败原因
- AIDL FMQ 跨描述符重打包后 grantor / event-flag 语义是否完整
- 手搓非 VINTF binder 时 libbinder stability 检查的实际行为
- MTK AIDL parcelable 的字段名（`Lhdcv5Configuration` 等，二进制不可恢复）
- AIDL 通路下 `setLowLatencyModeAllowed` 是否能打通 LL（R8 曾实测 MTK AIDL 的 PCM 分支把 `isLowLatencyEnabled` 硬编码为 0）

---

## 8. 脚本与原始输出索引

| 文件 | 内容 |
|---|---|
| `analysis/scripts/d1/d1_halver.py` | MTK HalVersionManager ctor 全反汇编 → `raw/d1_halver.txt` |
| `analysis/scripts/d1/d1_gsub.py` / `d1_gsub2.py` | 静态初始化、GOT 槽、服务名字面值 |
| `analysis/scripts/d1/d1_gotusers.py` | 两个 descriptor GOT 槽的全部使用者 |
| `analysis/scripts/d1/d1_aidl_avail.py` / `d1_av2.py` | `is_aidl_available` / `GetAidlInterfaceVersion` |
| `analysis/scripts/d1/d1_xref4.py` | 通过 PLT stub 反查调用者 |
| `analysis/scripts/d1/d1_disp.py` | MTK a2dp 分发器（init/setup_codec/is_hal_enabled） |
| `analysis/scripts/d1/d1_transport2.py` | 两套 `GetHalTransport` |
| `analysis/scripts/d1/d1_aidl_init.py` / `d1_fail.py` | AIDL 初始化失败分支与日志字符串 |
| `analysis/scripts/d1/d1_table.py` | 两张 codec_type 跳转表全解码 |
| `analysis/scripts/d1/d1_aosp_aidl.py` / `d1_aosp2.py` / `d1_aosp_calls.py` | AOSP AIDL `setup_codec` 的平坦 if/else 链与 V5 调用点 0x862928 |
| `analysis/scripts/d1/d1_prop.py` | `ro.product.name` xref |
| `analysis/scripts/d1/d1_fmq.py` | `MessageQueueBase` 双实例化 |
| `analysis/raw/d1/fmq-V1-ndk.so` | 从设备 APEX 拉取的 `android.hardware.common.fmq-V1-ndk.so`（10648 B，仅导出 `GrantorDescriptor`） |
