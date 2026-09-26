#!/system/bin/sh
# 捕获新服务二进制退出前的全部输出（按 PID 过滤）
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek
OUT=/data/local/tmp/svc_fail.log

logcat -c -b all 2>/dev/null
sleep 1
mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
echo "mounted: $(sha256sum $SVC | cut -c1-16)"

# 记录起始时间与 PID 快照
T0=$(date +%s)
OLD=$(cat /proc/sys/kernel/ns_last_pid 2>/dev/null)
setprop ctl.restart vendor.audio-hal
sleep 8

NP=$(pidof android.hardware.audio.service.mediatek)
echo "PID after = [$NP]  (old ns_last_pid=$OLD)"

# 抓取全部日志到文件
logcat -d -b all 2>/dev/null > $OUT
echo "log lines: $(wc -l < $OUT)"

echo "===== 含 audioserver / audio-hal / audio 服务 PID 范围的日志 ====="
grep -nE "audioserver|audio service|vendor\.audio|audio-hal|mtk_hal_audio|HalDeathHandler" $OUT | tail -25

echo "===== 日志中 PID > \$OLD 的行（新进程）====="
grep -E "^[0-9-]+ +[0-9:.]+ +[0-9]+ " $OUT | awk -v old="$OLD" '{ if ($3+0 > old) print }' | head -40

echo "===== 回退 ====="
umount $SVC 2>/dev/null
umount /vendor/etc/vintf/manifest.xml 2>/dev/null
setprop ctl.restart vendor.audio-hal
sleep 6
echo "reverted PID=$(pidof android.hardware.audio.service.mediatek)"
