#!/bin/sh
# 构建两个 shim 库：
#   vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so  顶替 MTK HIDL 2.2 实现
#   lhdcv5_shimsym.so                                    补齐 libhidlbase 缺失符号
set -e

NDK="${NDK:-/d/Cache/Hyperos/ndk/android-ndk-r27d}"
TC="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
API="${API:-24}"

CXX="$TC/aarch64-linux-android${API}-clang++"
READELF="$TC/llvm-readelf"
NM="$TC/llvm-nm"

[ -x "$CXX" ] || { echo "error: 找不到 $CXX（可用 NDK= 指定 NDK 路径）" >&2; exit 1; }

SONAME='vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so'

echo "=== 1) 符号补齐库 ==="
# 默认可见性：符号必须导出
"$CXX" -shared -fPIC -O2 -std=c++17 -static-libstdc++ \
       -Wl,-soname,lhdcv5_shimsym.so \
       -o lhdcv5_shimsym.so lhdcv5_shimsym.cpp -llog
"$NM" -D --defined-only lhdcv5_shimsym.so | grep details5check \
  || { echo "error: 补齐库未导出目标符号" >&2; exit 1; }

echo
echo "=== 2) shim 库 ==="
# -fvisibility=hidden 会隐藏 HIDL_FETCH_*，源码里已对该符号显式 visibility("default")
"$CXX" -shared -fPIC -O2 -std=c++17 -fvisibility=hidden -static-libstdc++ \
       -Wl,-soname,"$SONAME" -Wall -Wextra \
       -o "$SONAME" lhdcv5_shim.cpp -llog -ldl
"$NM" -D --defined-only "$SONAME" | grep HIDL_FETCH \
  || { echo "error: shim 未导出 HIDL_FETCH_IBluetoothAudioProvidersFactory" >&2; exit 1; }

echo
echo "=== 依赖（均不得含 libc++_shared.so）==="
for f in lhdcv5_shimsym.so "$SONAME"; do
  echo "--- $f"
  "$READELF" -d "$f" | grep NEEDED
done

echo
echo "built:"
ls -la lhdcv5_shimsym.so "$SONAME"
