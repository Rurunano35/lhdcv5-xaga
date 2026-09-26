#!/system/bin/sh
# LHDC V5 AIDL 移植 - 阶段1：准备新库目录 + 给 [vendor] 命名空间加搜索路径
P=/data/local/tmp/p
BAK=/data/local/tmp/ld.config.txt.bak
CFG=/linkerconfig/ld.config.txt

echo "=== 1) relabel 新库为 vendor_file ==="
chcon -R u:object_r:vendor_file:s0 $P
ls -laZ $P | head -6

echo "=== 2) 备份 ld.config ==="
[ -f $BAK ] || cp $CFG $BAK
ls -la $BAK

echo "=== 3) 检查是否已打过补丁 ==="
if grep -q "data/local/tmp/p" $CFG; then
  echo "already patched"
else
  awk '
    /^\[vendor\]$/ { inv=1 }
    /^\[/ && $0 != "[vendor]" { inv=0 }
    { print }
    inv==1 && $0 == "namespace.default.search.paths += /vendor/${LIB}/egl" {
      print "namespace.default.search.paths += /data/local/tmp/p"
      print "namespace.default.permitted.paths += /data/local/tmp/p"
    }
  ' $BAK > $CFG.new
  mv $CFG.new $CFG
  echo "patched"
fi

echo "=== 4) 校验插入结果 ==="
grep -n "data/local/tmp/p" $CFG
echo "--- [vendor] 段确认 ---"
grep -n -A5 "^namespace.default.search.paths = /odm" $CFG | head -12
