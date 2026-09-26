#!/system/bin/sh
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek

logcat -c -b all 2>/dev/null
sleep 1
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
setprop ctl.restart vendor.audio-hal
sleep 6
echo "PID=[$(pidof android.hardware.audio.service.mediatek)]"

echo "===== 崩溃/链接错误 ====="
logcat -d -b all 2>/dev/null | grep -iE "tombstone|signal [0-9]|FATAL|abort|CANNOT LINK|not found|DEBUG|crash|audio-hal" | head -40

echo "===== 所有含 vendor.audio-hal 的行 ====="
logcat -d -b all 2>/dev/null | grep -iE "vendor.audio-hal|audio.service.mediatek" | tail -20

echo "===== 回退 ====="
umount $SVC 2>/dev/null
setprop ctl.restart vendor.audio-hal
sleep 6
echo "reverted PID = $(pidof android.hardware.audio.service.mediatek)"
