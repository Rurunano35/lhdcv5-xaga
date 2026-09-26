#!/system/bin/sh
# 换文件系统测试：把二进制放到 tmpfs/devtmpfs 上再 bind-mount
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek
M=/data/local/tmp/lhdcv5port
Z=$M/bin/hw/android.hardware.audio.service.mediatek

try_fs() {
  LABEL=$1; DST=$2
  echo "########## 试验: $LABEL ($DST) ##########"
  mkdir -p "$DST" 2>/dev/null
  cp -f $Z $DST/svc
  chmod 0755 $DST/svc
  chcon u:object_r:mtk_hal_audio_exec:s0 $DST/svc 2>/dev/null
  ls -laZ $DST/svc
  echo "  mount fs: $(df -T $DST 2>/dev/null | tail -1)"

  dmesg -c >/dev/null 2>&1
  mount --bind $DST/svc $SVC
  setprop ctl.restart vendor.audio-hal
  sleep 7
  NP=$(pidof android.hardware.audio.service.mediatek)
  echo "  PID = [$NP]"
  if [ -n "$NP" ]; then
    echo "  === 成功！==="
    dmesg -c >/dev/null 2>&1
    umount $SVC 2>/dev/null
    setprop ctl.restart vendor.audio-hal; sleep 5
    return 0
  else
    echo "  --- dmesg ---"
    dmesg 2>/dev/null | grep -iE "cannot execv|execute_no_trans|execute.*denied" | tail -3
    umount $SVC 2>/dev/null
    setprop ctl.restart vendor.audio-hal; sleep 5
    return 1
  fi
}

echo "=== tmpfs 测试 ==="
mkdir -p /data/local/tmp/tmpfs
mount -t tmpfs tmpfs /data/local/tmp/tmpfs 2>&1
try_fs "tmpfs" /data/local/tmp/tmpfs
umount /data/local/tmp/tmpfs 2>/dev/null

echo "=== devtmpfs 测试 ==="
mkdir -p /dev/lhdcv5 2>/dev/null
try_fs "devtmpfs" /dev/lhdcv5

echo "=== 最终回退 ==="
umount $SVC 2>/dev/null
setprop ctl.restart vendor.audio-hal
sleep 6
echo "PID=$(pidof android.hardware.audio.service.mediatek)"
mount | grep -cE " /vendor/"
