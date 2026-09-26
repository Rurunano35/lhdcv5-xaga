#!/system/bin/sh
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek

logcat -c -b all 2>/dev/null
sleep 1
mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
echo "mounted hash: $(sha256sum $SVC | cut -c1-16)"
setprop ctl.restart vendor.audio-hal
sleep 8
echo "PID=[$(pidof android.hardware.audio.service.mediatek)]"

echo "===== RAW LOGCAT (全部, 后 120 行) ====="
logcat -d -b all 2>/dev/null | tail -120

echo "===== 回退 ====="
umount $SVC 2>/dev/null
umount /vendor/etc/vintf/manifest.xml 2>/dev/null
setprop ctl.restart vendor.audio-hal
sleep 6
echo "reverted PID = $(pidof android.hardware.audio.service.mediatek)"
