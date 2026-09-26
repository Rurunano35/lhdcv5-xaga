#!/system/bin/sh
# 安装测试模块 3
rm -rf /data/adb/modules/lhdcv5-t3 /data/local/tmp/t3x
mkdir -p /data/local/tmp/t3x
cd /data/local/tmp/t3x
tar -xzf /data/local/tmp/lhdcv5-t3.tar.gz
cp -a lhdcv5-t3 /data/adb/modules/
chmod 0755 /data/adb/modules/lhdcv5-t3/post-fs-data.sh
rm -f /data/adb/modules/lhdcv5-t3/disable
echo "=== lhdcv5 系模块状态 ==="
for m in lhdcv5 lhdcv5-aidl lhdcv5-t1 lhdcv5-t2 lhdcv5-t3; do
  if [ ! -d /data/adb/modules/$m ]; then continue; fi
  if [ -f /data/adb/modules/$m/disable ]; then echo "  $m: DISABLED"; else echo "  $m: ENABLED"; fi
done
echo "=== t3 脚本 ==="
ls -la /data/adb/modules/lhdcv5-t3/
