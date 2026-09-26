#!/system/bin/sh
# 安装测试模块 1
set -e
rm -rf /data/adb/modules/lhdcv5-t1
rm -rf /data/local/tmp/t1x
mkdir -p /data/local/tmp/t1x
cd /data/local/tmp/t1x
tar -xzf /data/local/tmp/lhdcv5-t1.tar.gz
cp -a lhdcv5-t1 /data/adb/modules/
chmod 0755 /data/adb/modules/lhdcv5-t1/post-fs-data.sh
rm -f /data/adb/modules/lhdcv5-t1/disable
echo "=== 已安装模块 ==="
ls /data/adb/modules/ | grep lhdcv5
echo "=== t1 内容 ==="
ls -la /data/adb/modules/lhdcv5-t1/
echo "=== 各 lhdcv5 模块的 disable 状态 ==="
for m in lhdcv5 lhdcv5-aidl lhdcv5-t1; do
  if [ -f /data/adb/modules/$m/disable ]; then echo "  $m: DISABLED"; else echo "  $m: ENABLED"; fi
done
