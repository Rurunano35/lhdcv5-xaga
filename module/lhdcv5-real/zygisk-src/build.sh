#!/bin/sh
# 构建 Zygisk 模块（G1 机型白名单绕过）→ ../zygisk/arm64-v8a.so
#
# 注意两个已验证的坑：
#   1. 必须 -static-libstdc++：依赖 libc++_shared.so 会导致模块加载失败且无任何日志
#   2. api.hpp 用到 dev_t/ino_t，须先于它引入 <sys/types.h> 等系统头（已在 module.cpp 中处理）
set -e

NDK="${NDK:-/d/Cache/Hyperos/ndk/android-ndk-r27d}"
TC="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
API="${API:-24}"

CXX="$TC/aarch64-linux-android${API}-clang++"
STRIP="$TC/llvm-strip"
NM="$TC/llvm-nm"
READELF="$TC/llvm-readelf"

[ -x "$CXX" ] || { echo "error: 找不到 $CXX（可用 NDK= 指定 NDK 路径）" >&2; exit 1; }

echo "using: $CXX"
"$CXX" -shared -fPIC -O2 -std=c++17 -fvisibility=hidden -static-libstdc++ \
       -Wall -Wextra -o arm64-v8a.so module.cpp -llog

"$STRIP" --strip-unneeded arm64-v8a.so 2>/dev/null || true
mkdir -p ../zygisk
cp -f arm64-v8a.so ../zygisk/arm64-v8a.so

echo
echo "=== 依赖（必须不含 libc++_shared.so）==="
"$READELF" -d arm64-v8a.so | grep NEEDED

echo
echo "=== 必须导出 zygisk_module_entry ==="
"$NM" -D --defined-only arm64-v8a.so | grep zygisk_module_entry

echo
echo "built: $(pwd)/../zygisk/arm64-v8a.so"
ls -la ../zygisk/arm64-v8a.so
