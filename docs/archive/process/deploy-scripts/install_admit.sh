#!/system/bin/sh
# 安装独立的准入模块 lhdcv5-admit，并停用旧的伪装模块 lhdcv5
rm -rf /data/adb/modules/lhdcv5-admit /data/local/tmp/admx
mkdir -p /data/local/tmp/admx
cd /data/local/tmp/admx
tar -xzf /data/local/tmp/lhdcv5-admit.tar.gz
cp -a lhdcv5-admit /data/adb/modules/
chmod 0755 /data/adb/modules/lhdcv5-admit
chmod 0644 /data/adb/modules/lhdcv5-admit/module.prop
chmod 0644 /data/adb/modules/lhdcv5-admit/zygisk/arm64-v8a.so
rm -f /data/adb/modules/lhdcv5-admit/disable

# 停用旧的伪装模块（P1/P2 属于 HIDL 伪装时期，V5 通路已不需要）
if [ -d /data/adb/modules/lhdcv5 ]; then
  touch /data/adb/modules/lhdcv5/disable
fi

echo "=== 模块状态 ==="
for m in lhdcv5 lhdcv5-admit lhdcv5-aidl lhdcv5-t1 lhdcv5-t3 lhdcv5-t4 lhdcv5-t5; do
  [ -d /data/adb/modules/$m ] || continue
  if [ -f /data/adb/modules/$m/disable ]; then echo "  $m: DISABLED"; else echo "  $m: ENABLED"; fi
done
echo "=== admit 内容 ==="
find /data/adb/modules/lhdcv5-admit -type f -printf "%9s  %P\n" | sort -k2
