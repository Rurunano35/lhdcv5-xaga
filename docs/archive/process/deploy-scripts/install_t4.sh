#!/system/bin/sh
# 安装测试模块 4
rm -rf /data/adb/modules/lhdcv5-t4 /data/local/tmp/t4x
mkdir -p /data/local/tmp/t4x
cd /data/local/tmp/t4x
tar -xzf /data/local/tmp/lhdcv5-t4.tar.gz
cp -a lhdcv5-t4 /data/adb/modules/
chmod 0755 /data/adb/modules/lhdcv5-t4/post-fs-data.sh
chmod 0644 /data/adb/modules/lhdcv5-t4/payload/*.so
rm -f /data/adb/modules/lhdcv5-t4/disable
# 确保其它模块全部禁用
for m in lhdcv5 lhdcv5-aidl lhdcv5-t1 lhdcv5-t3; do
  [ -d /data/adb/modules/$m ] && touch /data/adb/modules/$m/disable
done
echo "=== 状态 ==="
for m in lhdcv5 lhdcv5-aidl lhdcv5-t1 lhdcv5-t3 lhdcv5-t4; do
  [ -d /data/adb/modules/$m ] || continue
  if [ -f /data/adb/modules/$m/disable ]; then echo "  $m: DISABLED"; else echo "  $m: ENABLED"; fi
done
echo "=== t4 payload ==="
ls /data/adb/modules/lhdcv5-t4/payload/ | wc -l
