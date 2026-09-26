#!/system/bin/sh
# 重新应用 ld.config 搜索路径 + 修正模块路径 + 重测
CFG=/linkerconfig/ld.config.txt
BAK=/data/local/tmp/ld.config.txt.bak
M=/data/local/tmp/lhdcv5port
V=/vendor
LIB=/data/vendor/lhdcv5

echo "=== 1) 还原并重新打 ld.config 补丁 ==="
[ -f $BAK ] || cp $CFG $BAK
cp -f $BAK $CFG
awk '
  /^\[vendor\]$/ { inv=1 }
  /^\[/ && $0 != "[vendor]" { inv=0 }
  { print }
  inv==1 && $0 == "namespace.default.search.paths += /vendor/${LIB}/egl" {
    print "namespace.default.search.paths += /data/vendor/lhdcv5"
    print "namespace.default.permitted.paths += /data/vendor/lhdcv5"
  }
' $BAK > $CFG.new && mv $CFG.new $CFG
grep -n "data/vendor/lhdcv5" $CFG

echo "=== 2) 找模块文件实际位置 ==="
find $M -name "audio.bluetooth.default.so" 2>/dev/null

echo "=== 3) 重新挂载 ==="
for m in $(mount | grep -E " /vendor/" | awk '{print $3}'); do umount "$m" 2>/dev/null; done
logcat -c -b all 2>/dev/null
chcon -R u:object_r:vendor_file:s0 $LIB $M 2>/dev/null

MOD=$(find $M -name "audio.bluetooth.default.so" | head -1)
mount --bind $M/hw/shim.so "$V/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so" && echo "  OK shim"
[ -n "$MOD" ] && mount --bind "$MOD" "$V/lib64/hw/audio.bluetooth.default.so" && echo "  OK module ($MOD)" || echo "  FAIL module"
mount --bind $M/etc/vintf/manifest.xml "$V/etc/vintf/manifest.xml" && echo "  OK manifest"

echo "=== 4) 重启 audio-hal ==="
setprop ctl.restart vendor.audio-hal
sleep 10
NP=$(pidof android.hardware.audio.service.mediatek)
echo "PID = [$NP]"

echo "=== 5) shim 日志 ==="
logcat -d -b all 2>/dev/null | grep -E "LHDCV5SHIM" | tail -12

echo "=== 6) AIDL 服务注册 ==="
lshal 2>/dev/null | grep -iE "IBluetoothAudioProviderFactory" | head -5
echo "--- service list ---"
service list 2>/dev/null | grep -i "bluetooth.audio" | head -8

echo "=== 7) 从新目录加载的库 ==="
[ -n "$NP" ] && grep -E "lhdcv5" /proc/$NP/maps 2>/dev/null | awk '{print $6}' | sort -u
