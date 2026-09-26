#!/system/bin/sh
# 安装最终版 t5 + 启用 P0 白名单绕过模块
rm -rf /data/adb/modules/lhdcv5-t5 /data/local/tmp/t5x
mkdir -p /data/local/tmp/t5x
cd /data/local/tmp/t5x
tar -xzf /data/local/tmp/lhdcv5-t5.tar.gz
cp -a lhdcv5-t5 /data/adb/modules/
chmod 0755 /data/adb/modules/lhdcv5-t5/post-fs-data.sh
chmod 0644 /data/adb/modules/lhdcv5-t5/payload/*
rm -f /data/adb/modules/lhdcv5-t5/disable

# 禁用所有测试模块
for m in lhdcv5-aidl lhdcv5-t1 lhdcv5-t3 lhdcv5-t4; do
  [ -d /data/adb/modules/$m ] && touch /data/adb/modules/$m/disable
done

# 启用 P0 白名单绕过（原有模块）
if [ -d /data/adb/modules/lhdcv5 ]; then
  rm -f /data/adb/modules/lhdcv5/disable
fi

echo "=== 模块状态 ==="
for m in lhdcv5 lhdcv5-aidl lhdcv5-t1 lhdcv5-t3 lhdcv5-t4 lhdcv5-t5; do
  [ -d /data/adb/modules/$m ] || continue
  if [ -f /data/adb/modules/$m/disable ]; then echo "  $m: DISABLED"; else echo "  $m: ENABLED"; fi
done
echo "t5 payload: $(ls /data/adb/modules/lhdcv5-t5/payload/ | wc -l) 个文件"
