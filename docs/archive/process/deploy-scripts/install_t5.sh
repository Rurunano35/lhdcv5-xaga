#!/system/bin/sh
# 安装测试模块 5
rm -rf /data/adb/modules/lhdcv5-t5 /data/local/tmp/t5x
mkdir -p /data/local/tmp/t5x
cd /data/local/tmp/t5x
tar -xzf /data/local/tmp/lhdcv5-t5.tar.gz
cp -a lhdcv5-t5 /data/adb/modules/
chmod 0755 /data/adb/modules/lhdcv5-t5/post-fs-data.sh
chmod 0644 /data/adb/modules/lhdcv5-t5/payload/*
rm -f /data/adb/modules/lhdcv5-t5/disable
for m in lhdcv5 lhdcv5-aidl lhdcv5-t1 lhdcv5-t3 lhdcv5-t4; do
  [ -d /data/adb/modules/$m ] && touch /data/adb/modules/$m/disable
done
echo "=== 模块状态 ==="
for m in lhdcv5 lhdcv5-aidl lhdcv5-t1 lhdcv5-t3 lhdcv5-t4 lhdcv5-t5; do
  [ -d /data/adb/modules/$m ] || continue
  if [ -f /data/adb/modules/$m/disable ]; then echo "  $m: DISABLED"; else echo "  $m: ENABLED"; fi
done
echo "payload 文件数: $(ls /data/adb/modules/lhdcv5-t5/payload/ | wc -l)"
