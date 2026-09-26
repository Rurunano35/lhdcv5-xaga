// lhdcv5_shimsym.cpp — 补齐 xaga 的 libhidlbase 缺失符号
//
// MediaTek 的 AOSP-AIDL 蓝牙音频实现（malachite 版）是用比 xaga 更新的
// libhidlbase 构建的，导入了 xaga 版本里不存在的：
//     android::hardware::details::check(bool, char const*)
// 该符号被 android.hardware.bluetooth.audio-impl.so 及两个 session 库导入。
//
// xaga 的 libhidlbase.so 无法替换（同 SONAME 已被音频 HAL 服务加载，链接器会去重），
// 所以用一个独立 SONAME 的 stub 提供该符号，由 shim 以 RTLD_GLOBAL 预加载 ——
// 之后 dlopen AIDL 实现时，链接器会在全局作用域里找到它。
//
// 语义：原函数是断言辅助。为保证安全，这里只记录不中止（若断言失败会在日志中可见、
// 便于诊断，而不会把音频 HAL 服务直接打死）。

#include <android/log.h>
#include <cstddef>

namespace android {
namespace hardware {
namespace details {

void check(bool cond, const char* msg) {
  if (!cond) {
    __android_log_print(ANDROID_LOG_ERROR, "LHDCV5SYM",
                        "hidlbase details::check FAILED: %s",
                        msg != nullptr ? msg : "(null)");
  }
}

}  // namespace details
}  // namespace hardware
}  // namespace android
