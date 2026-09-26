# R7 — Android 蓝牙音频 HAL「管线工程」调查（平台知识 + xaga 映射）

> 调查日期：2026-09-25
> 目标：搞清楚 Android 14 上「新增/替换一个蓝牙音频 HAL 实现」需要动哪些系统组件，作为判断各条「真 V5」路线可行性的基础。
> 设备：Redmi Note 11T Pro (xaga / MT6895) / Android 14 / HyperOS OS2.0.12.0.ULOCNXM / KernelSU root
> 方法：android.googlesource.com `?format=TEXT` 原文落盘（`reference/aosp-src/r7/`）+ 设备只读 adb + 拉取的 CIL 策略本地解析
> **本报告只做只读操作**（临时 cp 到 `/data/local/tmp` 的两个 .cil 已 `rm` 清理）

---

## 0. 结论速览（每条都有下文证据）

| # | 结论 | 分级 |
|---|---|---|
| 1 | **BT 音频 HAL 在 AOSP 里没有自己的 SELinux 域/服务命名空间**：HIDL 侧接口 `android.hardware.bluetooth.audio::IBluetoothAudioProvidersFactory` 的 hwservice 类型是 `hal_audio_hwservice`，AIDL 侧 `android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` 是 `hal_audio_service` —— 都被归入「音频 HAL」。MTK 只给自己那份 HIDL 接口另建了 `mtk_hal_bluetooth_audio_hwservice` | 已验证 |
| 2 | 本机 **BT audio HAL provider 不是独立进程**：AOSP HIDL impl（`android.hardware.bluetooth.audio@2.1-impl.so`）、MTK HIDL impl（`vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so`）、**以及音频 HAL 模块 `audio.bluetooth.default.so`** 全部映射在 **pid 1006 = `/vendor/bin/hw/android.hardware.audio.service.mediatek`（`u:r:mtk_hal_audio:s0`）** | 已验证（`/proc/1006/maps`） |
| 3 | 新增 HIDL 服务时 **VINTF manifest 条目是硬要求**：本机 `kEnforceVintfManifest = true`（`libhidlbase.so` 内含 `must be in VINTF manifest in order to register/get.`，且**不含** `not being enforced` 分支字符串），且 `ro.debuggable=0` → treble testing override 不可用。注册（server）与获取（client）两侧都要求 manifest 里 transport=hwbinder | 已验证 |
| 4 | 新增 AIDL 服务时 `add` 权限按 **service_contexts 里的服务名**判定。本机 `plat_service_contexts` 里只有 AOSP 名 → `hal_audio_service`，外加通配 `* → default_android_service`；而 `mtk_hal_audio` **没有** `default_android_service add` 规则 → 用 `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` 这个名字注册会被 SELinux 直接拒（除非打策略补丁） | 已验证（CIL 原文） |
| 5 | A14 栈侧的 AIDL 探测是 `AServiceManager_isDeclared` + `AServiceManager_waitForService` + `getProviderCapabilities`；`getInterfaceVersion` 只在 A14 **QPR3 及以后**的 HalVersionManager 里出现；**`getSupportedProfiles` 在 A14 与 main 分支都不存在**（AIDL factory 只有 `getProviderCapabilities`/`openProvider` 两个方法） | 已验证（diff 无差异） |
| 6 | 软件编码（`A2DP_SOFTWARE_ENCODING_DATAPATH`）下 **HAL 侧只收 PCM**：`setup_codec()` 只在 offload 分支下发 codecConfig，SW 分支只发 `pcmConfig`。**独立复核确认 MAIN-findings §3 成立** | 已验证（AOSP 源码 + 设备反汇编） |
| 7 | `openOutputStream` 失败的判定点：`adev_open_output_stream()` → `SetUp()` → `IsSessionReady()` 为假 → 返回 `-EINVAL`；framework 侧 `AudioHwDevice::openOutputStream()` 打印 `HAL returned sampleRate 0, Format 0, channelMask 0, status -22`；APM 打印 `openOutputWithProfileAndDevice failed to open output -19` | 已验证（源码 + 日志逐字对上） |
| 8 | **采样率上限不在 audio_policy_configuration.xml 里钳制**：BT module 的 `a2dp output` mixPort 在本机**没有任何 `<profile>`** → APM 视其为动态 profile，用 `getParameters(keyStreamSupportedSamplingRates)` 向 HAL 查询，BT module 由会话 PCM 配置回答（`out_get_parameters` → `LoadAudioConfig`）。日志实证：先以 `SamplingRate 0` 打开，再以 `SamplingRate 96000` 重开。真正的拒绝发生在 vendor session 库 `IsSoftwarePcmConfigurationValid` | 已验证 |
| 9 | 本机**不存在** `libbluetooth_audio_session_aidl.so`（APEX 与 /vendor 全无，只有 HIDL 版 `libbluetooth_audio_session.so` 与 `libbluetooth_audio_session_mediatek.so`）→ 走 AIDL 路线必须自带该库 + AIDL provider 实现 + AIDL-aware 的 `audio.bluetooth.default.so` | 已验证 |
| 10 | 「不新增服务」的替代做法里，**hook 厂商 HAL 的 setCodecConfig 对 SW 通路零收益**（HAL 根本不看 codec）；唯一有意义的仍是栈内补丁（现有 P0/P1/P2） | 已验证（源码+反汇编） |

---

## 1. 方法与环境（可复现）

### 1.1 源码落盘

```
# 工具（前序报告已备）
cd d:/Cache/Hyperos/lhdcv5-tr/analysis/scripts
export PATH="/d/Tools/Anaconda3/envs/py3123:/d/Tools/Anaconda3/envs/py3123/Scripts:$PATH"
python r7_fetch.py     # 第 1 批（hwservicemanager/libhidl/sepolicy/hwif/audiopolicy）
python r7_fetch2.py    # 第 2 批（Bluetooth module: audio_bluetooth_hw / audio_hal_interface）
```
落盘目录：`d:/Cache/Hyperos/lhdcv5-tr/reference/aosp-src/r7/`（本文引用的所有 AOSP 源码都在这里）
分支：`refs/heads/android14-release`（= UP1A.231005.007），另取 `refs/heads/main` 做 AIDL 接口对照

### 1.2 设备侧只读查询

```
export MSYS_NO_PATHCONV=1; ADB="d:/Cache/Hyperos/platform-tools/adb.exe"
$ADB shell su -c "lshal"                                  # HIDL 服务清单
$ADB shell su -c "ps -A -Z"                               # 域
$ADB shell su -c "grep -i bluetooth /proc/1006/maps"      # 进程内映射
$ADB shell su -c "grep -n <pat> /vendor/etc/vintf/manifest.xml"
$ADB shell su -c "grep -n <pat> /vendor/etc/selinux/vendor_sepolicy.cil"
$ADB shell su -c "strings /system/lib64/libhidlbase.so"   # 编译期开关取证
```
> 踩坑：`adb shell su -c 'grep -E "a|b" f'` 会因为 adb 丢引号把 `|` 当管道 → 静默失败（exit 127）。
> 必须写成 `su -c "grep -e a -e b f"`。

---

## 2. (a) HIDL 蓝牙音频 HAL 的服务注册与发现

### 2.1 服务名格式（已验证）

HIDL 服务全名 = `<package>@<major>.<minor>::<Interface>/<instance>`：

```
android.hardware.bluetooth.audio@2.0::IBluetoothAudioProvidersFactory/default      ← AOSP HIDL
android.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default      ← AOSP HIDL
vendor.mediatek.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default   ← MTK HIDL
vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory/default   ← MTK HIDL
```
设备实测（`lshal`，只读）：
```
DM,FC Y android.hardware.bluetooth.audio@2.0::IBluetoothAudioProvidersFactory/default  0/8  1006
DM,FC Y android.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default  0/8  1006
DM,FC Y vendor.mediatek.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default 0/8 1006
DM,FC Y vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory/default 0/8 1006
```
**四个服务全在 pid 1006**（音频 HAL 服务进程）。

AOSP 侧接口定义（`r7/hwif/2.0/IBluetoothAudioProvidersFactory.hal`）只有两个方法：
```
openProvider(SessionType) generates (Status, IBluetoothAudioProvider)
getProviderCapabilities(SessionType) generates (vec<AudioCapabilities>)
```
`r7/hwif/2.0/IBluetoothAudioProvider.hal`：`startSession(IBluetoothAudioPort, AudioConfiguration) generates (Status, fmq_sync<uint8_t> dataMQ)`。
**HIDL 2.0 没有 `IBluetoothAudioHost`**（那是更早的命名）；2.0/2.1 的宿主接口叫 `IBluetoothAudioPort`（本机也是这个名字）。

### 2.2 注册（server 侧）——`registerAsService` 的两道关

`r7/libhidl/ServiceManagement.cpp:965-1000`（`registerAsServiceInternal`，原文）：
```cpp
    if (kEnforceVintfManifest && !isTrebleTestingOverride()) {
        Return<Transport> transport = sm->getTransport(descriptor, name);
        ...
        if (transport != Transport::HWBINDER) {
            LOG(ERROR) << "Service " << descriptor << "/" << name
                       << " must be in VINTF manifest in order to register/get.";
            return UNKNOWN_ERROR;
        }
    }
```
- 关 1：**VINTF manifest 必须声明该 HAL**（`sm->getTransport()` 读的是 manifest，不是运行时表）。
- 关 2：`sm->addWithChain()` → hwservicemanager `ServiceManager::add()` → `mAcl.canAdd(fqName, callingContext)`。

`r7/hwservicemanager/AccessControl.cpp:42-55`（原文）：
```cpp
bool AccessControl::canAdd(const std::string& fqName, const CallingContext& callingContext) {
    ...
    const std::string checkName = fqIface.package() + "::" + fqIface.name();
    return checkPermission(callingContext, kPermissionAdd, checkName.c_str());   // kPermissionAdd = "add"
}
```
`checkPermission` 先 `selabel_lookup(mSeHandle, &targetContext, interface, 0)` 查 **hwservice_contexts**；查不到直接 `return false`（原文：`ALOGE("No match for interface %s in hwservice_contexts")`），查到后 `selinux_check_access(sid, tctx, "hwservice_manager", perm)`。
→ **注册 = manifest 声明 + hwservice_contexts 有条目 + 目标域有 `hwservice_manager add`**。

### 2.3 发现（client 侧）——`getService()` 的失败条件

`r7/libhidl/ServiceManagement.cpp:857-955`（`getRawServiceInternal`，原文）：
```
sm = defaultServiceManager1_1();
Return<Transport> transportRet = sm->getTransport(descriptor, instance);   // ① 先问 manifest
const bool vintfHwbinder = (transport == HWBINDER);
const bool vintfPassthru = (transport == PASSTHROUGH);
const bool allowLegacy   = !kEnforceVintfManifest || (trebleTestingOverride && isDebuggable());
const bool vintfLegacy   = (transport == EMPTY) && allowLegacy;
...
for (int tries = 0; !getStub && (vintfHwbinder || vintfLegacy); tries++) {  // ② 再问 hwservicemanager
    Return<sp<IBase>> ret = sm->get(descriptor, instance);
    ...
}
if (getStub || vintfPassthru || vintfLegacy) { ... getPassthroughServiceManager()->get(...) }
return nullptr;
```
`r7/hwservicemanager/ServiceManager.cpp:269-292`（`ServiceManager::get`，原文）：
```cpp
    if (!mAcl.canGet(fqName, getBinderCallingContext())) return nullptr;      // ① SELinux find
    HidlService* hidlService = lookup(fqName, name);
    if (hidlService == nullptr) { tryStartService(fqName, name); return nullptr; }   // ② 未注册 → 懒加载
    sp<IBase> service = hidlService->getService();
    if (service == nullptr) { tryStartService(fqName, name); return nullptr; }
```
`tryStartService`（同文件 246-267）就是 `SetProperty("ctl.interface_start", fqName + "/" + name)` → 让 init 拉起 lazy HAL。

**失败条件汇总（HIDL，本机语境）**：

| 条件 | 结果 |
|---|---|
| manifest 无该 HAL（transport=EMPTY）且 `kEnforceVintfManifest=true` | 客户端**根本不进 get 循环** → 直接走 passthrough 兜底（`getStub`）或返回 nullptr |
| manifest 有、但服务进程没起来 | `get()` 返回 nullptr，同时尝试 `ctl.interface_start` 拉起（lazy HAL 机制） |
| 调用域对 hwservice 类型没有 `find` | `canGet` 返回 false → nullptr，**且不会有任何 hwbinder 流量**（日志只有 `getService: unable to call into hwbinder service`） |
| 版本不匹配 | `canCastInterface` 失败 → `getService: received incompatible service` |
| `persist.bluetooth.bluetooth_audio_hal.disabled` 为真 | 栈侧整条 BT audio HAL 被关（`client_interface_{hidl,aidl}.h:30-33`），与上面机制无关 |

**本机编译期开关取证（已验证）**：
```
$ adb shell su -c "strings /system/lib64/libhidlbase.so" | grep -e "must be in VINTF" -e "not being enforced"
 must be in VINTF manifest in order to register/get.          ← 存在 ⇒ kEnforceVintfManifest 分支被编译进来
（"not being enforced" 无匹配）                               ← 该分支被编译掉
```
`getprop ro.debuggable` = `0`，`getprop ro.treble.enabled` = `true` → `isTrebleTestingOverride()` 恒 false（`ServiceManagement.cpp:177-185`：`if (kEnforceVintfManifest && !isDebuggable()) return false;`）。

### 2.4 hwservice_contexts 与 SELinux（设备实测）

`/system/etc/selinux/plat_hwservice_contexts`（只读 grep）：
```
android.hardware.bluetooth.audio::IBluetoothAudioProvidersFactory   u:object_r:hal_audio_hwservice:s0
android.hardware.bluetooth.a2dp::IBluetoothAudioOffload            u:object_r:hal_audio_hwservice:s0
android.hardware.bluetooth::IBluetoothHci                          u:object_r:hal_bluetooth_hwservice:s0
```
`/vendor/etc/selinux/vendor_hwservice_contexts`：
```
vendor.mediatek.hardware.bluetooth.audio::IBluetoothAudioProvidersFactory u:object_r:mtk_hal_bluetooth_audio_hwservice:s0
```
CIL 规则（`raw/r7_vendor_sepolicy.cil`）：
```
L4812: (allow bluetooth_31_0 mtk_hal_bluetooth_audio_hwservice (hwservice_manager (find)))
L6784: (allow mtk_hal_audio mtk_hal_bluetooth_audio_hwservice (hwservice_manager (add find)))
```
→ **`bluetooth` 域只有 `find`；`add` 只在 `mtk_hal_audio`（音频 HAL 服务域）手里。** 这就是「BT 栈永远不可能是 BT 音频 HAL 的服务端」的策略根源。

### 2.5 新增一个 HIDL 服务的完整清单（平台通用）

| # | 需要什么 | 本机可写性 |
|---|---|---|
| 1 | 实现库（`.so`），导出 `HIDL_FETCH_<Iface>` 或自行 `registerAsService` | 自编译 |
| 2 | 承载进程 + init `.rc`（`/vendor/etc/init/*.rc`，`class hal`；lazy 则加 `interface <fqname>` 让 `ctl.interface_start` 生效） | /vendor 只读，可 root 覆盖 |
| 3 | **`/vendor/etc/vintf/manifest.xml`（或 `/vendor/etc/vintf/manifest/*.xml` fragment）**：`<hal format="hidl"><name>…</name><transport>hwbinder</transport><version>…</version><interface><name>…</name><instance>default</instance></interface></hal>` | 同上 |
| 4 | `hwservice_contexts` 条目（把接口名映射到 hwservice 类型） | **平台/vendor 只读**，root 需 sepolicy 补丁 |
| 5 | 进程域的 `allow <domain> <hwservice_type>:hwservice_manager add`（通常由 `hal_attribute_hwservice()` 宏给出）+ `allow <domain> hwservicemanager:binder call`（`hwbinder_use()`） | 同上 |
| 6 | 二进制文件路径的 file_contexts（`/vendor/bin/hw/...` 默认 `vendor_file`，`hal_audio_exec` 之类需显式） | 同上 |
| 7 | 框架兼容矩阵（FCM）里允许该 HAL（否则 `checkvintf` 报 manifest 与 FCM 不一致） | 只读 |
| 8 | 客户端的 `find` 规则（`hal_client_domain(bluetooth, hal_audio)` 已给出 `bluetooth → hal_audio_hwservice find`） | 已满足 |

**关键取舍**：第 4/5 条是本机**唯一无法通过"加文件"绕过的**（`hwservice_contexts` 与 `hwservice_manager add` 权限都在只读分区，必须 sepolicy 补丁；KernelSU 的 `sepolicy.rule` 可在开机时注入 allow 规则，这是唯一可行的注入点）。

---

## 3. (b) AIDL 蓝牙音频 HAL 的对应机制

### 3.1 注册与发现

| 维度 | HIDL | AIDL |
|---|---|---|
| 传输 | hwbinder（hwservicemanager） | binder（servicemanager） |
| 服务名 | `android.hardware.bluetooth.audio@2.1::IBluetoothAudioProvidersFactory/default` | `android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` |
| 注册 API | `IBluetoothAudioProvidersFactory::registerAsService()` | `AServiceManager_addService(binder, instance_name)` |
| 发现 | `getTransport`(manifest) + `get`(hwservicemanager) | `AServiceManager_isDeclared` / `waitForService` / `checkService` |
| 声明位置 | `/vendor/etc/vintf/manifest.xml` | 同（`<hal format="aidl">`，通常由 `vintf_fragments` 生成） |
| SELinux | `hwservice_contexts` + `hwservice_manager` 类 | `service_contexts` + `service_manager` 类 |

AOSP 的 AIDL 默认实现注册方式（`r7/hwif/aidldefault/service.cpp` 原文）：
```cpp
extern "C" __attribute__((visibility("default"))) binder_status_t
createIBluetoothAudioProviderFactory() {
  auto factory = ::ndk::SharedRefBase::make<BluetoothAudioProviderFactory>();
  const std::string instance_name =
      std::string() + BluetoothAudioProviderFactory::descriptor + "/default";
  binder_status_t aidl_status = AServiceManager_addService(factory->asBinder().get(), instance_name.c_str());
  ALOGW_IF(aidl_status != STATUS_OK, "Could not register %s, status=%d", instance_name.c_str(), aidl_status);
  return aidl_status;
}
```
VINTF 片段（`…/aidl/default/bluetooth_audio.xml` 原文）：
```xml
<manifest version="1.0" type="device">
    <hal format="aidl">
        <name>android.hardware.bluetooth.audio</name>
        <version>3</version>
        <fqname>IBluetoothAudioProviderFactory/default</fqname>
    </hal>
</manifest>
```
`Android.bp`：`cc_library_shared { name: "android.hardware.bluetooth.audio-impl", vendor: true, vintf_fragments: ["bluetooth_audio.xml"] ... }` —— 注意它是 **shared lib**（不是可执行文件），由**宿主进程**调用 `createIBluetoothAudioProviderFactory()` 完成注册。

### 3.2 AIDL 的 `add` 权限判定（设备实测）

`r7/svcmgr/Access.cpp:120-130`（原文）：
```cpp
bool Access::canAdd(const CallingContext& ctx, const std::string& name) { return actionAllowedFromLookup(ctx, name, "add"); }
...
    if (selabel_lookup(getSehandle(), &tctx, name.c_str(), SELABEL_CTX_ANDROID_SERVICE) != 0) { ... }
```
→ 按 **服务名字符串** 查 `service_contexts`，再 `selinux_check_access(..., "service_manager", "add")`。

本机 `/system/etc/selinux/plat_service_contexts`：
```
android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default   u:object_r:hal_audio_service:s0
android.hardware.audio.core.IModule/a2dp                                 u:object_r:hal_audio_service:s0
android.hardware.audio.core.IModule/bluetooth                            u:object_r:hal_audio_service:s0
...
*                                                                        u:object_r:default_android_service:s0     ← 第 438 行，通配兜底
```
本机 `/vendor/etc/selinux/vendor_service_contexts`：**没有任何 bluetooth audio 条目**（只有 MTK NN shim / 小米 mrm / goodix 等）。

CIL 规则（`raw/r7_plat_sepolicy.cil`）：
```
L3934: (type hal_audio_service)
L9758: (allow hal_audio_client hal_audio_service (service_manager (find)))
L9759: (allow hal_audio_server hal_audio_service (service_manager (add find)))
L19892: (allow bluetooth hal_audio_service (service_manager (find)))
```
域归属（`raw/r7_vendor_sepolicy.cil`）：
```
L590: (typeattributeset hal_audio (… mtk_hal_audio …))
L592: (typeattributeset hal_audio_server (… mtk_hal_audio …))
L995(plat): (typeattributeset hal_audio_client (audioserver bluetooth dumpstate system_server ))
L9739(plat): (allow hal_audio_client hal_audio_server (binder (call transfer)))
```
**推论（已验证级别的直接后果）**：
- 用 **AOSP 名** `android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` 注册 → 命中 `hal_audio_service`，`mtk_hal_audio ∈ hal_audio_server` ⇒ `add` **放行**；`bluetooth` 有 `find` ⇒ 栈侧可查。
- 用 **MTK 名** `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` 注册 → 只命中通配 `default_android_service`；`mtk_hal_audio` **没有** `default_android_service add` 规则（grep 结果为空）⇒ **被拒**。`bluetooth` 也没有 `default_android_service find`。

> 这条结论很关键：**「加一个 MTK AIDL 服务」在本机连注册这一步都过不了**，除非同时打 sepolicy 补丁；
> 而注册成 **AOSP 名**可以过策略关（`hal_version_` 会走 MTK 版 HalVersionManager 的第二个 AIDL 分支 = 4）。

### 3.3 版本 / 特性探测

AIDL 接口（`r7/hwif/aidl/IBluetoothAudioProviderFactory.aidl` 原文，`@VintfStability`）**只有两个方法**：
```aidl
AudioCapabilities[] getProviderCapabilities(in SessionType sessionType);
IBluetoothAudioProvider openProvider(in SessionType sessionType);
```
- **`getSupportedProfiles` 不存在**：与 `refs/heads/main` 版本 `diff` **无任何差异**（`diff hwif/aidl/IBluetoothAudioProviderFactory.aidl hwif/aidl/main/IBluetoothAudioProviderFactory.aidl` 输出为空）。
  「会话类型支持列表」的等价物是 `getProviderCapabilities(SessionType)`（返回空数组 = 不支持该 session type）。
- `getInterfaceVersion` / `getInterfaceHash` 是 AIDL 生成代码自带的（`@VintfStability` 接口都会有），**栈侧只在 A14 QPR3+ 的 `HalVersionManager` 里显式使用**（R1 §(f) 已取证 `GetAidlInterfaceVersion()`）。
- 本机（MTK fork）的探测顺序（R1/R2 已反汇编确认）：`AServiceManager_checkService(MTK AIDL 名)` → `listManifestByInterface(MTK HIDL 2.2)` → `listManifestByInterface(MTK HIDL 2.1)` → `checkService(第二个 AIDL 名)`。**只用 `checkService`，不读属性、不查 VINTF**。
- 但**数据通路侧**（`BluetoothAudioClientInterface::FetchAudioProvider`，`r7/bt/audio_hal_interface/aidl/client_interface_aidl.cc:57-140` 原文）：
```cpp
bool BluetoothAudioClientInterface::is_aidl_available() {
  return AServiceManager_isDeclared(kDefaultAudioProviderFactoryInterface.c_str());
}
...
  auto provider_factory = IBluetoothAudioProviderFactory::fromBinder(
      ::ndk::SpAIBinder(AServiceManager_waitForService(kDefaultAudioProviderFactoryInterface.c_str())));
```
→ **`isDeclared` 才是 AIDL 服务能否被真正使用的闸门**（它查 VINTF manifest），`checkService` 只影响版本选择。两者**都要满足**。

---

## 4. (c) 软件编码（A2DP_SOFTWARE_ENCODING_DATAPATH）完整数据流

### 4.1 进程拓扑（本机实测，`/proc/<pid>/maps`）

```
audioserver (pid 1109, u:r:audioserver:s0)                      ← AudioFlinger / AudioPolicyService
   │  binder（audio HAL 7.1 HIDL 接口，IDevicesFactory::openDevice("bluetooth")）
   ▼
android.hardware.audio.service.mediatek (pid 1006, u:r:mtk_hal_audio:s0)   ← 音频 HAL 服务
   ├─ /vendor/lib64/hw/audio.bluetooth.default.so            ← BT audio HAL module（音频 HAL "bluetooth" module）
   ├─ /vendor/lib64/hw/android.hardware.bluetooth.audio@2.1-impl.so      ← AOSP HIDL BT audio provider
   ├─ /vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so  ← MTK HIDL BT audio provider
   ├─ /vendor/lib64/libbluetooth_audio_session.so
   └─ /vendor/lib64/libbluetooth_audio_session_mediatek.so   ← 会话/FMQ 单例
   ▲
   │  hwbinder（IBluetoothAudioProvidersFactory@2.2 / IBluetoothAudioPort 回调）
   │
com.android.bluetooth (pid 2688, u:r:bluetooth:s0)            ← BT 栈 libbluetooth_jni.so
```

**证据（逐条可复现）**：
```
$ adb shell su -c "grep -i bluetooth /proc/1006/maps"
7cac7ca000-… /vendor/lib64/hw/audio.bluetooth.default.so
7cc6110000-… /vendor/lib64/libbluetooth_audio_session.so
7cc6156000-… /vendor/lib64/hw/android.hardware.bluetooth.audio@2.1-impl.so
7cc61c6000-… /vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so
7cc6211000-… /vendor/lib64/libbluetooth_audio_session_mediatek.so

$ adb shell su -c "grep -i bluetooth /proc/1109/maps"      # audioserver：只有属性区，没有任何 BT 音频库
（无 audio.bluetooth.default.so）

$ adb shell su -c "ps -A -Z" | grep -i -e audio -e bluetooth
u:r:mtk_hal_audio:s0   audioserver 1006  … android.hardware.audio.service.mediatek
u:r:mtk_hal_bluetooth:s0 bluetooth 1007  … android.hardware.bluetooth@1.1-service-mediatek
u:r:audioserver:s0     audioserver 1109  … audioserver
u:r:bluetooth:s0       bluetooth  2688  … com.android.bluetooth
```
日志侧同证（`artifacts/logs/a2dp_raw.log:45106`）：
```
I/AudioFlinger(11326): loadHwModule() Loaded bluetooth audio interface, handle 18
E/AudioFlinger(11326): loadHwModule() error -22 loading module a2dp       ← 纯输入 module，本机不需要
```
→ **BT audio HAL module 与 BT audio provider 同进程**。这不是巧合，而是设计前提：会话/FMQ 是**进程内单例**（`BluetoothAudioSessionReport::OnSessionStarted` 由 provider 调用、`BluetoothAudioSessionControl::IsSessionReady` 由 module 调用，都在 `libbluetooth_audio_session*` 里，纯进程内静态对象）。

> 平台知识：AIDL 音频 HAL 时代这套关系被显式化为 binder 服务
> `android.hardware.audio.core.IModule/a2dp`、`…/bluetooth`、`…/hearing_aid`（`plat_service_contexts` 里三条都是 `hal_audio_service`）。
> 本机是 HIDL 音频 HAL（`android.hardware.audio@7.0/7.1::IDevicesFactory`，见 `lshal`），
> AudioFlinger 通过 `IDevicesFactory::openDevice_7_1(string device)`（`r7/audio/7.1/IDevicesFactory.hal:56`）
> 拿到名为 `"bluetooth"` 的设备；该名字由厂商 `audio_policy_configuration.xml` 的 `<module name="bluetooth">` 给出，
> 由 **HAL 服务进程** dlopen 对应 `.so`。这就是 `audio.bluetooth.default.so` 出现在 pid 1006 而不是 audioserver 的原因。

### 4.2 控制面时序（本机 + AOSP 源码）

```
① BT 栈启动：init()
   r7/bt/audio_hal_interface/aidl/a2dp_encoding_aidl.cc:360-400
     BluetoothAudioClientInterface::is_aidl_available() → false（本机无 AIDL 服务）
   → 回退 HIDL：hidl::a2dp::init() → openProvider(A2DP_SOFTWARE_ENCODING_DATAPATH)
② 每次 codec 配置变化：setup_codec()
   hidl/a2dp_encoding_hidl.cc:430-465（原文）
     if (!a2dp_get_selected_hal_codec_config(&codec_config)) return false;   ← ★ 失败即整条链路断
     should_codec_offloading = IsCodecOffloadingEnabled(codec_config);
     if (sessionType == A2DP_HARDWARE_OFFLOAD_DATAPATH) audio_config.codecConfig(codec_config);
     else { a2dp_get_selected_hal_pcm_config(&pcm_config); audio_config.pcmConfig(pcm_config); }
     return active_hal_interface->UpdateAudioConfig(audio_config);           ← 只发 PCM
③ 起流：start_session() → active_hal_interface->StartSession()
     → provider->startSession(hostIf, audioConfig) generates (Status, dataMQ)
④ HAL 侧：A2dpSoftwareAudioProvider::startSession（r7/hwif/2.0default/A2dpSoftwareAudioProvider.cpp 原文）
     - 只接受 pcmConfig（否则 UNSUPPORTED_CODEC_CONFIGURATION）
     - IsSoftwarePcmConfigurationValid(pcmConfig) 校验
     - mDataMQ = new DataMQ(kDataMqSize, EventFlag=true)      ← ★ FMQ 由 provider 创建
     - BluetoothAudioSessionReport::OnSessionStarted(session_type_, hostIf, mDataMQ->getDesc(), audio_config_)
     - 把 MQDescriptor 回传 BT 栈
⑤ 打开输出流：APM → AudioFlinger(module 18="bluetooth") → IDevicesFactory::openDevice("bluetooth")
     → audio.bluetooth.default.so : adev_open_output_stream
     → BluetoothAudioPortHidlOut/AidlOut::SetUp(devices)
         → init_session_type(device)  → IsSessionReady(session_type_)   ← ④ 未成功则这里失败
         → LoadAudioConfig(config)   ← 把 pcmConfig 变成 sample_rate/format/channel_mask
⑥ 控制回调：IBluetoothAudioPort::startStream → HAL 模块 BluetoothAudioPort::Start()
     → BluetoothAudioSession::StartStream → provider 侧 ReportControlStatus
```

### 4.3 数据面（FMQ，不是 streamOut）

```
应用 AudioTrack → AudioFlinger 混音线程
   → audio.bluetooth.default.so : out_write()
   → BluetoothAudioPortOut::WriteData()          (device_port_proxy.cc:527)
   → BluetoothAudioSessionControl::GetSessionInstance(A2DP_SOFTWARE_ENCODING_DATAPATH)
   → BluetoothAudioSession::OutWritePcmData()    (utils/session 或 aidl_session)
   → MessageQueueBase<MQDescriptor<uint8_t>>::write()
   ============ FMQ（共享内存，SynchronizedReadWrite） ============
   → BT 栈 libbluetooth_jni.so : MessageQueueBase<…>::read()   （.dynsym 已确认存在）
   → LHDC 编码 → L2CAP → 耳机
```
**明确否证**：不存在 `IBluetoothAudioHost::streamOut`。HIDL 2.0/2.1 与 AIDL V1~V3 的软件通路**都是 FMQ 传 PCM**，HIDL/AIDL 调用里没有音频数据（R1 §(h)、R3 §5.3 一致）。

### 4.4 对本项目最重要的一条

`setup_codec()` 的 SW 分支**从不把 codec 配置发给 HAL**；`codecConfig` 只用于 `IsCodecOffloadingEnabled()` 判定。
→ 对 HAL 而言，「V5 伪装成 V3」与「原生 V5」**逐字节相同**（MAIN-findings §3 独立复核成立）。
→ 「让 HAL 支持 V5」在 SW 通路下是**伪需求**；真正的缺口只在**栈侧**（HIDL 无 V5 转换函数）。

---

## 5. (d) SELinux 域（AOSP 14 + 本机）

### 5.1 AOSP 侧

- **没有 `hal_bluetooth_audio` 域**：`system/sepolicy/public/` 下只有 `hal_bluetooth.te` 与 `hal_audio.te`（目录列表已验证）。BT 音频 HAL 被并入音频 HAL。
- `r7/sepolicy/public_hal_audio.te`（原文）：`hal_attribute_hwservice(hal_audio, hal_audio_hwservice)`、`hal_attribute_service(hal_audio, hal_audio_service)`、`binder_call(hal_audio_client, hal_audio_server)`。
- `r7/sepolicy/bluetooth.te`（原文）：`hal_client_domain(bluetooth, hal_audio)` —— BT 栈作为音频 HAL 的**客户端**。
- `r7/sepolicy/hwservice_contexts`：`android.hardware.bluetooth.audio::IBluetoothAudioProvidersFactory  u:object_r:hal_audio_hwservice:s0`。
- `r7/sepolicy/service_contexts`：`android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default u:object_r:hal_audio_service:s0`。

### 5.2 本机（xaga）

| 对象 | 域 / 类型 | 证据 |
|---|---|---|
| 音频 HAL 服务（含 BT audio provider + BT module） | `u:r:mtk_hal_audio:s0` | `ps -A -Z` |
| 蓝牙芯片 HAL | `u:r:mtk_hal_bluetooth:s0` | `ps -A -Z` |
| BT 栈（应用） | `u:r:bluetooth:s0` | `ps -A -Z` |
| AOSP HIDL BT audio 接口 | `hal_audio_hwservice` | `plat_hwservice_contexts` |
| MTK HIDL BT audio 接口 | `mtk_hal_bluetooth_audio_hwservice` | `vendor_hwservice_contexts` |
| AIDL BT audio 接口名（AOSP 名） | `hal_audio_service` | `plat_service_contexts` |
| 是否存在 `hal_bluetooth_audio` 域 | **平台策略 0 处，vendor 策略 7 处（均为 `mtk_hal_bluetooth_audio_hwservice` 类型，不是域）** | `grep -c` |

**新增服务需要的 sepolicy（本机缺口）**：
1. `hwservice_contexts` / `service_contexts` 条目 —— **只读分区**，必须策略补丁（KernelSU `sepolicy.rule` / magiskpolicy 在开机注入）。
2. 新域或复用域：
   - 复用 `mtk_hal_audio`：**HIDL add 已有**（`mtk_hal_bluetooth_audio_hwservice add find`）；AIDL add 走 `hal_audio_server → hal_audio_service add` **已有**。
   - 新域：需要完整的 `domain`/`hwbinder_use`/`halserverdomain`/`add`/`find`/`file_contexts`/`entrypoint` 全套，全部要策略补丁。
3. 客户端 `bluetooth` 的 `find`：HIDL 侧已有（`mtk_hal_bluetooth_audio_hwservice find`；AOSP 名走 `hal_client_domain(bluetooth, hal_audio)`）；AIDL 侧已有（`bluetooth hal_audio_service find`）。
4. binder `call`：`hal_audio_client → hal_audio_server` 已有（`bluetooth ∈ hal_audio_client`，`mtk_hal_audio ∈ hal_audio_server`）。

---

## 6. (e) audio_policy_configuration.xml 的作用与采样率钳制分层

### 6.1 本机策略文件结构（只读）

```
/vendor/etc/audio_policy_configuration.xml
  ├─ <module name="primary" halVersion="3.0">            ← BT SCO 端口；且 route: BT A2DP Out ← primary output,deep_buffer,fast,compress_offload
  │     devicePort "BT A2DP Out" encodedFormats="AUDIO_FORMAT_SBC AUDIO_FORMAT_AAC"
  │                              PCM 44100 48000（仅这两个）
  ├─ xi:include bluetooth_offload_audio_policy_configuration.xml   ← <module name="bluetooth" halVersion="2.0">
  │     mixPort "a2dp output" role="source"     ← ★ 没有任何 <profile>
  │     devicePort "BT A2DP Out" PCM samplingRates="44100 48000 88200 96000"
  │                 encodedFormats="AUDIO_FORMAT_LDAC AUDIO_FORMAT_LHDC AUDIO_FORMAT_LHDC_LL AUDIO_FORMAT_APTX AUDIO_FORMAT_APTX_HD"
  ├─ xi:include a2dp_in_audio_policy_configuration.xml             ← <module name="a2dp">（仅输入）
  └─ xi:include usb / r_submix …
```
（`analysis/raw/16_bt_offload_policy.xml`、`17_apm_xml_bt.txt`、`18_a2dp_policy.xml`）

### 6.2 谁决定 `openOutputStream` 可用

1. `AudioPolicyManager::checkOutputsForDevice()`（`r7/audiopolicy/AudioPolicyManager.cpp:6276+` 原文）：
   收集所有 `profile->supportsDevice(device)` 的 **mixPort**，逐个 `openOutputWithProfileAndDevice()`。
   先 `mpClientInterface->getAudioPort(&port)` 把 **HAL 上报的端口属性** import 进 device descriptor。
2. `openOutputWithProfileAndDevice()`（同文件 8210+ 原文）：
   `desc->open(halConfig=nullptr, …)` → 若失败：`ALOGE("%s failed to open output %d", __func__, status)`（**与设备日志 `openOutputWithProfileAndDevice failed to open output -19` 逐字吻合**）。
3. `SwAudioOutputDescriptor::open()`（`r7/audiopolicy/AudioOutputDescriptor.cpp:567` 原文）：
   `halConfig==nullptr` 时用 `mSamplingRate/mChannelMask/mFormat`（初始为 0）→ 于是日志出现 `SamplingRate 0, Format 00000000, Channels 0`。
4. AudioFlinger → HAL 服务 → `adev_open_output_stream()`（`r7/bt/audio_bluetooth_hw/stream_apis.cc:720-745` 原文）：
```cpp
  if (!out->bluetooth_output_->SetUp(devices)) {
    out->bluetooth_output_ = nullptr;
    LOG(ERROR) << __func__ << ": cannot init HAL";
    return -EINVAL;                                  // ← ★ 会话未就绪就死在这里
  }
```
   `SetUp()` → `init_session_type()` → `if (!BluetoothAudioSessionControl::IsSessionReady(session_type_)) return false;`（`device_port_proxy.cc:161-216` 原文）。
5. framework 侧打印：`r7/audioflinger/AudioHwDevice.cpp` 原文
   `ALOGI("openOutputStream(), HAL returned sampleRate %d, Format %#x, channelMask %#x, status %d", …)` —— **报告里的失败行就是这一行**。

### 6.3 采样率上限在哪一层钳制（★ 对 R3 的细化）

| 层 | 机制 | 是否真的钳制 |
|---|---|---|
| L1 `/vendor/etc/audio_policy_configuration.xml` | mixPort/devicePort 的 `samplingRates`、`encodedFormats` | **不是硬钳制**。本机 BT module 的 `a2dp output` mixPort **无 profile** → APM 认为是**动态 profile**，转而向 HAL 查询（见下）。devicePort 的 `samplingRates` 只作为 `devDesc->getAudioProfiles()` 的**回退值**（`updateAudioProfiles()` 里 `repliedParameters.get(...) != NO_ERROR` 分支） |
| L2 音频 HAL module（`audio.bluetooth.default.so`） | `LoadAudioConfig()` 直接把会话里的 `pcmConfig.sampleRateHz` 抄进 `config->sample_rate`（`device_port_proxy.cc:336-372` 原文，**无任何 clamp**）；`out_set_sample_rate()` 若与当前不同则返回 -1 | **不钳制**，只**上报** |
| L2' 同 module 的 `out_get_parameters()` | `AUDIO_PARAMETER_STREAM_SUP_SAMPLING_RATES` 返回**会话 PCM 配置的那一个值**（`stream_apis.cc:425-470` 原文，硬编码比较 16000…192000 只是格式化） | 这是 APM 实际采信的来源 |
| L3 vendor session 库 `libbluetooth_audio_session_mediatek.so` | `IsSoftwarePcmConfigurationValid(_2_1)` 掩码 `{0x1,0x2,0x4,0x8,0x40,0x80}`，`GetSoftwarePcmCapabilities_2_1` 常量 `0x3cf` | **真钳制**（R3 §8 已取证，本次未重复） |
| L4 BT 栈 | 协商出的 codec sample rate（`A2dpCodecToHalSampleRate`） | 源头 |

**日志实证（L1/L2 关系）**：
```
I/AudioFlinger: openOutput() … module 18 Device AUDIO_DEVICE_OUT_BLUETOOTH_A2DP, @:SUPPRESSED, SamplingRate 0,      Format 00000000, Channels 0,   flags 0
I/AudioFlinger: openOutput() … module 18 Device AUDIO_DEVICE_OUT_BLUETOOTH_A2DP, @:SUPPRESSED, SamplingRate 96000,  Format 0x000006, Channels 0x3, flags 0
```
（`artifacts/logs/lhdc_param.log:80284 / 80385`，`lhdc_96k_run.log:99354 / 99444`）
→ 第一次空配置打开、第二次带 96000 重开：正是 `openOutputWithProfileAndDevice()` 里
`else if (profile->hasDynamicAudioProfile() && halConfig == nullptr) { desc->close(); … profile->pickAudioProfile(…) }` 这条分支。
**96000 不是从 XML 读出来的，是 HAL 报出来的。**

> 对 R3 的修正建议：R3 §8.1 把「音频策略 samplingRates 上限 96000」列为闸门①。本次证据表明，
> 在**软件编码通路**上它是**回退值/声明值**，不是生效的钳制点；真正会挡住 192 kHz 的是 L3（session 库掩码）
> 与 L2'（HAL 只上报协商值，APM 不会凭空放宽）。若真要跑 192 kHz，改 XML 是**必要但不充分**的，
> 且必须先过 L3。

### 6.4 其他 XML 影响面

- `encodedFormats`（`AUDIO_FORMAT_LHDC` 等）只影响 **offload** 路径的 `desc->devicesSupportEncodedFormats()` 判定与 `AUDIO_FORMAT_LHDC` 的路由，不影响 SW 路径（本机 SW 路径全程 `flags 0`）。
- `<module name="bluetooth">` 的存在决定 AudioFlinger 会不会 `loadHwModule("bluetooth")`；本机实测已加载（handle 18）。
- primary module 里也有一条 `BT A2DP Out ← primary output,deep_buffer,fast,compress_offload` 的 route：因为对应输出已为扬声器打开，APM 的「已打开则跳过」逻辑使其不会重复打开（推断，未逐步日志验证）。

---

## 7. (f) 本设备映射速查表（xaga）

| 项 | 值 | 来源 |
|---|---|---|
| 音频 HAL 服务进程 | pid 1006 `/vendor/bin/hw/android.hardware.audio.service.mediatek`，域 `u:r:mtk_hal_audio:s0` | `ps -A -Z` |
| BT audio provider（HIDL，AOSP 名） | `android.hardware.bluetooth.audio@2.0/@2.1::IBluetoothAudioProvidersFactory/default` | `lshal` |
| BT audio provider（HIDL，MTK 名） | `vendor.mediatek.hardware.bluetooth.audio@2.1/@2.2::IBluetoothAudioProvidersFactory/default` | `lshal` |
| BT audio provider（AIDL） | **不存在** | `lshal` 无 AIDL 段；`service list` 无；`manifest.xml` `format="aidl"` 计数 0 |
| HIDL 实现库 | `/vendor/lib64/hw/{android.hardware.bluetooth.audio@2.0-impl.so, @2.1-impl.so, vendor.mediatek.hardware.bluetooth.audio@2.1-impl.so, @2.2-impl.so}` | maps + `ls` |
| BT audio HAL module | `/vendor/lib64/hw/audio.bluetooth.default.so`，`DT_NEEDED` 只有 MTK HIDL 2.1/2.2 + `libbluetooth_audio_session_mediatek.so` + `libfmq` 等（**无任何 AIDL 依赖**） | pyelftools 实测 |
| 会话库 | `/vendor/lib64/libbluetooth_audio_session.so`、`/vendor/lib64/libbluetooth_audio_session_mediatek.so` | maps |
| **AIDL 会话库 `libbluetooth_audio_session_aidl.so`** | **全机不存在**（APEX 与 /vendor 都无） | `ls /apex/com.android.btservices/lib64/`、`ls /vendor/lib64/` |
| APEX 内的接口库 | `android.hardware.bluetooth.audio-V3-ndk.so`、`vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`、`libfmq.so`、`android.hardware.common.fmq-V1-ndk.so` | `ls` |
| VINTF manifest（device） | `/vendor/etc/vintf/manifest.xml`：`android.hardware.bluetooth.audio@2.1`（L71-78）、`vendor.mediatek.hardware.bluetooth.audio@2.2`（L334-341）；**无 `format="aidl"`** | grep |
| VINTF fragment 目录 | `/vendor/etc/vintf/manifest/`（存在）；`/vendor/etc/vintf/compatibility_matrix.xml`（DCM） | `ls` |
| FCM 中 MTK AIDL 条目 | `/system/etc/vintf/compatibility_matrix.device.xml:474-480`：`<hal format="aidl" optional="true"><name>vendor.mediatek.hardware.bluetooth.audio</name><interface><name>IBluetoothAudioProviderFactory</name><instance>default</instance>` | grep |
| hwservice_contexts | 平台：AOSP 名 → `hal_audio_hwservice`；vendor：MTK 名 → `mtk_hal_bluetooth_audio_hwservice` | grep |
| service_contexts | 平台：AOSP AIDL 名 → `hal_audio_service`；**vendor 无 MTK AIDL 条目** | grep |
| 策略文件 | `/system/etc/selinux/plat_sepolicy.cil`（2,131,648 B）、`/vendor/etc/selinux/vendor_sepolicy.cil`（1,178,058 B） | 已拉取本地副本 |
| 音频策略 | `/vendor/etc/audio_policy_configuration.xml` + `bluetooth_offload_audio_policy_configuration.xml` + `a2dp_in_audio_policy_configuration.xml` | 只读 grep |
| 相关属性 | `persist.bluetooth.a2dp_offload.cap=sbc-aac`、`persist.bluetooth.bluetooth_audio_hal.disabled`（未设置） | getprop |

---

## 8. (g) 「不新增服务」的替代做法 + 路线可行性矩阵

### 8.1 候选做法

| 方案 | 内容 | 可行性 | 风险 / 收益 |
|---|---|---|---|
| **G1. 现状：栈内内存补丁**（P0/P1/P2） | GOT 重定向 `osi_property_get` / `getCodecConfig` + `.rodata` 跳转表 | **已实现** | 收益：96 kHz 实测通过。风险：依赖 APEX 版本（偏移失配即放弃）；`codec_type` 在栈内被改写为 10（对 HAL 不可见） |
| **G2. 在 pid 1006 内 hook 厂商 HAL 的 `setCodecConfig`/`startSession`** | ptrace/LD_PRELOAD 注入音频 HAL 服务，改写 `AudioConfiguration` | 技术可行（进程与 init 同 mount namespace，root 可注入） | **收益 = 0**：SW 通路下 HAL 不读 codec（§4.4）。若想「让 HAL 知道 V5」，HIDL 结构体根本没有 V5 字段，hook 无从下手 |
| **G3. 替换 `audio.bluetooth.default.so` / provider 为 AIDL 版** | 编译 AOSP `audio_bluetooth_hw`（AIDL）+ `libbluetooth_audio_session_aidl` + AIDL provider，bind-mount 覆盖 | 可行但工作量大 | 需要：① 自带 `libbluetooth_audio_session_aidl.so`（本机无）；② 新 AIDL 服务注册（VINTF + service_contexts）；③ 让栈选 AIDL（`isDeclared` 必须为真）。**收益**：栈侧可原生走 `A2dpLhdcv5ToHalConfig`；**但 SW 通路下 HAL 仍只收 PCM** |
| **G4. 新增 HIDL 服务（自带 V5 结构）** | 新写 `.hal` + 新版本号 + 新 impl | **第三方不可行** | 需要厂商出接口定义；且栈侧 `a2dp_encoding_hidl.cc` 无 V5 分支，仍要打补丁 |
| **G5. 让 `libbluetooth_jni.so` 原生走 V5（HIDL 版转换函数）** | 用模块自己实现 V5→HIDL 转换并 hook 分发器 | 可行（等价于 P1+P2 的更干净版本） | 结果字节与现状**完全相同**（HIDL `LhdcParameters` 无版本字段）→ 无收益 |
| **G6. 强制 offload 通路承载 LHDC** | 改 `persist.bluetooth.a2dp_offload.cap` + XML `encodedFormats` | 不适用 | 本机 DSP 无 LHDC（调查报告：`audio_dsp.img` LHDC 字符串 0）；且 offload 需要 DSP 编码器 |

### 8.2 若坚持走 AIDL（G3）的完整前置条件清单

1. **新服务进程或宿主进程**：AIDL provider 是 shared lib（`android.hardware.bluetooth.audio-impl`），需要宿主调用 `createIBluetoothAudioProviderFactory()`。最省事的宿主就是现有 pid 1006（`mtk_hal_audio`），但需要注入/替换其启动方式。
2. **服务名二选一**：
   - AOSP 名 → SELinux 放行（`hal_audio_service`），栈侧 `hal_version_ = 4`（transport 4 → AOSP AIDL 实现）；
   - MTK 名 → **SELinux 直接拒**（`default_android_service` 无 add 规则），需策略补丁；换来 `hal_version_ = 3`（transport 2 → MTK AIDL 实现，含 V5 转换）。
3. **VINTF manifest**：`<hal format="aidl"><name>…</name><version>…</version><fqname>IBluetoothAudioProviderFactory/default</fqname></hal>` 必须进 device manifest（`AServiceManager_isDeclared` 依赖它）；FCM 侧 MTK 名已 `optional="true"` 存在，AOSP 名需查 FCM（本机 `compatibility_matrix.device.xml` 里 AOSP 名条目未在本次核对范围内 → **未验证**）。
4. **库**：`libbluetooth_audio_session_aidl.so`（AOSP `hardware/interfaces/bluetooth/audio/utils/Android.bp` 的 `libbluetooth_audio_session_aidl` 目标，`vendor: true`）必须自编译并放到 `/vendor/lib64`（bind-mount）。
5. **`audio.bluetooth.default.so` 也要换成 AIDL-aware 版**（AOSP 版同时链接 AIDL 与 HIDL，见 `r7/bt/audio_bluetooth_hw/Android.bp`；本机 MTK 版只链接 HIDL）——否则会话永远不 ready。
6. **策略补丁**（若走 MTK 名/新域）：KernelSU `sepolicy.rule`。
7. **verity/挂载**：`/vendor` 是 `erofs ro + dm-verity`（R3 §7.3），只能靠 KernelSU 的 overlay/bind-mount；pid 1006 与 init 同 mount namespace → post-fs-data 挂载对它可见（R3 已验证）。

**收益评估**：即便全部做完，**软件编码通路下 HAL 收到的字节与现状相同**；唯一变化是「栈内 codec_type 不再被改写成 10」。
而 V5 的 96 kHz 早已在现状下实测通过。→ **工程投入与收益严重不成比例。**

---

## 9. 管线地图（哪些是 /vendor 只读、哪些是 APEX、哪些可被 root 方案改写）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 应用 / AudioTrack                                            [APEX/app，可改]│
└───────────────┬─────────────────────────────────────────────────────────────┘
                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ audioserver (pid 1109)                                                       │
│   AudioFlinger / AudioPolicyManager        [/system/bin，只读]                │
│   配置源: /vendor/etc/audio_policy_configuration.xml + xi:include  [只读]     │
│           ↑ 决定 module/devicePort/profile/route/encodedFormats               │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │ HIDL audio HAL 7.1（IDevicesFactory::openDevice("bluetooth")）
                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ android.hardware.audio.service.mediatek (pid 1006, u:r:mtk_hal_audio:s0)      │
│                                                                              │
│  ┌── /vendor/lib64/hw/audio.bluetooth.default.so ─────────────[只读, 可挂载] │
│  │     adev_open_output_stream → SetUp → IsSessionReady → LoadAudioConfig    │
│  └── /vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so    │
│  │     provider: startSession(hostIf, AudioConfiguration) → 建 FMQ           │
│  └── /vendor/lib64/libbluetooth_audio_session_mediatek.so  [只读, 可挂载]      │
│        ├─ IsSoftwarePcmConfigurationValid  ← ★采样率真闸门                    │
│        └─ 进程内会话单例（provider 与 module 必须同进程）                     │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │ hwbinder: startSession / startStream / suspendStream
                │ FMQ(共享内存): PCM 数据（audioserver→BT 栈）
                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ com.android.bluetooth (pid 2688, u:r:bluetooth:s0)                           │
│   /apex/com.android.btservices/lib64/libbluetooth_jni.so      [APEX, 只读]    │
│     ├─ HalVersionManager（探测顺序：MTK AIDL→MTK HIDL2.2→2.1→AIDL）          │
│     ├─ setup_codec(): SW→只发 pcmConfig / offload→才发 codecConfig            │
│     ├─ A2dpLhdcV3ToHalConfig（HIDL 族，V3 专用）                             │
│     ├─ A2dpLhdcv5ToHalConfig（AIDL 族，本机死代码）                           │
│     └─ createCodec 白名单（corot/duchamp/zircon/rothko/malachite）           │
│   /apex/com.android.btservices/lib64/{liblhdc.so,liblhdcv5.so,...}  [APEX]    │
└─────────────────────────────────────────────────────────────────────────────┘
                │ L2CAP → 耳机（RF 层与 codec 无关）
                ▼

可被 root 方案改写的层（按侵入性递增）：
 ① 进程内内存补丁（现状）：只改 com.android.bluetooth 的私有映射        ← 零挂载、零策略、零属性
 ② bind-mount /vendor 文件（pid 1006 与 init 同 mnt ns，post-fs-data 可见）
 ③ sepolicy 补丁（KernelSU sepolicy.rule）→ 唯一能放行「新服务名/新域」的手段
 ④ 新 VINTF manifest 条目（可挂载覆盖 /vendor/etc/vintf/manifest.xml 或 manifest/ 目录）
 ⑤ 新进程/新 init 服务（需 ②③④ 全部齐备）
```

---

## 10. 证据 / 推断 / 未知 分级

### 10.1 已验证（命令或源码原文可复现）

- HIDL 服务名格式、四个 BT audio HIDL 服务的注册进程（`lshal`）。
- `registerAsServiceInternal` 的 manifest 硬要求 + `kEnforceVintfManifest=true` 的二进制取证（`libhidlbase.so` 字符串）。
- `ServiceManager::get` 的 `canGet` → `lookup` → `tryStartService` 三步失败条件（源码原文）。
- `AccessControl::canAdd` 走 `hwservice_contexts` + `selabel_lookup`（源码原文）。
- 本机 hwservice/service_contexts 内容、CIL allow 规则（`grep` 原文）。
- pid 1006 同时映射 BT audio provider impl 与 `audio.bluetooth.default.so`（`/proc/1006/maps`）。
- AudioFlinger `loadHwModule() Loaded bluetooth audio interface, handle 18`（日志）。
- AOSP `setup_codec()` SW 分支只发 pcmConfig（源码原文）。
- `adev_open_output_stream` 的 `SetUp()` 失败 → `-EINVAL`；`AudioHwDevice::openOutputStream` 日志格式（源码原文 + 设备日志逐字吻合）。
- `LoadAudioConfig` 无采样率钳制、`out_get_parameters` 返回会话值（源码原文 + 日志 `SamplingRate 0 → 96000`）。
- `libbluetooth_audio_session_aidl.so` 本机不存在（`ls`）。
- `audio.bluetooth.default.so` 的 `DT_NEEDED` 只有 HIDL（pyelftools）。
- AIDL factory 只有 2 个方法，且 A14 与 main 无差异（`diff` 空）。

### 10.2 推断（证据支持但非直接观测）

- 「AIDL 音频 HAL 的 `IModule/a2dp`/`IModule/bluetooth` 承载 BT 音频/SCO 模块」：依据是 `plat_service_contexts` 的三条条目 + `r7/audio/aidldefault/Bluetooth.cpp`（SCO 语义）。本机不用 AIDL 音频 HAL，未实测。
- 「primary module 的 A2DP route 因输出已打开而被跳过」：依据 APM 源码「已打开同 profile 则跳过」逻辑，未逐步日志验证。
- 「用 AOSP 名注册 AIDL 服务可过 SELinux」：依据 CIL 规则组合推导，未实测（本任务只读）。
- 「`hal_version_=4` 时栈走 AOSP AIDL 实现」：R2 §2.3 的 `GetHalTransport` 位掩码查表结论，本次未复核。

### 10.3 未知 / 未验证

- AOSP 名 `android.hardware.bluetooth.audio` 的 AIDL 条目是否在本机 FCM（`compatibility_matrix.device.xml`）里（只核对了 MTK 名条目）。
- `/vendor/etc/vintf/manifest/` 目录下的 fragment 清单（只列了目录，未逐个 grep）。
- 本机 `mtk_hal_audio` 是否有 `binder call` 到 `bluetooth` 域的反向规则（未查；按需查）。
- A14 QPR3 版 `HalVersionManager` 的 `getInterfaceVersion` 在 MTK fork 里是否也被采用（本机为 A14 release 基线，未验证）。
- 若强行让协商到 192 kHz，APM 会选什么速率（`pickAudioProfile` 的具体回退值未实测）。

---

## 11. 对既有结论的核对与修正

| 既有说法 | 本次复核 |
|---|---|
| MAIN-findings §3：SW 模式 HAL 收不到 codecConfig | ✅ **成立**，AOSP 源码 `setup_codec()` 原文逐字支持 |
| MAIN-findings §4：厂商 BT audio provider 与 audioserver 同进程 | ⚠️ **表述需修正**：provider 与**音频 HAL 服务（pid 1006）**同进程，不是与 audioserver（pid 1109）同进程；audioserver 只是 client。`audio.bluetooth.default.so` 也在 1006 而非 audioserver |
| R3 §7.1「软件通路下 HAL 侧零改动」 | ✅ 成立 |
| R3 §8.1 闸门①「音频策略 samplingRates 上限 96000」 | ⚠️ **需降级**：SW 通路上它是回退/声明值；生效的采样率由 HAL 上报（会话 PCM 配置）决定（见 §6.3） |
| R1 §(g)#7「服务端 SELinux 域允许 add（未验证）」 | ✅ **本次已验证**：HIDL `mtk_hal_bluetooth_audio_hwservice add` 在 `mtk_hal_audio`；AIDL `hal_audio_service add` 在 `hal_audio_server`（含 `mtk_hal_audio`） |
| 任务描述提到 `getSupportedProfiles` | ❌ **AOSP 14 与 main 都没有这个方法**；对应物是 `getProviderCapabilities(SessionType)` |
| 任务描述提到 `IBluetoothAudioHost::streamOut` | ❌ **HIDL 2.0 起就不存在**；PCM 走 FMQ |

---

## 12. 落盘文件清单（本文引用的本地副本）

```
d:/Cache/Hyperos/lhdcv5-tr/reference/aosp-src/r7/
├─ hwservicemanager/{ServiceManager.cpp,AccessControl.cpp,Vintf.cpp,service.cpp,hwservicemanager.xml,.rc}
├─ libhidl/{ServiceManagement.cpp,HidlLazyUtils.cpp,HidlTransportSupport.h,IServiceManager.hal,IServiceManager12.hal}
├─ svcmgr/{Access.cpp,ServiceManager.cpp,ndk_service_manager.cpp}
├─ hwif/2.0/{IBluetoothAudioProvider.hal,IBluetoothAudioProvidersFactory.hal,types.hal,Android.bp}
├─ hwif/2.0default/{Android.bp,BluetoothAudioProvidersFactory.cpp,A2dpSoftwareAudioProvider.cpp,BluetoothAudioProvider.cpp}
├─ hwif/2.1/{IBluetoothAudioProvider.hal,IBluetoothAudioProvidersFactory.hal,Android.bp}
├─ hwif/aidl/{IBluetoothAudioProviderFactory.aidl,IBluetoothAudioProvider.aidl,IBluetoothAudioPort.aidl,SessionType.aidl,CodecType.aidl,AudioConfiguration.aidl,LatencyMode.aidl,Android.bp}
├─ hwif/aidl_main/IBluetoothAudioProviderFactory.aidl      ← main 分支对照（diff 为空）
├─ hwif/aidldefault/{Android.bp,service.cpp,BluetoothAudioProviderFactory.cpp,A2dpSoftwareAudioProvider.cpp}
├─ hwif/utils/Android.bp                                    ← libbluetooth_audio_session[_aidl] 目标定义
├─ bt/audio_bluetooth_hw/{Android.bp,audio_bluetooth_hw.cc,device_port_proxy.cc,device_port_proxy.hidl.cc,stream_apis.cc,utils.cc}
├─ bt/audio_a2dp_hw/Android.bp
├─ bt/audio_hal_interface/{Android.bp,a2dp_encoding.h,aidl/*,hidl/*}
├─ sepolicy/{bluetooth.te,bluetoothdomain.te,public_hal_audio.te,public_hal_bluetooth.te,hwservice_contexts,service_contexts,audioserver.te,file_contexts}
├─ audiopolicy/{audio_policy_configuration.xml,bluetooth_audio_policy_configuration.xml,a2dp_audio_policy_configuration.xml,AudioPolicyManager.cpp,AudioOutputDescriptor.cpp,IOProfile.cpp}
├─ audioflinger/{AudioFlinger.cpp,AudioHwDevice.cpp}
├─ audio/7.1/{IDevicesFactory.hal,types.hal}, audio/aidl/IModule.aidl, audio/aidldefault/{Android.bp,Bluetooth.cpp,Module.cpp}
└─ libhardware/audio.h

d:/Cache/Hyperos/lhdcv5-tr/analysis/raw/
├─ r7_plat_sepolicy.cil       (2,131,648 B)   ← 设备 /system/etc/selinux/plat_sepolicy.cil
└─ r7_vendor_sepolicy.cil     (1,178,058 B)   ← 设备 /vendor/etc/selinux/vendor_sepolicy.cil

脚本：d:/Cache/Hyperos/lhdcv5-tr/analysis/scripts/{r7_fetch.py,r7_fetch2.py,r7_tree.py}
```

---

## 13. 一句话回答任务问题

**Android 14 上「新增/替换一个蓝牙音频 HAL 实现」不是"加一个 .so"那么简单**：HIDL 要求 VINTF manifest 声明 + `hwservice_contexts` 条目 + `hwservice_manager add` 权限；AIDL 要求 `service_contexts` 条目（服务名决定）+ `service_manager add` 权限 + `isDeclared` 可见的 manifest 条目；两者都要与**音频 HAL 服务同进程**才能让进程内会话单例/FMQ 工作。
**本机（xaga）的硬缺口依次是**：① `libbluetooth_audio_session_aidl.so` 不存在；② MTK AIDL 服务名无 service_contexts 条目（SELinux 会拒注册）；③ `audio.bluetooth.default.so` 是 HIDL-only；④ 厂商 HIDL 接口无 V5 结构。
而**这四条全都无法带来实际收益** —— 因为软件编码通路下 HAL 只消费 PCM，V5 与 V3 送到 HAL 的字节完全相同。**结论：现有「V5 伪装 V3」的内存补丁方案已经是该设备上最优解；"真 V5 通路"是伪需求。**
