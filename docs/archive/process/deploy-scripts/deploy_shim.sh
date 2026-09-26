#!/system/bin/sh
# LHDC V5 AIDL 点亮 - shim 方案部署
V=/vendor
M=/data/local/tmp/lhdcv5port
LIB=/data/vendor/lhdcv5
SVC=$V/bin/hw/android.hardware.audio.service.mediatek

echo "=== 0) 清理旧挂载 ==="
for m in $(mount | grep -E " /vendor/" | awk '{print $3}'); do umount "$m" 2>/dev/null; done

echo "=== 1) 标签 ==="
chcon -R u:object_r:vendor_file:s0 $LIB 2>/dev/null
chcon u:object_r:vendor_file:s0 $M/hw/shim.so $M/hw/audio.bluetooth.default.so 2>/dev/null

echo "=== 2) 挂载 ==="
logcat -c -b all 2>/dev/null
dmesg -c >/dev/null 2>&1

mount --bind $M/hw/shim.so "$V/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so" \
  && echo "  OK shim" || echo "  FAIL shim"
mount --bind $M/hw/audio.bluetooth.default.so "$V/lib64/hw/audio.bluetooth.default.so" \
  && echo "  OK module" || echo "  FAIL module"
mount --bind $M/etc/vintf/manifest.xml "$V/etc/vintf/manifest.xml" \
  && echo "  OK manifest" || echo "  FAIL manifest"

echo "=== 3) 重启 audio-hal ==="
setprop ctl.restart vendor.audio-hal
sleep 10

NP=$(pidof android.hardware.audio.service.mediatek)
echo "PID = [$NP]"

echo "=== 4) shim 日志 ==="
logcat -d -b all 2>/dev/null | grep -E "LHDCV5SHIM" | tail -15

echo "=== 5) AIDL 服务是否注册 ==="
lshal 2>/dev/null | grep -iE "IBluetoothAudioProviderFactory" | head -6
service list 2>/dev/null | grep -i "bluetooth.audio" | head -6

echo "=== 6) 从新目录加载的库 ==="
if [ -n "$NP" ]; then
  grep -E "lhdcv5" /proc/$NP/maps 2>/dev/null | awk '{print $6}' | sort -u
fi
