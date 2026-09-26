#!/system/bin/sh
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek

dmesg -c >/dev/null 2>&1
mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
setprop ctl.restart vendor.audio-hal
sleep 8

echo "PID=[$(pidof android.hardware.audio.service.mediatek)]"
echo "===== dmesg: 只看 vendor.audio-hal / execv ====="
dmesg 2>/dev/null | grep -iE "vendor.audio-hal|cannot execv|audio.service.mediatek" | tail -20

echo "===== 新二进制自身能否被内核识别 ====="
head -c 4 $SVC | od -An -tx1
/system/bin/toybox file $SVC 2>/dev/null || echo "(no file cmd)"

echo "===== 回退 ====="
umount $SVC 2>/dev/null
umount /vendor/etc/vintf/manifest.xml 2>/dev/null
setprop ctl.restart vendor.audio-hal
sleep 6
echo "reverted PID=$(pidof android.hardware.audio.service.mediatek)"
