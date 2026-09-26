// LHDC V5 AIDL 点亮的 shim
//
// 替换 /vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so
//
// 原理：HIDL 的 registerPassthroughServiceImplementation 会 dlopen 这个文件并
// 查找 HIDL_FETCH_IBluetoothAudioProvidersFactory。音频 HAL 服务（PID 1006 /
// mtk_hal_audio 域）在启动时会做这件事 —— 本 shim 借这个时机：
//   1) dlopen 真正的 HIDL 实现并转发 FETCH，保证 HIDL 通路不回归；
//   2) dlopen MediaTek 的 AOSP-AIDL 实现 —— 它靠静态构造函数自注册为
//      android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default，
//      从而让蓝牙协议栈切到 AIDL 通路（进而解锁 192 kHz）。
//
// 之所以需要 shim：本机 SELinux 禁止 init exec 任何 bind-mount 回来的可执行文件
// （execute_no_trans denied），所以无法直接替换服务二进制；但 dlopen 一个库只需要
// read+mmap，bind-mount 的库可以正常加载。

#include <android/log.h>
#include <dlfcn.h>
#include <cstddef>
#include <cstdint>

// 最小 ABI 声明：NDK 稳定接口 AServiceManager_addService
// 不直接链接 libbinder_ndk —— 改用 dlsym(RTLD_DEFAULT) 解析，
// 因为加载 AIDL 实现时它已把 libbinder_ndk 带进进程（RTLD_GLOBAL）。
struct AIBinder;
typedef int32_t binder_status_t;
typedef binder_status_t (*AddServiceFn)(AIBinder*, const char*);

#define LOG_TAG "LHDCV5SHIM"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

const char* kRealHidl = "/data/vendor/lhdcv5/real_hidl22.so";
const char* kAidlImpl = "/data/vendor/lhdcv5/android.hardware.bluetooth.audio-impl.so";
const char* kSymFill = "/data/vendor/lhdcv5/lhdcv5_shimsym.so";
const char* kFetchSym = "HIDL_FETCH_IBluetoothAudioProvidersFactory";
const char* kCreateSym = "createIBluetoothAudioProviderFactory";
const char* kAidlSvcName =
    "android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default";

using FetchFn = void* (*)(const char*);
using CreateFn = void* (*)();

void* LoadRealHidl() {
  void* h = dlopen(kRealHidl, RTLD_NOW | RTLD_LOCAL);
  if (h == nullptr) {
    LOGE("real HIDL impl open failed: %s", dlerror());
  }
  return h;
}

// 点亮 AIDL：加载符号补齐 → 加载实现 → 创建 factory →（实现内部自注册）
// createIBluetoothAudioProviderFactory 返回 ndk::SpAIBinder（trivial_abi，单指针，x0 返回）
void BringUpAidl() {
  // 先补符号：malachite 的实现依赖比 xaga 更新的 libhidlbase，
  // 缺失的 android::hardware::details::check 由这个独立 SONAME 的 stub 以
  // RTLD_GLOBAL 提供，供随后 dlopen 的实现解析。
  void* symfill = dlopen(kSymFill, RTLD_NOW | RTLD_GLOBAL);
  if (symfill != nullptr) {
    LOGI("symbol filler loaded at %p", symfill);
    // 自检：该符号是否已进入可被后续 dlopen 解析的全局作用域
    void* probe = dlsym(RTLD_DEFAULT, "_ZN7android8hardware7details5checkEbPKc");
    LOGI("global lookup probe -> %p", probe);
    void* probe2 = dlsym(symfill, "_ZN7android8hardware7details5checkEbPKc");
    LOGI("handle lookup probe -> %p", probe2);
  } else {
    LOGE("symbol filler FAILED: %s", dlerror());
  }

  // RTLD_LAZY：函数符号延迟到调用时解析 —— 那时 bionic 会做完整查找
  // （含全局作用域），从而能找到上面预加载的补齐库提供的符号。
  // 用 RTLD_NOW 时 bionic 只在该库的 DT_NEEDED 闭包内重定位，会失败。
  void* impl = dlopen(kAidlImpl, RTLD_LAZY | RTLD_GLOBAL);
  if (impl == nullptr) {
    LOGE("AIDL impl load FAILED: %s", dlerror());
    return;
  }
  LOGI("AIDL impl loaded at %p", impl);

  auto create = reinterpret_cast<CreateFn>(dlsym(impl, kCreateSym));
  if (create == nullptr) {
    LOGE("create symbol missing: %s", dlerror());
    return;
  }
  AIBinder* factory = static_cast<AIBinder*>(create());
  if (factory == nullptr) {
    LOGE("create returned null");
    return;
  }
  LOGI("factory created at %p", factory);

  auto add_service =
      reinterpret_cast<AddServiceFn>(dlsym(RTLD_DEFAULT, "AServiceManager_addService"));
  if (add_service == nullptr) {
    LOGE("AServiceManager_addService not resolvable: %s", dlerror());
    return;
  }
  binder_status_t st = add_service(factory, kAidlSvcName);
  LOGI("addService(%s) -> %d", kAidlSvcName, static_cast<int>(st));
}

// shim 自身被 dlopen 时触发
__attribute__((constructor)) void ShimInit() {
  LOGI("shim ctor: start");
  BringUpAidl();
  void* real = LoadRealHidl();
  LOGI("real HIDL impl preload %s", real != nullptr ? "ok" : "FAILED");
  LOGI("shim ctor: done");
}

}  // namespace

extern "C" __attribute__((visibility("default"))) void*
HIDL_FETCH_IBluetoothAudioProvidersFactory(const char* name) {
  void* real = LoadRealHidl();
  if (real == nullptr) {
    return nullptr;
  }
  auto fn = reinterpret_cast<FetchFn>(dlsym(real, kFetchSym));
  if (fn == nullptr) {
    LOGE("fetch symbol missing: %s", dlerror());
    return nullptr;
  }
  void* instance = fn(name);
  LOGI("fetch forwarded (name=%s) -> %p", name != nullptr ? name : "(null)", instance);
  return instance;
}
