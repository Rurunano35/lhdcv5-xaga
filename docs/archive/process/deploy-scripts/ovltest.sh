#!/system/bin/sh
# 测试本机 overlayfs 是否可用于「在只读目录中新增文件」
set -x
B=/data/local/tmp/ovltest
rm -rf $B; mkdir -p $B/lower $B/upper $B/work $B/mnt
echo hello > $B/lower/existing.txt
echo new   > $B/upper/added.txt
chcon u:object_r:vendor_file:s0 $B/upper/added.txt $B/lower/existing.txt 2>/dev/null

mount -t overlay overlay \
  -o lowerdir=$B/lower,upperdir=$B/upper,workdir=$B/work \
  $B/mnt
echo "mount rc=$?"
echo "--- contents ---"
ls -laZ $B/mnt
echo "--- read existing ---"
cat $B/mnt/existing.txt
echo "--- read added ---"
cat $B/mnt/added.txt
umount $B/mnt 2>/dev/null
