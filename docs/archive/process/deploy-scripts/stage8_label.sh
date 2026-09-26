#!/system/bin/sh
# 用正确的 SELinux exec 标签重测
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek

echo "=== 1) 给替换件打正确标签 ==="
chcon u:object_r:mtk_hal_audio_exec:s0 $M/bin/hw/android.hardware.audio.service.mediatek
ls -laZ $M/bin/hw/

echo "=== 2) 挂载 ==="
logcat -c -b all 2>/dev/null
mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
ls -laZ $SVC

echo "=== 3) 重启 ==="
setprop ctl.restart vendor.audio-hal
sleep 10

NP=$(pidof android.hardware.audio.service.mediatek)
echo "PID = [$NP]"
if [ -n "$NP" ]; then
  echo "=== 4) 成功！从新目录加载的库 ==="
  grep -E "lhdcv5|/data/vendor" /proc/$NP/maps 2>/dev/null | awk '{print $6}' | sort -u
  echo "=== AIDL 服务注册 ==="
  lshal 2>/dev/null | grep -iE "IBluetoothAudioProviderFactory|bluetooth.audio" | head -12
else
  echo "=== 仍失败，看日志 ==="
  logcat -d -b all 2>/dev/null | grep -iE "exec|denied|audio-hal|HalDeath|CANNOT LINK" | tail -15
  echo "=== 回退 ==="
  umount $SVC 2>/dev/null
  umount /vendor/etc/vintf/manifest.xml 2>/dev/null
  setprop ctl.restart vendor.audio-hal
  sleep 6
  echo "reverted PID=$(pidof android.hardware.audio.service.mediatek)"
fi
