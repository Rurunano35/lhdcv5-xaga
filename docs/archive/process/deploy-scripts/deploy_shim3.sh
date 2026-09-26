#!/system/bin/sh
# 部署 v3：ld.config 同时暴露 /data/vendor/lhdcv5 与 btservices APEX
CFG=/linkerconfig/ld.config.txt
BAK=/data/local/tmp/ld.config.txt.bak
M=/data/local/tmp/lhdcv5port
V=/vendor
LIB=/data/vendor/lhdcv5

echo "=== 1) ld.config 补丁（两个路径）==="
[ -f $BAK ] || cp $CFG $BAK
cp -f $BAK $CFG
awk '
  /^\[vendor\]$/ { inv=1 }
  /^\[/ && $0 != "[vendor]" { inv=0 }
  { print }
  inv==1 && $0 == "namespace.default.search.paths += /vendor/${LIB}/egl" {
    print "namespace.default.search.paths += /data/vendor/lhdcv5"
    print "namespace.default.permitted.paths += /data/vendor/lhdcv5"
    print "namespace.default.search.paths += /apex/com.android.btservices/${LIB}"
    print "namespace.default.permitted.paths += /apex/com.android.btservices/${LIB}"
  }
' $BAK > $CFG.new && mv $CFG.new $CFG
grep -n "btservices\|data/vendor/lhdcv5" $CFG

echo "=== 2) 重新挂载 ==="
for m in $(mount | grep -E " /vendor/" | awk '{print $3}'); do umount "$m" 2>/dev/null; done
logcat -c -b all 2>/dev/null
chcon u:object_r:vendor_file:s0 $LIB/*.so 2>/dev/null

mount --bind $M/hw/shim.so "$V/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so" && echo "  OK shim"
mount --bind $M/lib64/hw/audio.bluetooth.default.so "$V/lib64/hw/audio.bluetooth.default.so" && echo "  OK module"
mount --bind $M/etc/vintf/manifest.xml "$V/etc/vintf/manifest.xml" && echo "  OK manifest"

echo "=== 3) 重启 audio-hal ==="
setprop ctl.restart vendor.audio-hal
sleep 10
NP=$(pidof android.hardware.audio.service.mediatek)
echo "PID = [$NP]"

echo "=== 4) shim 日志 ==="
logcat -d -b all 2>/dev/null | grep -E "LHDCV5SHIM" | tail -12

echo "=== 5) AIDL 服务 ==="
lshal 2>/dev/null | grep -iE "IBluetoothAudioProviderFactory" | head -5
service list 2>/dev/null | grep -iE "bluetooth.audio" | head -6
echo "--- 从新目录加载 ---"
[ -n "$NP" ] && grep -E "lhdcv5|btservices" /proc/$NP/maps 2>/dev/null | awk '{print $6}' | sort -u | head -12
