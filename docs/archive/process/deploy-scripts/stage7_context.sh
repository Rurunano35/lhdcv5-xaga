#!/system/bin/sh
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek
OUT=/data/local/tmp/svc_fail2.log

logcat -c -b all 2>/dev/null
sleep 1
mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
setprop ctl.restart vendor.audio-hal
sleep 8
logcat -d -b all 2>/dev/null > $OUT

LN=$(grep -n "HAL server crashed" $OUT | head -1 | cut -d: -f1)
echo "crash line = $LN (total $(wc -l < $OUT))"
if [ -n "$LN" ]; then
  S=$((LN-45)); [ $S -lt 1 ] && S=1
  sed -n "${S},$((LN+3))p" $OUT
fi

echo "===== 回退 ====="
umount $SVC 2>/dev/null
umount /vendor/etc/vintf/manifest.xml 2>/dev/null
setprop ctl.restart vendor.audio-hal
sleep 6
echo "reverted PID=$(pidof android.hardware.audio.service.mediatek)"
