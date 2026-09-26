#!/system/bin/sh
# 安装生产模块 lhdcv5-aidl（v2.0）
rm -rf /data/adb/modules/lhdcv5-aidl /data/local/tmp/aidx
mkdir -p /data/local/tmp/aidx
cd /data/local/tmp/aidx
tar -xzf /data/local/tmp/lhdcv5-aidl.tar.gz
cp -a lhdcv5-aidl /data/adb/modules/
chmod 0755 /data/adb/modules/lhdcv5-aidl/post-fs-data.sh
chmod 0644 /data/adb/modules/lhdcv5-aidl/payload/*
rm -f /data/adb/modules/lhdcv5-aidl/disable

# 禁用所有测试模块
for m in lhdcv5-t1 lhdcv5-t3 lhdcv5-t4 lhdcv5-t5; do
  [ -d /data/adb/modules/$m ] && touch /data/adb/modules/$m/disable
done
# 启用 P0 白名单准入
[ -d /data/adb/modules/lhdcv5 ] && rm -f /data/adb/modules/lhdcv5/disable

echo "=== 模块状态 ==="
for m in lhdcv5 lhdcv5-aidl lhdcv5-t1 lhdcv5-t3 lhdcv5-t4 lhdcv5-t5; do
  [ -d /data/adb/modules/$m ] || continue
  if [ -f /data/adb/modules/$m/disable ]; then echo "  $m: DISABLED"; else echo "  $m: ENABLED"; fi
done
echo "payload: $(ls /data/adb/modules/lhdcv5-aidl/payload/ | wc -l) 个文件"
