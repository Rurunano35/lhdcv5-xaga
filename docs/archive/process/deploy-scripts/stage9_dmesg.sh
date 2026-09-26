#!/system/bin/sh
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek

dmesg -c >/dev/null 2>&1
logcat -c -b all 2>/dev/null
echo "ns_last_pid before = $(cat /proc/sys/kernel/ns_last_pid)"

mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
setprop ctl.restart vendor.audio-hal

# 高频采样，看进程是否短暂存在
for i in 1 2 3 4 5 6 7 8 9 10; do
  P=$(pidof android.hardware.audio.service.mediatek)
  echo "  t=$i PID=[$P]"
  sleep 1
done

echo "ns_last_pid after = $(cat /proc/sys/kernel/ns_last_pid)"
echo "===== dmesg ====="
dmesg 2>/dev/null | grep -iE "avc|denied|exec|segfault|tombstone|vendor.audio" | tail -25

echo "===== 回退 ====="
umount $SVC 2>/dev/null
umount /vendor/etc/vintf/manifest.xml 2>/dev/null
setprop ctl.restart vendor.audio-hal
sleep 6
echo "reverted PID=$(pidof android.hardware.audio.service.mediatek)"
