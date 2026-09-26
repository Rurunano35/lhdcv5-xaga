#!/system/bin/sh
# LHDC V5 AIDL 移植 - 阶段3：替换音频 HAL 服务二进制 + VINTF 声明
P=/data/local/tmp/p
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek

echo "=== 1) 挂载 VINTF 声明（含 AIDL 条目）==="
mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml \
  && echo "  MOUNTED manifest.xml" || echo "  FAIL manifest.xml"

echo "=== 2) 挂载新服务二进制（zircon）==="
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC \
  && echo "  MOUNTED service" || echo "  FAIL service"
sha256sum $SVC
chcon u:object_r:vendor_file:s0 $SVC 2>/dev/null

echo "=== 3) 重启 audio-hal ==="
setprop ctl.restart vendor.audio-hal
sleep 10

echo "=== 4) 结果 ==="
NP=$(pidof android.hardware.audio.service.mediatek)
echo "  PID = $NP"
if [ -n "$NP" ]; then
  echo "  --- 从 /data/local/tmp/p 加载的库 ---"
  grep "data/local/tmp/p" /proc/$NP/maps 2>/dev/null | awk '{print $6}' | sort -u
  echo "  --- 映射数 ---"
  wc -l < /proc/$NP/maps
else
  echo "  !! 服务未启动（回退中）"
  umount $SVC 2>/dev/null
  umount /vendor/etc/vintf/manifest.xml 2>/dev/null
  setprop ctl.restart vendor.audio-hal
  sleep 5
  echo "  回退后 PID = $(pidof android.hardware.audio.service.mediatek)"
fi

echo "=== 5) AIDL 服务注册状态 ==="
lshal 2>/dev/null | grep -iE "bluetooth.audio" | head -12
