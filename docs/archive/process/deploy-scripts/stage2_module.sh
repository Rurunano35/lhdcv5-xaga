#!/system/bin/sh
# LHDC V5 AIDL 移植 - 阶段2：替换 BT 音频 HAL 模块（测试新搜索路径是否生效）
P=/data/local/tmp/p
SVC_BIN=/vendor/bin/hw/android.hardware.audio.service.mediatek

echo "=== 0) 清理早期遗留挂载 ==="
umount /vendor/lib64/libbluetooth_audio_session_mediatek.so 2>/dev/null && echo "  已卸载 _mediatek.so" || echo "  无遗留"

echo "=== 1) relabel ==="
chcon -R u:object_r:vendor_file:s0 $P
chcon u:object_r:vendor_file:s0 $P/hw/audio.bluetooth.default.so 2>/dev/null

echo "=== 2) bind-mount 新模块 ==="
mount -o bind $P/hw/audio.bluetooth.default.so /vendor/lib64/hw/audio.bluetooth.default.so \
  && echo "  MOUNTED module" || echo "  FAIL module"

echo "=== 3) 校验 ==="
ls -laZ /vendor/lib64/hw/audio.bluetooth.default.so
sha256sum /vendor/lib64/hw/audio.bluetooth.default.so

echo "=== 4) 重启 audio-hal ==="
setprop ctl.restart vendor.audio-hal
sleep 8

echo "=== 5) 结果 ==="
NP=$(pidof android.hardware.audio.service.mediatek)
echo "  PID = $NP"
if [ -n "$NP" ]; then
  echo "  --- 从 /data/local/tmp/p 加载的库 ---"
  grep "data/local/tmp/p" /proc/$NP/maps 2>/dev/null | awk '{print $6}' | sort -u
  echo "  --- bluetooth audio 相关映射 ---"
  grep -oE "/[^ ]*(bluetooth_audio_session|bluetooth.audio)[^ ]*" /proc/$NP/maps 2>/dev/null | sort -u | head -10
else
  echo "  !! 服务未启动"
fi
