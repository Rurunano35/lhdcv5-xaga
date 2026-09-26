#!/system/bin/sh
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek

chmod 0755 $M/bin/hw/android.hardware.audio.service.mediatek
chcon u:object_r:mtk_hal_audio_exec:s0 $M/bin/hw/android.hardware.audio.service.mediatek
ls -laZ $M/bin/hw/

dmesg -c >/dev/null 2>&1
mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
ls -laZ $SVC

setprop ctl.restart vendor.audio-hal
sleep 10

NP=$(pidof android.hardware.audio.service.mediatek)
echo "PID = [$NP]"
if [ -n "$NP" ]; then
  echo "=== SUCCESS: 从新目录加载的库 ==="
  grep -E "lhdcv5|/data/vendor" /proc/$NP/maps 2>/dev/null | awk '{print $6}' | sort -u
  echo "=== AIDL 服务注册 ==="
  lshal 2>/dev/null | grep -iE "IBluetoothAudioProviderFactory" | head -8
  echo "=== 全部 bluetooth.audio 服务 ==="
  lshal 2>/dev/null | grep -icE "bluetooth.audio"
else
  echo "=== 仍失败 ==="
  dmesg 2>/dev/null | grep -iE "cannot execv|avc.*denied|exited with status" | tail -10
  umount $SVC 2>/dev/null
  umount /vendor/etc/vintf/manifest.xml 2>/dev/null
  setprop ctl.restart vendor.audio-hal
  sleep 6
  echo "reverted PID=$(pidof android.hardware.audio.service.mediatek)"
fi
