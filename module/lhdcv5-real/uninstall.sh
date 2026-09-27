#!/system/bin/sh
# LHDC V5 模块 —— 卸载清理
#
# 触发时机：KernelSU 在「移除模块」后的**下次开机**、post-fs-data 阶段执行本脚本
# （root 权限，cwd = 模块目录），随后才 remove_dir_all 删掉模块目录。
# 注意顺序：那一次开机模块已经不再加载，所以 post-fs-data.sh 不会运行 ——
# 也就是说，本脚本要负责清掉本模块留在**模块目录之外**的一切。
#
# 本脚本**只清理本模块自己的产物**，共五处：
#   1. persist.bluetooth.a2dp_offload.disabled   （post-fs-data.sh 每次开机设）
#   2. /data/vendor/lhdcv5/                      （post-fs-data.sh 落地载荷）
#   3. 采样率偏好文件（zygisk 模块写的）。module.cpp 的 sr_pick_path() 有两个候选路径：
#      首选 /data/misc/bluedroid/lhdcv5_sr.conf，回退 /data/local/tmp/lhdcv5_sr.conf ——
#      **两个都要删**，只删首选的话回退路径生效时会漏。
#   4. /data/local/tmp/lhdcv5-aidl.log           （post-fs-data.sh 每次开机重写）
#   5. /data/local/tmp/ld.new                    （post-fs-data.sh 写 ld.config 补丁的中间文件）
#
# ★ 卸载后**不留任何文件**，包括本脚本自己的日志：日志只写 logcat（缓冲区自清理，
#   不是磁盘残留）。要看清理过程就在重启后立刻抓：
#       adb logcat -d -s LHDCV5U
#
# 清不了也不需要清的（重启即自愈，无需在这里处理）：
#   - /linkerconfig/ld.config.txt —— tmpfs，每次开机由系统重建
#   - /vendor 下被 bind 顶替的 4 个文件 —— bind mount 只存在于内存
#   - Zygisk 的内存补丁 —— 随进程消失
#
# 本项目历史上手工推入 /data/local/tmp 的临时文件（安装包、调试 dump 等）
# 不属于本模块的产物，本脚本刻意不碰，由使用者在模块外自行处置。

log() { /system/bin/log -t LHDCV5U "$@" 2>/dev/null; }
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

# ---------- 2) 落地产物与中间文件 ----------
for f in /data/vendor/lhdcv5 \
         /data/misc/bluedroid/lhdcv5_sr.conf \
         /data/local/tmp/lhdcv5_sr.conf \
         /data/local/tmp/ld.new \
         /data/local/tmp/lhdcv5-aidl.log; do
  [ -e "$f" ] && { rm -rf "$f" 2>/dev/null && log "已删除 $f"; }
done

log "=== 完成。请重启：bind mount 与 Zygisk 内存补丁都只在重启后才会消失 ==="
# 本脚本不写任何文件：以上日志只进 logcat。卸载完成后本模块在磁盘上零残留。
