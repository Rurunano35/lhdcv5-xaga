# D2 — 路线设计：自建 HIDL 厂商 HAL 实现（含 V5 原生支持）

> 调查日期：2026-09-25
> 设备：Redmi Note 11T Pro (xaga / MT6895) / Android 14 / HyperOS OS2.0.12.0.ULOCNXM / KernelSU root
> 方法：设备只读 adb（`exec-out` 拉文件，未在设备上留任何文件）+ 本地反汇编（capstone/pyelftools）+ AOSP android14-release 源码落盘
> **全程只读**。唯一一次写设备（`cp` 到 `/data/local/tmp` 拉音频 HAL 服务二进制）已立即 `rm`，其后全部改用 `adb exec-out`（不落盘）。

---

## 0. 结论速览

| # | 问题 | 结论 | 分级 |
|---|---|---|---|
| a1 | 厂商实现的服务名 | `vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory/default`（另有 `@2.1`、AOSP 名 `@2.0`/`@2.1`，共 4 个，全在 pid 1006） | 已验证 |
| a2 | VINTF 声明 | `/vendor/etc/vintf/manifest.xml` L334–343，`<transport>hwbinder</transport>`。**HIDL VINTF 条目没有路径字段** → 无法"指向别处" | 已验证 |
| a3 | 谁加载 impl | **音频 HAL 服务进程自己**：`registerPassthroughServiceImplementation(desc, desc, "default")` → passthrough 查找 → dlopen `<desc>-impl*.so` | 已验证（反汇编 + 符号） |
| a4 | 能否同名抢占 | hwservicemanager **允许**覆盖（只打 WARNING）。但**抢到名字也没用**：provider 必须与音频 HAL module 同进程 | 已验证 |
| a5 | 可行形态 | **bind-mount 覆盖 `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so`**（同名、同进程、零 VINTF/零 sepolicy/零新进程） | 已验证（时序） |
| b | 接口面 | Factory 5 方法（含 MTK 私有 `updataConnParam`）+ Provider 5 方法（含 MTK 私有 `enterGameMode`）+ 回调侧 `IBluetoothAudioPort` 6 方法。**完整清单见 §3** | 已验证（接口库 Bp/Bn 符号） |
| c | PCM 从哪来 | **不是 provider 提供的 stream**。provider 只建 FMQ；PCM 由**同进程**的 `audio.bluetooth.default.so` 写入 | 已验证 |
| c2 | 能否复用现有 module | **能，且必须复用**。自建 provider 只需链接 `libbluetooth_audio_session_mediatek.so` 并调 `OnSessionStarted` | 已验证 |
| d | 自建能否复刻整条链 | **能**。所有组件同进程、会话 API 稳定、AOSP 有完整参考实现 | 已验证 |
| e | 能否"原生携带 V5" | **在 HIDL 2.x 公共语义下不可能**。`CodecSpecific` 恰好 5 个变体、无 `vendorConfig` 逃生口；`LhdcParameters` 仅 8 字节、无版本字段；线格式编译期冻结且两端共用 APEX 库。**只能做到"私有协议意义上的原生"**，而软件编码通路下它**零功能收益** | 已验证（逐指令） |
| e2 | D2 的唯一实质收益 | **192 kHz 准入**：`IsSoftwarePcmConfigurationValid` 只被 provider 调用，自建 provider 可放宽；厂商 provider 显式拒绝 `0x10/0x20` | 已验证（逐指令） |
| f | 总判定 | **技术可行、工程量大、收益极小**。若目标是"配置送到 HAL 不伪装"→ 伪需求（SW 通路 HAL 只收 PCM）；若目标是 **192 kHz** → 这是目前唯一可行路线 | — |

---

## 1. 取证清单（可复现）

### 1.1 拉取的设备文件（`adb exec-out`，不落设备盘）

```
export MSYS_NO_PATHCONV=1; ADB="d:/Cache/Hyperos/platform-tools/adb.exe"
$ADB exec-out su -c "cat /vendor/bin/hw/android.hardware.audio.service.mediatek" > raw/d2/audio_service_mediatek
$ADB exec-out su -c "cat /apex/com.android.btservices/lib64/vendor.mediatek.hardware.bluetooth.audio@2.2.so" > raw/d2/mtk_hidl_22_iface.so
$ADB exec-out su -c "cat /apex/com.android.btservices/lib64/vendor.mediatek.hardware.bluetooth.audio@2.1.so" > raw/d2/mtk_hidl_21_iface.so
```

| 文件 | 大小 | SHA256 | 与设备一致 |
|---|---|---|---|
| `raw/d2/audio_service_mediatek` | 15552 | `604dbfd2f48ebbfcb7c98296c2784389b9ec398e2445fcfcdbeacc9327b924ac` | ✔（设备侧复算相同） |
| `raw/d2/mtk_hidl_22_iface.so` | 174400 | `a651ecf0399d424973f87350a90f7f285098e7dfeae945d48babe0f55847f355` | ✔ |
| `raw/d2/mtk_hidl_21_iface.so` | 231592 | `c04bef4a9f83a187a33599017080f052b7554902c0cf6c27c25ed6de23139568` | ✔ |

设备侧关键文件哈希（本次复算）：

```
604dbfd2…b924ac  /vendor/bin/hw/android.hardware.audio.service.mediatek
8a266659…511fa2  /vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so   (= artifacts/libs/hal22.so)
7ad79adf…930b67  /vendor/lib64/hw/audio.bluetooth.default.so
5eadb9b6…27592e6 /vendor/lib64/libbluetooth_audio_session_mediatek.so
c04bef4a…139568  /apex/com.android.btservices/lib64/vendor.mediatek.hardware.bluetooth.audio@2.1.so
```

### 1.2 新增 AOSP 源码落盘

```
reference/aosp-src/d2/
├─ audio_service.cpp                     ← hardware/interfaces/audio/common/all-versions/default/service/service.cpp  ★关键
├─ audio_service_Android.bp / audio_service.rc
├─ DevicesFactory_7_0.cpp（404，不存在）
├─ hwsvcmgr_ServiceManager.cpp           ← system/hwservicemanager/ServiceManager.cpp
├─ hwsvcmgr_HidlService.cpp              ← system/hwservicemanager/HidlService.cpp
├─ BluetoothAudioProvider.cpp            ← hwif 2.0 default
├─ BluetoothAudioSession.cpp             ← hwif utils/session
├─ IBluetoothAudioPort_2_0.hal
├─ IBluetoothAudioProvidersFactory_2_1.hal
├─ libhardware_hardware.c / .h           ← hw_get_module_by_class 命名规则
└─ audio_allversions_default.bp
```

（`r7/` 下已有：`hwif/2.0*`、`hwif/2.1`、`libhidl/ServiceManagement.cpp`、`libhidl/include/LegacySupport.h`、`bt/audio_bluetooth_hw/*`、`bt/audio_hal_interface/hidl/*`）

---

## 2. (a) 现有厂商实现：服务名 / VINTF / 能否"抢占"

### 2.1 服务名与 VINTF 声明（已验证）

`lshal`（只读）实测 4 个 BT audio HIDL 服务，全部注册在 **pid 1006**（音频 HAL 服务 `android.hardware.audio.service.mediatek`，域 `u:r:mtk_hal_audio:s0`）：

```
DM,FC Y android.hardware.bluetooth.audio@2.0::IBluetoothAudioProvidersFactory/default         0/8 1006
DM,FC Y android.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default         0/8 1006
DM,FC Y vendor.mediatek.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default 0/8 1006
DM,FC Y vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory/default 0/8 1006
```

`/vendor/etc/vintf/manifest.xml` L334–343（原文）：

```xml
    <hal format="hidl">
        <name>vendor.mediatek.hardware.bluetooth.audio</name>
        <transport>hwbinder</transport>
        <version>2.2</version>
        <interface>
            <name>IBluetoothAudioProvidersFactory</name>
            <instance>default</instance>
        </interface>
        <fqname>@2.2::IBluetoothAudioProvidersFactory/default</fqname>
    </hal>
```

另 L70–79 是 AOSP 名 `android.hardware.bluetooth.audio@2.1`。全 manifest `format="aidl"` 计数 = **0**；`/vendor/etc/vintf/manifest/` 目录 39 个 fragment 中亦无 `format="aidl"`。
FCM（`/system/etc/vintf/compatibility_matrix.device.xml`）：L463–472 = MTK HIDL 2.1/2.2（`optional="true"`）；L473–480 = MTK **AIDL**（`optional="true"`，无版本号）。

### 2.2 ★ 谁加载 impl —— 机制完全解出（已验证）

**证据 1**：音频 HAL 服务二进制只有 15552 字节，其 `.dynsym` 的**全部导入符号**里只有 5 个非 libc 符号，其中：

```
_ZN7android8hardware40registerPassthroughServiceImplementationERKNSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEES9_S9_
```

即**只导入了 3 参数版 `registerPassthroughServiceImplementation(string,string,string)`**。

**证据 2**：`.rodata` 里的 BT audio 相关字符串（地址即文件偏移）：

```
0x0df9  android.hardware.bluetooth.audio@2.0::IBluetoothAudioProvidersFactory
0x0e6d  vendor.mediatek.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory
0x0ebb  Bluetooth Audio API
0x0f35  android.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory
0x0f7b  vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory
0x1205  Vendor Bluetooth Audio API
0x0fc9  register interface = %s fail!
0x1097  register interface = %s
```

**证据 3**：`.text` 反汇编。PLT 桩逐条解析（`adrp x16,#0x3000` + `ldr x17,[x16,#imm]` → GOT 槽 → `.rela.plt` 符号）：

```
0x2f60 -> GOT 0x3420  _Znwm                                              (operator new)
0x2f70 -> GOT 0x3428  std::string::string(std::string const&)            (拷贝构造)
0x2f80 -> GOT 0x3430  _ZdlPv                                             (operator delete)
0x2f90 -> GOT 0x3438  android::hardware::registerPassthroughServiceImplementation(
                          std::string const&, std::string const&, std::string const&)   ★
0x2fa0 -> GOT 0x3440  android::hardware::joinRpcThreadpool()
```
关键反汇编：

```
0x29c0  stp  xzr, xzr, [x29, #-0xd8]        ; 构造 "default" 短字符串（立即数拼出 "ault"/"defa"）
0x29d8  sub  x2, x29, #0xd8                 ; x2 = &"default"
0x29dc  mov  x0, x22                        ; x0 = 当前接口名
0x29e0  mov  x1, x22                        ; x1 = 同一接口名（expectInterfaceName）
0x29e4  bl   #0x2f90                        ; registerPassthroughServiceImplementation(iface, iface, "default")
0x29ec  cmp  w0, #0
0x29f0  cset w20, eq                        ; 记录成功
...
0x2a18  sub  x2, x29, #0xd8
0x2a24  bl   #0x2f90                        ; 同一调用（编译器复制）
0x2a3c  cbz  w23, #0x2988                   ; 失败则跳出
```

**证据 4**：两个列表（构造位置 0x2590–0x2654 与 0x2690–0x2758）：

| 列表标签 | 成员（注册顺序） |
|---|---|
| `Bluetooth Audio API` (0x0ebb) | `android.hardware.bluetooth.audio@2.1::…`(0x0f35)、`android.hardware.bluetooth.audio@2.0::…`(0x0df9) |
| `Vendor Bluetooth Audio API` (0x1205) | `vendor.mediatek.hardware.bluetooth.audio@2.2::…`(0x0f7b)、`vendor.mediatek.hardware.bluetooth.audio@2.1::…`(0x0e6d) |

**MTK 改写了 AOSP 的"首个成功即停止"语义**（AOSP `service.cpp` 的 `registerPassthroughServiceImplementations` 是 early-return），改为**逐条注册** —— 这与 `lshal` 同时看到 2.0 与 2.1（以及 2.1 与 2.2）四个服务完全吻合。

**证据 5**：`registerPassthroughServiceImplementation` 的语义（AOSP `libhidl/include/LegacySupport.h` 原文）：

```cpp
template <class Interface, class ExpectInterface = Interface>
status_t registerPassthroughServiceImplementation(const std::string& name = "default") {
    return registerPassthroughServiceImplementation(Interface::descriptor,
                                                    ExpectInterface::descriptor, name);
}
```
→ 最终走 `Interface::getService(name, /*getStub=*/true)` → `getPassthroughServiceManager()->get()`。

**证据 6**：passthrough 查找算法（AOSP `libhidl/transport/ServiceManagement.cpp:450-520` 原文）：

```cpp
std::string packageAndVersion = fqName.substr(0, idx);      // "vendor.mediatek.hardware.bluetooth.audio@2.2"
std::string ifaceName         = fqName.substr(idx + 2);      // "IBluetoothAudioProvidersFactory"
const std::string prefix = packageAndVersion + "-impl";      // ← 前缀匹配
const std::string sym    = "HIDL_FETCH_" + ifaceName;        // ← 固定符号名
std::vector<std::string> paths = {
    HAL_LIBRARY_PATH_ODM,      // /odm/lib64/hw/
    HAL_LIBRARY_PATH_VENDOR,   // /vendor/lib64/hw/
    halLibPathVndkSp,          // /vendor/lib64/vndk-sp-<ver>/hw/
#ifndef __ANDROID_VNDK__
    HAL_LIBRARY_PATH_SYSTEM,   // /system/lib64/hw/
#endif
};
for (const std::string& path : paths) {
    std::vector<std::string> libs = findFiles(path, prefix, ".so");   // 前缀 + ".so" 后缀
    for (const std::string &lib : libs) {
        handle = android_load_sphal_library(fullPath.c_str(), dlMode);
        if (!eachLib(handle, lib, sym)) return;    // ← 找到 HIDL_FETCH_ 即停
    }
}
```
`findFiles`（同文件 352–369）用 `readdir` 顺序 + `StartsWith(name,prefix) && EndsWith(name,".so")`。

**→ 完整机制（已验证）**：
```
pid 1006 启动（on boot: class_start hal）
  → registerPassthroughServiceImplementation("vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory", 同名, "default")
  → Interface::getService("default", getStub=true)
  → getPassthroughServiceManager()->get(desc, "default")
  → 扫 /odm/lib64/hw/ → /vendor/lib64/hw/ → vndk-sp → /system/lib64/hw/
    找 前缀 "vendor.mediatek.hardware.bluetooth.audio@2.2-impl" + 后缀 ".so" 的文件
  → dlopen + dlsym("HIDL_FETCH_IBluetoothAudioProvidersFactory")
  → 调用它，得到 factory 对象
  → factory->registerAsService("default")   ← 此时才进 hwservicemanager
```

设备实测落地文件：
```
/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so   173360 B  8a266659…  ← 导出 HIDL_FETCH_IBluetoothAudioProvidersFactory @0x11700
/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.1-impl.so    96824 B
/vendor/lib64/hw/android.hardware.bluetooth.audio@2.1-impl.so           140800 B
/vendor/lib64/hw/android.hardware.bluetooth.audio@2.0-impl.so            88448 B
/odm/lib64/hw/                                        ← **不存在**（/odm/lib64 下只有 2 个文件）
/vendor/lib64/vndk-sp-*                               ← **不存在**
```

### 2.3 "抢占"的三种形态逐一评估

#### 形态 A：另一进程用同名 `registerAsService` —— 技术上可覆盖，但**抢到也没用**

hwservicemanager 的行为（AOSP `hwservicemanager/ServiceManager.cpp:338-378` 原文）：

```cpp
bool ServiceManager::addImpl(...) {
    for(size_t i = 0; i < interfaceChain.size(); i++) {
        if (!mAcl.canAdd(interfaceChain[i], callingContext)) return false;   // ① SELinux add 权限
    }
    ...
    // Detect duplicate registration
    if (interfaceChain.size() > 1) {
        const HidlService *hidlService = lookup(baseFqName, name);
        if (hidlService != nullptr && hidlService->getService() != nullptr) {
            LOG(WARNING) << "Detected instance of " << childFqName << " (pid: " << newServicePid
                    << ") registering over instance of or with base of " << baseFqName
                    << " (pid: " << oldServicePid << ").";      // ← 只是 WARNING
        }
    }
    // Unregister superclass if subclass is registered over it
    ...
```
`HidlService::setService`（`HidlService.cpp:48-58`）直接 `mService = service;` —— **无重复检查、静默覆盖**。

所以：
- **hwservicemanager 层：可以抢占**（先注册者被后来的覆盖）。
- **SELinux 层**：调用域必须对 `vendor.mediatek.hardware.bluetooth.audio::IBluetoothAudioProvidersFactory`（→ `mtk_hal_bluetooth_audio_hwservice`）有 `hwservice_manager add`。本机 CIL 实测只有 `mtk_hal_audio` 有该权限（`raw/r7_vendor_sepolicy.cil` L6784），`bluetooth` 域只有 `find`（L4812）。→ 异进程必须打 sepolicy 补丁。
- **客户端层**：`registerAsServiceInternal`（`ServiceManagement.cpp:965-1000`）要求 VINTF manifest 声明 `transport=hwbinder` —— 该条目已存在，放行。
- **★ 致命问题**：即使抢到名字，**provider 与音频 HAL module 必须同进程**（§4）。异进程的 provider 创建的 FMQ 与 pid 1006 里 `audio.bluetooth.default.so` 查的会话单例不是同一个对象 → `IsSessionReady()` 恒 false → `openOutputStream` 返回 -EINVAL，通路照旧不通。
  → **形态 A：不可行。**

#### 形态 B：让 VINTF 指向别处 —— HIDL VINTF **没有路径字段**，且唯一可改项有害

HIDL VINTF `<hal format="hidl">` 的合法子元素只有 `name / transport / version / interface{name,instance} / fqname`，**没有任何指向实现文件的字段**（实现文件路径是 passthrough 查找在运行时按前缀拼出来的）。
唯一能"改指向"的是 `<transport>`：

```cpp
// ServiceManagement.cpp getRawServiceInternal
const bool vintfPassthru = (transport == Transport::PASSTHRU);
...
if (getStub || vintfPassthru || vintfLegacy) { ... getPassthroughServiceManager()->get(...) }
```
把 transport 改成 `passthru` 会让**BT 栈自己**（com.android.bluetooth 进程）dlopen impl —— 会话单例就跑到 BT 进程去了，而 `audio.bluetooth.default.so` 在 pid 1006 → 必坏。
→ **形态 B：不可行且有害。**

#### 形态 C（推荐）：同名替换 impl 库 —— **唯一可行形态**

用 bind-mount 覆盖 `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so`：
- 服务名不变、进程不变、注册路径不变 → **VINTF 不用改、hwservice_contexts 不用加、init rc 不用写、新进程不用起**；
- `findFiles` 只匹配到一个文件（前缀+后缀），无 readdir 顺序风险；
- 时序已验证：`/system/etc/init/hw/init.rc` 中 `on post-fs-data` 在 **L747**，`class_start hal` 在 **L1311**（属 `on boot`，L1194 开始）；`late-init`(L593) 先触发 `post-fs-data` 再触发 `boot`。KernelSU 的 post-fs-data 挂载**早于** pid 1006 dlopen impl。
- pid 1006 与 init 同 mount namespace（R3 已验证 `mnt:[4026533766]`）→ 挂载对它可见。
- **遗留风险（未实测）**：SELinux 标签。bind-mount 源在 `/data` 时目标沿用源 inode 的标签；`mtk_hal_audio` 读 `data_file` 可能被拒。缓解：`mount --bind -o context=u:object_r:vendor_file:s0`，或 KernelSU `sepolicy.rule` 补 allow，或把源文件放进一个已正确标注的目录。

#### 形态 D（备选，风险更高）：新增一个前缀匹配的库

例如放 `vendor.mediatek.hardware.bluetooth.audio@2.2-impl-xaga.so`：
- `findFiles` 的前缀匹配会**同时命中**厂商文件与我们的文件；`eachLib` 在**第一个**导出 `HIDL_FETCH_` 的库上返回 false 并终止 → 谁先被 `readdir` 返回谁生效，**不可控**（erofs/ext4 目录顺序）。
- 若放到 `/odm/lib64/hw/`（路径顺序最前）则可确定胜出，但本机**该目录不存在**，需要额外把整个 `/odm/lib64`（或 `/odm/lib64/hw`）用 tmpfs/目录挂载造出来。
- 好处：厂商原文件不动，可回退；坏处：多一层挂载工程 + 目录顺序风险。
→ **形态 D：可行但不如 C 干净**，且一旦生效，**同一 descriptor 下的全部 provider（A2dpOffload / HearingAid / LE Audio 系列）都必须由我们的库提供**（厂商库不会再被扫到）。

---

## 3. (b) 自建实现必须实现的 HIDL 接口面（完整）

来源：设备接口库 `mtk_hidl_22_iface.so` / `mtk_hidl_21_iface.so` 的 `.dynsym` 中 `BpHw*` / `BnHw*` 方法符号逐条枚举（`_hidl_*` = Bn 服务端分派，非 `_hidl_` 前缀 = Bp 代理方法），以及栈内 `hidl::BluetoothAudioPortImpl` vtable @`0xf6d550` 逐槽解析。

### 3.1 `vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory`（服务端，**必须实现**）

| 方法 | 说明 |
|---|---|
| `openProvider(SessionType) generates (Status, IBluetoothAudioProvider)` | 2.0 版 |
| `openProvider_2_1(SessionType) generates (Status, IBluetoothAudioProvider)` | 2.1 版（MTK 接口库中确实存在） |
| `getProviderCapabilities(SessionType) generates (vec<AudioCapabilities>)` | 2.0 版 |
| `getProviderCapabilities_2_1(SessionType) generates (vec<AudioCapabilities>)` | 2.1 版 |
| **`updataConnParam(ConnParam)`** | **MTK 私有**（注意拼写就是 `updata`）。栈侧计数 = 0 → 本机无人调用，实现可为空 |

### 3.2 `vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvider`（服务端，**必须实现**）

| 方法 | 说明 |
|---|---|
| `startSession(sp<IBluetoothAudioPort>, V2_0::AudioConfiguration) generates (Status, fmq_sync<uint8_t>)` | 2.0 版 |
| `startSession_2_1(sp<IBluetoothAudioPort>, V2_2::AudioConfiguration) generates (Status, fmq_sync<uint8_t>)` | **2.1 版 —— BT 栈实际调用的就是它** |
| `streamStarted(Status)` | 回调 |
| `streamSuspended(Status)` | 回调 |
| `endSession()` | |
| **`enterGameMode(uint8_t)`** | **MTK 私有**（HIDL 侧也有，AIDL 侧是 `enterGameMode(char)`） |

### 3.3 回调侧 `vendor.mediatek.hardware.bluetooth.audio@2.1::IBluetoothAudioPort`（HAL → 栈，**必须调用/兼容**）

vtable 实测（`libbluetooth_jni_orig.so` @`0xf6d550`，栈内 `vendor::mediatek::bluetooth::audio::hidl::BluetoothAudioPortImpl`）：

```
[14] dtor D1   [15] dtor D0
[16] 0x833b20 476  BluetoothAudioPortImpl::startStream()
[17] 0x833d00 472  BluetoothAudioPortImpl::suspendStream()
[18] 0x833ee0 200  BluetoothAudioPortImpl::stopStream()
[19] 0x833fb0 332  BluetoothAudioPortImpl::getPresentationPosition(std::function<...>)
[20] 0x834100 548  BluetoothAudioPortImpl::updateMetadata(V5_0::SourceMetadata const&)
[21] 0x834330 324  BluetoothAudioPortImpl::enterGameMode(unsigned char)     ← MTK 私有
```
即：AOSP 的 5 个方法 + `enterGameMode`。

### 3.4 必须导出的符号

```c
extern "C" IBluetoothAudioProvidersFactory*
HIDL_FETCH_IBluetoothAudioProvidersFactory(const char* name);
```
符号名由 `"HIDL_FETCH_" + ifaceName` 在运行时拼出（`ServiceManagement.cpp:468`），**不可改名**。

### 3.5 明确**不存在**的能力（重要）

| 项 | HIDL 侧计数 | 结论 |
|---|---|---|
| `setLatencyMode` / `LatencyMode` | `hal22.so` = **0** / **0**；`mtk_hidl_21_iface.so` = 0 / 0 | **HIDL 通路无法承载低延迟控制**（与 R8 的 D1 一致） |
| `LowLatencyModeAllowed` | 0 | 同上 |
| `getSupportedProfiles` | 0 | 不存在（R7 已证 AOSP A14/main 都没有） |
| `IBluetoothAudioHost::streamOut` | 0 | 不存在，PCM 走 FMQ |
| `Lhdcv5*` / `lhdcv5` 字符串 | `mtk_hidl_21/22_iface.so` = 0；`hal22.so` = 0 | **HIDL 接口与实现里没有任何 V5 结构** |

栈侧计数（`libbluetooth_jni_orig.so`）：`setLatencyMode` = 3、`LatencyMode` = 14 —— **全部在 AIDL 命名空间**（`aidl::…::BluetoothAudioPortImpl::setLatencyMode` @0x8560b0、`@0x868680`）。

---

## 4. (c) 音频数据通路：PCM 从哪来，自建实现要提供什么

### 4.1 ★ 核心认知：provider **不提供** audio output stream

设备上存在**两个不同角色**，它们必须同进程：

| 角色 | 库 | 对 audioserver 的接口 | 职责 |
|---|---|---|---|
| **BT audio provider**（HIDL） | `vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so` | 对 audioserver **不可见** | 与 BT 栈通话；**创建 FMQ**；把会话登记到进程内单例 |
| **audio HAL module "bluetooth"** | `audio.bluetooth.default.so` | 对 audioserver **可见**（经音频 HAL 服务） | 实现 `adev_open_output_stream` / `out_write`；**把 PCM 写进 FMQ** |

实测（`/proc/1006/maps`，只读）两者与 `libbluetooth_audio_session_mediatek.so` 同在 pid 1006：

```
7cac7ca000-… /vendor/lib64/hw/audio.bluetooth.default.so
7cc6110000-… /vendor/lib64/libbluetooth_audio_session.so
7cc6156000-… /vendor/lib64/hw/android.hardware.bluetooth.audio@2.1-impl.so
7cc61c6000-… /vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so
7cc6211000-… /vendor/lib64/libbluetooth_audio_session_mediatek.so
```

**进程内单例是硬约束**：`BluetoothAudioSessionReport::OnSessionStarted`（provider 调）与 `IsSessionReady` / `OutWritePcmData`（module 调）都是 `libbluetooth_audio_session_mediatek.so` 里的**进程内静态对象**，不走 binder。

### 4.2 符号级证据（自建 provider 需要照抄的调用）

`hal22.so`（厂商 impl）**导入**的会话 API（`.dynsym` UNDEF 项）：

```
android::bluetooth::audio::BluetoothAudioSession_2_1::OnSessionStarted(
    sp<vendor::mediatek::…::V2_1::IBluetoothAudioPort>,
    const hardware::MQDescriptor<uint8_t, MQFlavor::SYNCHRONIZED_READ_WRITE>*,
    const V2_2::AudioConfiguration&)
android::bluetooth::audio::BluetoothAudioSessionInstance_2_1::GetSessionInstance(const V2_2::SessionType&)
android::bluetooth::audio::IsSoftwarePcmConfigurationValid_2_1(const V2_2::PcmParameters&)
android::bluetooth::audio::GetSoftwarePcmCapabilities_2_1()
```

`hl_libbluetooth_audio_session_mediatek.so`（会话库）**导出**（本次实测地址）：

```
0x12d9c 1452  BluetoothAudioSession_2_1::OnSessionStarted(sp<V2_1::IBluetoothAudioPort>, const MQDescriptor<uint8_t,SYNCHRONIZED_READ_WRITE>*, const V2_2::AudioConfiguration&)
0x16088  524  BluetoothAudioSessionInstance_2_1::GetSessionInstance(const V2_2::SessionType&)
0x128e4  156  BluetoothAudioSession_2_1::IsSessionReady()
0x12840  164  BluetoothAudioSession_2_1::UpdateAudioConfig(const V2_2::AudioConfiguration&)
0x1a2f4  516  IsSoftwarePcmConfigurationValid_2_1(const V2_2::PcmParameters&)
0x16e30  484  IsSoftwarePcmConfigurationValid(const V2_1::PcmParameters&)        ← 厂商 A2dpSoftware 调的是这个
0x1a244   72  GetSoftwarePcmCapabilities_2_1()
0x16bac   72  GetSoftwarePcmCapabilities()
0x f044  460  BluetoothAudioSession::OutWritePcmData(const void*, size_t)
0x1da68   40  BluetoothAudioSession_2_1::invalidOffloadAudioConfiguration
```

`audio.bluetooth.default.so`（module）**导入**：`BluetoothAudioSession_2_1::IsSessionReady()`、`BluetoothAudioSessionInstance_2_1::GetSessionInstance(...)`、`BluetoothAudioSession::OutWritePcmData(...)`、`BluetoothAudioSession_2_1::invalidOffloadAudioConfiguration`；**它不导入 `IsSoftwarePcmConfigurationValid`**（关键，见 §6.3）。

### 4.3 能否复用设备上已有的 audio HAL module？—— **能，而且是唯一正确做法**

自建 provider 要做的事（与 AOSP `A2dpSoftwareAudioProvider` 一致，MTK 版只是把类型换成 V2_2）：

```cpp
// 1) 构造时建 FMQ（AOSP 常量：7680 B，EventFlag=true）
std::unique_ptr<DataMQ> mDataMQ(new DataMQ(kDataMqSize /*7680*/, /*EventFlag*/ true));
session_type_ = SessionType::A2DP_SOFTWARE_ENCODING_DATAPATH;

// 2) startSession_2_1：校验 + 保存 hostIf + 保存 audioConfig
// 3) onSessionReady：把 FMQ 描述符登记进进程内单例，并回传给栈
BluetoothAudioSession_2_1::OnSessionStarted(session_type_, stack_iface_, mDataMQ->getDesc(), audio_config_);
_hidl_cb(Status::SUCCESS, *mDataMQ->getDesc());
```

`audio.bluetooth.default.so` **一字不改**：它在 `SetUp()` 里查 `IsSessionReady(session_type)`，成功后 `out_write` 经 `OutWritePcmData` 写入同一个 FMQ。

**不需要**在 provider 里调 `hw_get_module` / `hw_get_module_by_class` —— 那是 module 侧的加载路径，加载者是**音频 HAL 服务进程**（见 §5.1）。

**反例（不可行）**：自建独立进程 + 自己 `hw_get_module("audio","bluetooth")` 提供 stream。
理由：module 的加载发生在**音频 HAL 服务进程**内（`IDevicesFactory::openDevice("bluetooth")` 的实现），audioserver 只连 `android.hardware.audio@7.1::IDevicesFactory/default` 这一个服务（pid 1006）。要另起炉灶就得自己实现**整套** HIDL 音频 HAL（primary/a2dp/effect…），不现实。

---

## 5. (d) 完整链路（AOSP 源码逐行）+ 自建实现能否复刻

### 5.1 建立通路（控制面）

```
① BT 栈 init（com.android.bluetooth, pid 2688）
   audio_hal_interface/hidl/a2dp_encoding_hidl.cc:352  a2dp::init()
     → new A2dpTransport(A2DP_SOFTWARE_ENCODING_DATAPATH)
     → new BluetoothAudioSinkClientInterface(...)  → FetchAudioProvider_2_1()
        → vendor.mediatek.…@2.2::IBluetoothAudioProvidersFactory::getService("default")
        → factory->openProvider(A2DP_SOFTWARE_ENCODING_DATAPATH)   ← ★ 我们的 openProvider 被调用
        → castFrom<IBluetoothAudioProvider_2_1>()
② 每次 codec 变化：a2dp_encoding_hidl.cc:430  setup_codec()
     a2dp_get_selected_hal_codec_config(&codec_config)   ← 失败即整条链断（现 P0/P1/P2 修的正是这里）
     should_codec_offloading = IsCodecOffloadingEnabled(codec_config)
     if (SessionType == A2DP_HARDWARE_OFFLOAD_DATAPATH) audio_config.codecConfig(codec_config);
     else { a2dp_get_selected_hal_pcm_config(&pcm_config); audio_config.pcmConfig(pcm_config); }
     active_hal_interface->UpdateAudioConfig(audio_config)        ← 只缓存，不发 RPC
③ 起流：a2dp_encoding_hidl.cc:467 start_session() → StartSession_2_1()
     → provider_2_1_->startSession_2_1(hostIf /*IBluetoothAudioPort*/, audio_config)   ← ★ 我们的 startSession_2_1
④ HAL 侧（我们的实现）
     - 校验（可放宽）→ 建 FMQ → BluetoothAudioSession_2_1::OnSessionStarted(...) → 回传 MQDescriptor
⑤ 打开输出流：APM → AudioFlinger(module "bluetooth") → IDevicesFactory::openDevice("bluetooth")
     → pid 1006 内 hw_get_module_by_class("audio", "bluetooth", &module)
         （libhardware/hardware.c:197-260：name = "audio.bluetooth"；先试 ro.hardware.audio.bluetooth，
           再试 variant_keys，最后回退 "default" → /vendor/lib64/hw/audio.bluetooth.default.so）
     → adev_open → adev_open_output_stream(stream_apis.cc:720)
         → BluetoothAudioPortHidlOut::SetUp(devices)                 (device_port_proxy_hidl.cc:133)
             → init_session_type(devices) → IsSessionReady(A2DP_SOFTWARE_ENCODING_DATAPATH)
                   ← ④ 未成功则这里 false → SetUp false → return -EINVAL
             → RegisterControlResultCback(...)
⑥ HAL → 栈：IBluetoothAudioPort::startStream()
     → BluetoothAudioSession_2_1::StartStream → IBluetoothAudioProvider::streamStarted(Status)  ← ★ 我们的回调
```

设备日志逐字对上（既有报告已录）：
```
E BTAudioHalDeviceProxy: init_session_type: device=0x80, session_type=A2DP_SOFTWARE_ENCODING_DATAPATH is not ready
I AudioHwDevice: openOutputStream(), HAL returned sampleRate 0, Format 0, channelMask 0, status -22
E APM_AudioPolicyManager: openOutputWithProfileAndDevice failed to open output -19
I AudioFlinger: loadHwModule() Loaded bluetooth audio interface, handle 18
```

### 5.2 数据面（FMQ）

```
应用 AudioTrack → AudioFlinger 混音线程
  → audio.bluetooth.default.so : out_write()
  → BluetoothAudioPortHidlOut::WriteData()                    (device_port_proxy_hidl.cc)
  → BluetoothAudioSessionControl_2_1::OutWritePcmData(session_type, buf, len)
  → MessageQueueBase<uint8_t,kSynchronizedReadWrite>::write() ===== FMQ =====
  → BT 栈 libbluetooth_jni.so : MessageQueueBase<…>::read()
  → LHDC 编码 → L2CAP → 耳机
```

### 5.3 自建实现能否复刻？—— **能**

| 环节 | 复刻难度 | 依据 |
|---|---|---|
| `openProvider` / `openProvider_2_1` | 低（返回我们自己的 provider 实例） | AOSP `BluetoothAudioProvidersFactory.cpp` 可直接改 |
| `startSession_2_1` | 低（照抄 AOSP `A2dpSoftwareAudioProvider::startSession` + MTK 类型） | AOSP 源码 + hal22.so 反汇编 |
| FMQ 创建 | 低（`DataMQ(7680, true)`） | AOSP 源码 |
| 会话登记 | 低（`BluetoothAudioSession_2_1::OnSessionStarted`，符号已存在） | 会话库导出表 |
| module 侧 | **零改动** | module 不依赖 provider 的任何私有符号 |
| 进程归属 | **必须 pid 1006**（靠替换 impl 实现） | maps 实测 |
| `IBluetoothAudioPort` 回调 | 低（HAL 主动调栈） | vtable 已解析 |

---

## 6. (e) 「原生携带 V5」的严格论证

### 6.1 事实（全部逐指令验证）

**F1 — MTK HIDL `CodecConfiguration::CodecSpecific` 恰好 5 个变体，无逃生口。**

`mtk_hidl_21_iface.so`（= 定义 `CodecConfiguration` 的那个包）导出：

```
0x308d0  56  CodecSpecific::CodecSpecific()
0x30940 264  CodecSpecific::hidl_destructUnion()      ← cmp w0,#5 ; b.lo  ⇒ 合法 tag 只有 0..4
0x31120 100  CodecSpecific::lhdcConfig(LhdcParameters&&)
0x31280 100  CodecSpecific::ldacConfig(LdacParameters const&)
0x312f0 100  CodecSpecific::aptxConfig(AptxParameters const&)
0x31190 108  CodecSpecific::sbcConfig(SbcParameters const&)
0x31200 116  CodecSpecific::aacConfig(AacParameters const&)
0x31670   8  CodecSpecific::getDiscriminator()        ← ldrb w0,[x0]
```
逐条 setter 反汇编读出的判别值：

| 变体 | 判别值 | 证据 |
|---|---|---|
| `sbcConfig` | 0 | `CodecSpecific()` @0x308d0 逐指令：`strb wzr,[x19]`（tag=0）、`sturh wzr,[x19,#1]`、`strb wzr,[x19,#3]`、`stur xzr,[x19,#4]`、`str wzr,[x19,#0xc]` ⇒ 对象共 **16 字节**，载荷区 `+4..+15` = 12 字节 |
| `aacConfig` | 1 | （由声明顺序推出；未单独反汇编，因为 5 个 tag 已由 `cmp w0,#5` + 4 个已知 setter 完全确定） |
| `ldacConfig` | **2** | `0x31298  cmp w8,#2` / `0x312c4 mov w9,#2; strb w9,[x20]` |
| `aptxConfig` | **3** | `0x31308  cmp w8,#3` / `0x31334 mov w9,#3; strb w9,[x20]` |
| **`lhdcConfig`** | **4** | `0x31138  cmp w8,#4` / `0x31164 mov w9,#4; strb w9,[x20]` |

**没有 `vendorConfig`、没有 `lhdcv5Config`、没有 `lhdcv2Config`。**

**F2 — `LhdcParameters` 只有 8 字节，且无版本字段。**

setter 内 `str wzr,[x20,#0xc]` + `ldr x9,[x19]; stur x8,[x20,#4]` ⇒ union 载荷区 = `+4..+15`（12 字节），`CodecSpecific` 总 16 字节（1 tag + 3 pad + 12 payload）。

`LhdcParameters` 字段（栈侧 `toString(LhdcParameters)` @`0x82e060` 逐指令）：
```
ldr  w0, [x20]        → +0  SampleRate   (4B)   → toString(SampleRate) @0x829580
ldrb w0, [x20, #4]    → +4  ChannelMode  (1B)   → 0/1/2 ⇒ "UNKNOWN"/"MONO"/"STEREO"
ldrb w0, [x20, #5]    → +5  BitsPerSample(1B)   → 跳转表 @0x2c5752，5 个分支
```
栈侧写入侧（`A2dpLhdcV3ToHalConfig` @0x82a8b0 逐指令）：
```
0x82a9fc  str  w8, [sp,#8]      → +0 sampleRate = codec 采样率
0x82a9fc..0x82aa14             → +4 channelMode ∈ {0,1,2}
0x82aa40  strb w8, [sp,#0xd]    → +5 bitsPerSample ∈ {1,2,4}
0x82a960  strb w20,[sp,#0xe]    → +6 LL 标志（and w20,w8,#1）
                                → +7 **从不写入**
```
⇒ **8 字节里没有任何"版本"语义位**。

**F3 — 栈对 LHDC 的任何版本都写同一个 `codecType`。**

```
0x82a928  mov  w8, #0x20          ; HIDL CodecType::LHDC = 32
0x82a938  str  w8, [x19], #0xc    ; codecType @+0，x19 += 12 ⇒ CodecSpecific 位于 CodecConfiguration+12
```
`A2dpLhdcV3ToHalConfig` 与（AIDL 侧的）`A2dpLhdcv5ToHalConfig` 都是"LHDC ⇒ 0x20"。**HIDL 边界上 V3 与 V5 逐字节同形。**

**F4 — 线格式编译期冻结，两端共用同一份库。**

HIDL 的序列化/判别值由 `.hal` 经 hidl-gen 生成，固化在接口库 `vendor.mediatek.hardware.bluetooth.audio@2.1.so`（`CodecConfiguration`）与 `@2.2.so`（`AudioConfiguration`）里。栈（`/apex/com.android.btservices/lib64/libbluetooth_jni.so`，16 729 080 B，只读 APEX，MTK 私有源码不可得）与 HAL 端**链接的是同一份库**。改 union = 改接口版本 = 两端同时换库。

**F5 — HIDL 侧连 V5→HIDL 的转换函数都不存在。**
R2 已证：`命名空间含 hidl 且名字含 v5（不分大小写）的符号 = 0`；本次复核 `hal22.so` / 两个 HIDL 接口库中 `Lhdcv5` / `lhdcv5` / `LHDC` 字符串计数 **全为 0**。

### 6.2 严格结论

> **在 HIDL 2.x 的公共语义下，不存在"原生携带 V5"的实现方式。**

理由链：
1. HAL 能看到的唯一"配置"载体是 `CodecConfiguration{codecType, encodedAudioBitrate, peerMtu, isScmstEnabled, config:CodecSpecific}`；
2. `CodecSpecific` 有且仅有 5 个变体（F1），唯一 LHDC 槽是 `lhdcConfig`，载荷 `LhdcParameters` 8 字节且无版本位（F2）；
3. 栈对所有 LHDC 版本写同一 `codecType=0x20`（F3）；
4. 线格式冻结、两端共用库（F4）；
5. **且**软件编码通路下 `setup_codec()` 根本不下发 `codecConfig`（AOSP `a2dp_encoding_hidl.cc:430-464` 原文；MAIN-findings §3、R7 §4.4 已独立复核）。

三种"伪原生"方案评估：

| 方案 | 内容 | 判定 |
|---|---|---|
| **(i) 新 HIDL 包/版本 + 原生 `Lhdcv5Parameters`** | 自己写 `.hal` + 接口库 + 实现 | 接口与 HAL 侧**我们可以做到**；但**栈不会去调**。必须再给栈打补丁实现一整套新客户端（`FetchAudioProvider_2_1` 等价物 + `a2dp_encoding` 分支）。工作量 ≫ P1/P2，收益 = 0。**不可行/无意义** |
| **(ii) 复用通用字段做隐式通道** | 例如 `encodedAudioBitrate`（uint32，通用）或 `LhdcParameters` 的 2 个空闲字节承载 V5 标记 | **技术上可行**（provider 与栈两端都被我们控制）。但 **没有任何消费者**：SW 通路下 provider 拿到 codec 配置后无事可做（HAL 不读 codec）。属于"自娱自乐的私有协议"。**可行但零收益** |
| **(iii) 保留 `codec_type=12`、只把 `lhdcConfig` 换成 V5 语义** | 即"不伪装 V3" | HIDL 侧栈**根本没有 V5→HIDL 转换函数**（F5），要么新写（=方案 i），要么继续复用 V3 的转换函数 → **输出字节与现状完全相同**。**不可行/无收益** |

### 6.3 ★ 唯一能被自建 provider "原生解锁"的东西：192 kHz

**证据 A — `IsSoftwarePcmConfigurationValid` 只被 provider 调用。**
- 厂商 provider `hal22.so` 的 `A2dpSoftwareAudioProvider::startSession` @`0x1b2e4` 逐指令：
  ```
  0x1b334  mov  x0, x21
  0x1b338  bl   #0x24360   → V2_1::AudioConfiguration::getDiscriminator()
  0x1b340  b.eq #0x1b3c4   ; 必须 == pcmConfig
  0x1b3c8  bl   #0x24390   → V2_1::AudioConfiguration::pcmConfig()
  0x1b3cc  bl   #0x24650   → android::bluetooth::audio::IsSoftwarePcmConfigurationValid(V2_1::PcmParameters const&)
  0x1b3d8  cbz  x0, #0x1b4bc   ; 校验失败 → 返回 UNSUPPORTED_CODEC_CONFIGURATION
  ```
  （PLT 桩逐条解析：`0x24360/0x24390/0x24650` → 上述三个符号。）
- `audio.bluetooth.default.so` 的导入表里**没有** `IsSoftwarePcmConfigurationValid`（只有 `IsSessionReady` / `GetSessionInstance` / `OutWritePcmData` / `invalidOffloadAudioConfiguration`）。
  → **采样率的 HAL 侧闸门完全在 provider 内部，自建 provider 可以合法地放宽它。**

**证据 B — 厂商 provider 调的是 V2_1 版，显式拒绝 176.4k/192k。**
`hl_libbluetooth_audio_session_mediatek.so` @`0x16e30` 逐指令：
```
0x16e58  ldr  w8, [x0]            ; sampleRate（位掩码）
0x16e5c  sub  w9, w8, #1
0x16e60  cmp  w9, #0x3f
0x16e64  b.hi #0x16ec4            ; w8==0 或 w8>0x40 → 特殊分支
0x16e68  mov  w10, #1
0x16e6c  lsl  x9, x10, x9
0x16e70  mov  x10, #0x8b
0x16e74  movk x10, #0x8000, lsl #48      ; x10 = 0x8000_0000_0000_008b
0x16e78  tst  x9, x10
0x16e7c  b.eq #0x16ec4
...
0x16ec4  cmp  w8, #0x80
0x16ec8  b.eq #0x16e80                    ; 只有 0x80(RATE_24000) 被特殊放行
...
0x16e80  ldrb w9, [x19, #5]  ; bitsPerSample
0x16e94  mov  w10, #0x16 ; tst  → 必须 ∈ {BITS_16=1, BITS_24=2, BITS_32=4}
0x16ea0  ldrb w9, [x19, #4]  ; channelMode
0x16ea8  cmp  w9, #2 ; b.hs → 必须 ∈ {1,2}
0x16eb0  mov  w9, #0xcf ; tst w8, w9 ; b.eq → 拒绝
```
→ 放行 `sampleRate ∈ {0x1,0x2,0x4,0x8,0x40,0x80}` = **{44100, 48000, 88200, 96000, 16000, 24000}**；
→ `0x10 (176400)` / `0x20 (192000)` 在第一条掩码就落空、且不等于 0x80 → **拒绝**。
（`_2_1` 版 @`0x1a2f4` 掩码为 `0x3cf`，额外放行 8000/32000，同样不含 0x10/0x20。）

**⚠ 修正 R8**：R8 §5.1 写「栈侧不阻（`A2dpCodecToHalSampleRate` @0x829ac0 也允许 0x20）… 掩码允许 {…176400,192000…}」，与同一份 R8 §4 的「闸门①…显式拒绝 0x10/0x20」自相矛盾。本次逐指令复核支持 **闸门①**：**栈侧不阻，但 HAL provider 侧阻**。修正后的三闸门表述：

| 闸门 | 位置 | 是否被自建 provider 绕过 |
|---|---|---|
| ① provider 的 `IsSoftwarePcmConfigurationValid`（V2_1 版 @0x16e30） | pid 1006，**厂商 impl 库内** | **可以绕过**（自建 provider 跳过/放宽） |
| ② `GetSoftwarePcmCapabilities` 能力常量（`0x3cf`，经 `getProviderCapabilities` 上报） | 同上 | 可绕过（自定义上报）——但**栈是否用它钳制协商速率：未验证**（本次扫描 `.text` 未发现 `GetAudioCapabilities_2_1` 的直接 `bl` 调用者） |
| ③ `/vendor/etc/bluetooth_offload_audio_policy_configuration.xml` devicePort `samplingRates="44100 48000 88200 96000"` | audioserver | R7 §6.3 判为"回退/声明值，SW 通路非硬钳制"；**若要 192 kHz 仍建议一并放宽（未实测）** |

---

## 7. (f) 可行性结论 + 前置条件清单

### 7.1 结论

**技术上可行，工程量中等偏大，功能收益极小。** 分目标看：

| 目标 | D2 是否必要 | 说明 |
|---|---|---|
| **A. "配置送到 HAL，不伪装 V3"** | ❌ 伪需求 | 软件编码通路下 HAL 只收 `pcmConfig`；V3/V5 送到 HAL 的字节**完全相同**（F1–F4 + §5.1 ②）。D2 做完也不改变任何一个字节 |
| **B. 192 kHz** | ✅ **唯一有效路线** | 必须放宽 provider 侧的 `IsSoftwarePcmConfigurationValid`（§6.3） |
| **C. 低延迟（LL）控制面** | ❌ 无效 | HIDL 接口/实现中 `setLatencyMode`/`LatencyMode` 计数 = 0（§3.5）。要 LL 只能走 AIDL，而 AIDL 侧 MTK 把 `isLowLatencyEnabled` 硬编码为 0（R8 D1） |
| **D. 摆脱硬编码偏移（可维护性）** | ⚠️ 部分 | D2 让 HAL 侧不再依赖偏移，但**栈侧 P0/P1/P2 仍然依赖**（白名单 + 跳转表 + GOT）。D2 不能替代栈侧补丁 |

### 7.2 前置条件清单（逐项标注难度与证据强度）

| # | 前置条件 | 难度 | 证据强度 |
|---|---|---|---|
| **C1** | 编译一个 `cc_library_shared`（vendor），导出 `HIDL_FETCH_IBluetoothAudioProvidersFactory`，实现 §3.1+§3.2 全部方法（含 MTK 私有 `updataConnParam` / `enterGameMode`） | 中 | **已验证**（接口面来自设备接口库符号枚举） |
| **C2** | 链接 `vendor.mediatek.hardware.bluetooth.audio@2.2`（+`@2.1`）、`libbluetooth_audio_session_mediatek`、`libfmq`、`libhidlbase`、`libbase`、`liblog`、`libutils`、`libcutils`；**ABI 必须与 pid 1006 已加载版本一致**（同进程复用同一份 .so，风险低） | 中 | **已验证**（`hal22.so` 导入表 + 1006 maps） |
| **C3** | `startSession_2_1` 里照抄 AOSP：校验 → 建 `DataMQ(7680, /*EventFlag*/true)` → `BluetoothAudioSession_2_1::OnSessionStarted(session_type_, hostIf, mDataMQ->getDesc(), audio_config_)` → 回传 MQDescriptor | 低 | **已验证**（AOSP 源码 + 会话库导出符号 @0x12d9c） |
| **C4** | provider 覆盖全部 4 个 session type（A2DP_SW / A2DP_OFFLOAD / HEARING_AID / LE_AUDIO×4）；若只做 A2DP_SW，其余必须**显式返回 FAILURE**（会导致 LE Audio 功能回退，需评估） | 中 | 部分（hal22.so 导出了 `A2dpSoftware/A2dpOffload/HearingAid/LeAudio/LeAudioOffload{Input,Output}AudioProvider`） |
| **C5** | 覆盖 `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so`（**形态 C**）：KernelSU post-fs-data `mount --bind` | 中 | **时序已验证**（init.rc L747 post-fs-data 早于 L1311 `class_start hal`；pid 1006 与 init 同 mnt ns 见 R3） |
| **C6** | SELinux 标签：bind-mount 源在 `/data` 时目标沿用源标签，`mtk_hal_audio` 读 `data_file` 可能被拒。缓解：`-o context=u:object_r:vendor_file:s0` 或 KernelSU `sepolicy.rule` 补 allow | 中 | **未实测**（推断） |
| **C7** | 保留厂商原库以支持回退：把原文件复制到一个**不匹配前缀**的名字（如 `orig_hal22.so`）放进同目录 → 需要**目录级**挂载 `/vendor/lib64/hw`（30 个文件约 5 MB + 逐个 restorecon），爆炸半径更大 | 中高 | 已验证（`findFiles` 前缀规则） |
| **C8** | 栈侧仍必须打 P0（`ro.product.name` 白名单）+ P1（HIDL 跳转表 `table[12]`）+ P2（`getCodecConfig` 改写 codec_type），**D2 不能替代** | — | 已验证（R2/R4） |
| **C9** | 若要 192 kHz：还需放宽 `bluetooth_offload_audio_policy_configuration.xml` 的 `samplingRates`（R7 判为回退值，但 APM 侧仍需接受） | 中 | 部分未验证 |
| **C10** | 不需要：VINTF manifest 改动、hwservice_contexts 条目、新 init rc、新进程、新 SELinux 域 | — | **已验证**（同名覆盖路径完全绕开这四项） |

### 7.3 成本 / 收益 / 风险

```
收益（相对现状 P0/P1/P2）：
  ① 192 kHz 准入 ........................ ★ 唯一实质收益
  ② 语义上不再"伪装 V3" ................. 无功能收益（HAL 不读 codec）
  ③ 未来承载 V5 私有控制面的落点 ........ 当前 HIDL 无对应方法，收益 = 0
成本：
  一个可加载的 HIDL HAL 实现（4 个 session type × provider + factory）
  + 挂载与 SELinux 标签工程
  + 与厂商 HAL 全功能等价的风险
风险：
  - 替换 impl 会使该 descriptor 下的**全部** provider 由我们提供；HearingAid/LE Audio 若未实现会一起坏
  - bind-mount 标签处理不当 → dlopen 失败 → BT 音频全废（可用"只改一个文件"快速回退）
  - APEX 升级不影响本路线（impl 在 /vendor），但接口库 ABI 变化会影响
```

### 7.4 推荐的实施顺序（若决定做）

1. **先只做 A2dpSoftware provider**，其余 session type 全部 `return FAILURE`，在 192 kHz 上验证 D2 的唯一收益；
2. 若验证成功再补齐 A2dpOffload/HearingAid（AOSP `2.0default/` 有现成源码）；
3. 采用**形态 C + 目录级挂载**（保留原库作回退），而非形态 D（readdir 顺序不可控）。

---

## 8. 对既有报告的核对与修正

| 既有说法 | 本次复核 |
|---|---|
| R7 §2.5「新增 HIDL 服务需要 VINTF manifest + hwservice_contexts + `hwservice_manager add`」 | ✅ 成立，但 **D2 走"同名替换 impl"完全不触发这三项** —— 这是本次最重要的路线级修正 |
| R7 §8.1 G4「新增 HIDL 服务（自带 V5 结构）→ 第三方不可行」 | ✅ 成立且加强：**连"自带 V5 结构"这个前提都不可能**（F1：`CodecSpecific` 5 个变体、无 `vendorConfig`） |
| R8 §5.1「栈侧不阻（掩码允许 176400/192000）」 | ❌ **修正**：与 R8 自身 §4 闸门①矛盾。逐指令复核 = **栈侧不阻、HAL provider 侧显式拒绝 0x10/0x20**（§6.3 证据 B） |
| R8 D1「低延迟控制面是唯一真实功能缺口，且 HIDL 下 `set_audio_low_latency_mode_allowed` 是空操作」 | ✅ 成立，并补充：**HIDL 接口与实现里 `setLatencyMode`/`LatencyMode` 字符串计数 = 0**，即 HIDL 通路连方法都不存在，不是"空操作"而是"无接口" |
| R3「HAL 与 codec 无关，让 HAL 支持 V5 是伪需求」 | ✅ 成立 |
| R3「厂商 BT audio provider 与 audioserver 同进程」 | ⚠️ 表述：与**音频 HAL 服务（pid 1006）**同进程，audioserver（pid 1109）只是 client（R7 已修正，本次 maps 复核一致） |
| MAIN-findings §4「audio.bluetooth.default.so 只认 HIDL V2.2」 | ✅ 成立（`DT_NEEDED` 只含 HIDL 版会话库；本次 maps 复核它在 pid 1006） |
| 任务描述「能否复用设备上已有的 audio HAL module」 | ✅ **能，且必须**（§4.3）；但**不是**通过 `hw_get_module` 从 provider 里调 —— module 的加载者是音频 HAL 服务进程 |
| 任务描述「VINTF 指向别处」 | ❌ HIDL VINTF 条目**无路径字段**；唯一可改的 `<transport>` 改成 `passthru` 会让栈进程自己 dlopen impl → 会话单例错位 → 必坏 |
| 任务描述「同名注册抢占」 | ⚠️ hwservicemanager 层**允许**（静默覆盖，仅 WARNING），但抢到也没用（同进程约束） |

---

## 9. 未验证 / 未知（明确标注）

1. **bind-mount 的 SELinux 标签实际行为**：本次只做策略与机制推导，未在设备上实测 `mount --bind` 后 `mtk_hal_audio` 能否 dlopen 来自 `/data` 的文件。
2. **`/vendor/lib64/hw` 目录级挂载的可行性**：未实测（需要 30 个文件的复制与 relabel）。
3. **MTK 栈是否用 HAL 上报的 PCM capabilities 钳制协商采样率**：本次扫描 `.text` 未发现 `BluetoothAudioClientInterface::GetAudioCapabilities_2_1`（@0x8825e0 / @0x82f240）的直接 `bl` 调用者，可能是间接调用或死代码 —— 未结论。这影响"放宽 provider 是否足以跑到 192 kHz"。
4. **`vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvider` 是否在 2.1 之上新增方法**：BnHw vtable（256 B）的槽位由 `.relr.dyn` 重定位填充，本次未能解出（RELR 解码未命中该区间），故只按 2.1 方法面 + MTK 私有 `enterGameMode` 陈述。
5. **`updataConnParam(ConnParam)` 的语义与 `ConnParam` 布局**：栈侧 `updataConnParam` 计数 = 0（无人调用），故未深挖。
6. **`LhdcParameters` 第 6/7 字节（+6/+7）的确切字段名**：反汇编只能确定 +0/+4/+5 的字段与类型；+6 由栈写入（LL 标志），+7 无人写。字段名不可从二进制恢复。
7. **`enterGameMode` 的语义**（栈侧实现 @0x834330，324 B）：本次未逐指令分析其行为。
8. **192 kHz 全链路端到端**：即便放宽 provider，仍需 APM/AudioFlinger/编码器/耳机四端配合，本次未实测。

---

## 10. 一句话回答任务问题

**可以自建一个 HIDL 厂商 HAL 实现并替换厂商的 @2.2 impl —— 机制上它只是"往 `/vendor/lib64/hw/` 里同名覆盖一个 .so"，零 VINTF、零 sepolicy、零新进程；但它在 HIDL 2.x 的公共语义下**不可能**原生携带 V5（`CodecSpecific` 恰好 5 个变体、无 `vendorConfig`、`LhdcParameters` 仅 8 字节无版本位、线格式冻结在 APEX 接口库里），而软件编码通路下 HAL 又只消费 PCM —— 所以这条路线对"V5 通路"是伪需求；它唯一真实的能力是**放宽 provider 内部的 `IsSoftwarePcmConfigurationValid`（厂商 provider 显式拒绝 176.4k/192k），从而让 192 kHz 走到会话层**。**
