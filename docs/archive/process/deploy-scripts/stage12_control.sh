#!/system/bin/sh
# 控制实验：原始 xaga 二进制经 /data bind-mount 回去，是否也被拒？
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek
CTL=/data/vendor/lhdcv5/ctrl

echo "=== 1) 备份原始二进制 ==="
mkdir -p $CTL
cp -f $SVC $CTL/orig_svc
chmod 0755 $CTL/orig_svc
chcon u:object_r:mtk_hal_audio_exec:s0 $CTL/orig_svc
ls -laZ $CTL/orig_svc
sha256sum $CTL/orig_svc

echo "=== 2) bind-mount 回去（内容=原始）==="
dmesg -c >/dev/null 2>&1
mount --bind $CTL/orig_svc $SVC
ls -laZ $SVC

echo "=== 3) 重启 ==="
setprop ctl.restart vendor.audio-hal
sleep 8
NP=$(pidof android.hardware.audio.service.mediatek)
echo "PID = [$NP]"

if [ -z "$NP" ]; then
  echo "=== 原始二进制经 /data 挂回也失败 → 确认是 fs/bind-mount 问题 ==="
  dmesg 2>/dev/null | grep -iE "vendor.audio-hal|cannot execv|execute" | tail -8
else
  echo "=== 原始二进制经 /data 挂回成功 → 问题在 zircon 二进制本身 ==="
fi

echo "=== 4) 回退 ==="
umount $SVC 2>/dev/null
setprop ctl.restart vendor.audio-hal
sleep 6
echo "reverted PID=$(pidof android.hardware.audio.service.mediatek)"
mount | grep -cE " /vendor/"
