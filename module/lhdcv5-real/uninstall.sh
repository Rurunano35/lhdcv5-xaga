#!/system/bin/sh
# LHDC V5 模块 —— 卸载清理
#
# 触发时机：KernelSU 在「移除模块」后的**下次开机**、post-fs-data 阶段执行本脚本
# （root 权限，cwd = 模块目录），随后才 remove_dir_all 删掉模块目录。
# 注意顺序：那一次开机模块已经不再加载，所以 post-fs-data.sh 不会运行 ——
# 也就是说，本脚本要负责清掉 post-fs-data.sh 与 Zygisk 模块留在**模块目录之外**的一切。
#
# 清不了也不需要清的（重启即自愈，无需在这里处理）：
#   - /linkerconfig/ld.config.txt —— tmpfs，每次开机由系统重建
#   - /vendor 下被 bind 顶替的 4 个文件 —— bind mount 只存在于内存
#   - Zygisk 的内存补丁 —— 随进程消失
#
# 清理日志写在 /data/local/tmp/lhdcv5-uninstall.log：它按名字会被下面的清理
# 连带删除，所以刻意放在最后一步之前不删，留作凭据（无害，可随时手删）。

LOG=/data/local/tmp/lhdcv5-uninstall.log
: > "$LOG"
log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
log "=== lhdcv5-real 卸载清理开始 ==="

# resetprop 优先用 KernelSU 自带的；Magisk 的 resetprop 也可
RESETPROP=""
for c in /data/adb/ksud /data/adb/ksu/bin/ksud; do
  [ -x "$c" ] && { RESETPROP="$c resetprop"; break; }
done
[ -z "$RESETPROP" ] && command -v resetprop >/dev/null 2>&1 && RESETPROP="resetprop"

# ---------- 1) 恢复 A2DP 硬件 offload ----------
# post-fs-data.sh 每次开机都执行
#   setprop persist.bluetooth.a2dp_offload.disabled true
# 这个属性落在 /data/property/persistent_properties，**与模块目录无关**，
# 所以删模块不会清掉它。必须真正删除：`setprop … ""` 只是持久化一个空值条目。
# ROM 默认值 false 定义在 /vendor/build.prop:435。
K=persist.bluetooth.a2dp_offload.disabled
if [ -n "$RESETPROP" ]; then
  $RESETPROP -p -d "$K" && log "已删除 $K（$RESETPROP -p -d）" \
                          || log "删除 $K 失败（$RESETPROP）—— 请手动处理"
else
  setprop "$K" "" 2>/dev/null && log "无 resetprop，已置空 $K（会留下空值条目）"
  log "建议手动执行：/data/adb/ksud resetprop -p -d $K"
fi

# ---------- 2) 清掉更早实验遗留的 lhdcv5 属性 ----------
# 不是当前模块写的（本模块的属性只有上面那一条），但同属本项目，一并清掉
for K in persist.bluetooth.lhdcv5.sample_rate persist.vendor.bluetooth.lhdcv5.test; do
  [ -n "$RESETPROP" ] && $RESETPROP -p -d "$K" 2>/dev/null && log "已删除 $K"
done

# ---------- 3) 落地产物与残留文件 ----------
# 只清本项目的文件，不动 /data/local/tmp 里别人的东西。
for f in /data/vendor/lhdcv5 \
         /data/misc/bluedroid/lhdcv5_sr.conf \
         /data/adb/lhdcv5.log \
         /data/local/tmp/ld.new \
         /data/local/tmp/lhdcv5port \
         /data/local/tmp/lhdcv5-admit.tar.gz \
         /data/local/tmp/lhdcv5-aidl.tar.gz \
         /data/local/tmp/lhdcv5-aidl.log \
         /data/local/tmp/lhdcv5-real.tar.gz \
         /data/local/tmp/lhdcv5-t1.log /data/local/tmp/lhdcv5-t1.tar.gz \
         /data/local/tmp/lhdcv5-t3.log /data/local/tmp/lhdcv5-t3.tar.gz \
         /data/local/tmp/lhdcv5-t4.log /data/local/tmp/lhdcv5-t4.tar.gz \
         /data/local/tmp/lhdcv5-t5.log /data/local/tmp/lhdcv5-t5.tar.gz \
         /data/local/tmp/liblhdcv5.so /data/local/tmp/liblhdcv5BT_enc.so; do
  [ -e "$f" ] && { rm -rf "$f" 2>/dev/null && log "已删除 $f"; }
done

log "=== 完成。请重启：bind mount 与 Zygisk 内存补丁都只在重启后才会消失 ==="
