#!/system/bin/sh
# 重测新服务二进制并立即抓日志
P=/data/local/tmp/p
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek

logcat -c -b all 2>/dev/null
sleep 1

mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml
chcon u:object_r:vendor_file:s0 $SVC 2>/dev/null
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
setprop ctl.restart vendor.audio-hal
sleep 8

NP=$(pidof android.hardware.audio.service.mediatek)
echo "PID after restart: [$NP]"

echo "=== 日志（linker / init / 服务）==="
logcat -d -b all 2>/dev/null | grep -iE "CANNOT LINK|library .* not found|dlopen failed|audio-hal|audio.service|linker|namespace" | tail -40

echo "=== 回退 ==="
umount $SVC 2>/dev/null
umount /vendor/etc/vintf/manifest.xml 2>/dev/null
setprop ctl.restart vendor.audio-hal
sleep 6
echo "reverted PID = $(pidof android.hardware.audio.service.mediatek)"
