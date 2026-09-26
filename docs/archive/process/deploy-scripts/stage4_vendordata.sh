#!/system/bin/sh
# 把新库放到 /data/vendor/lhdcv5 并更新 ld.config
OLD=/data/local/tmp/p
NEW=/data/vendor/lhdcv5
CFG=/linkerconfig/ld.config.txt
BAK=/data/local/tmp/ld.config.txt.bak

echo "=== 1) 建目录并复制 ==="
mkdir -p $NEW
cp -f $OLD/*.so $NEW/ 2>/dev/null
mkdir -p $NEW/hw
cp -f $OLD/hw/*.so $NEW/hw/ 2>/dev/null
chcon -R u:object_r:vendor_file:s0 $NEW
ls -laZ $NEW | head -10

echo "=== 2) 更新 ld.config ==="
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

echo "=== 3) 重测服务二进制 ==="
M=/data/local/tmp/lhdcv5port
SVC=/vendor/bin/hw/android.hardware.audio.service.mediatek
logcat -c -b all 2>/dev/null
mount -o bind $M/etc/vintf/manifest.xml /vendor/etc/vintf/manifest.xml
mount -o bind $M/bin/hw/android.hardware.audio.service.mediatek $SVC
setprop ctl.restart vendor.audio-hal
sleep 10
NP=$(pidof android.hardware.audio.service.mediatek)
echo "PID = [$NP]"
if [ -n "$NP" ]; then
  echo "--- 从 /data/vendor/lhdcv5 加载的库 ---"
  grep "data/vendor/lhdcv5" /proc/$NP/maps 2>/dev/null | awk '{print $6}' | sort -u
fi

echo "=== 4) 错误日志 ==="
logcat -d -b all 2>/dev/null | grep -iE "CANNOT LINK|denied|audio server is restarting|hal_audio" | tail -12
