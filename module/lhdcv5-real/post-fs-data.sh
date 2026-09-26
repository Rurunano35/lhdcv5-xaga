#!/system/bin/sh
# LHDC V5 AIDL 通路 —— 开机自动生效
#
# 目标：让蓝牙协议栈走 AIDL 传输层，从而：
#   - LHDC V5 以 codec_type=12 原生送达 HAL（不再伪装成 V3）
#   - 解锁 192 kHz（软件 PCM 采样率上限由策略放开）
#
# 完整说明见 docs/LHDC-V5-通路-实现报告.md。四道已排除的障碍简述：
#   1. 本机 SELinux 禁止 init exec 任何 bind-mount 回来的可执行文件
#      （execute_no_trans denied）→ 因此不替换音频 HAL 服务二进制，
#      改为用一个 shim 顶替它本来就会 dlopen 的 HIDL 实现库
#      （dlopen 只需 read+mmap，不受 execute 限制）。
#   2. /linkerconfig/ld.config.txt 必须【原地写入】—— 用 mv 换 inode 会卡开机。
#   3. servicemanager 在开机时缓存 VINTF → 含 AIDL 声明的 manifest
#      必须在开机期就位（所以整套必须做成开机模块，不能只靠 ADB）。
#   4. MediaTek 的 AIDL 实现依赖比本机更新的 libhidlbase（缺
#      android::hardware::details::check，RTLD_GLOBAL 无效）
#      → 该实现有 3 个冗余 DT_NEEDED，已把其中之一改写指向符号补齐库，
#        使补齐库进入其依赖闭包。

MODDIR=${0%/*}
STAGE=/data/vendor/lhdcv5
V=/vendor
LOG=/data/local/tmp/lhdcv5-aidl.log
: > "$LOG"
log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

log "=== lhdcv5-real 启动 ==="

# ---------- 1) 落地载荷（不能放模块目录：Zygisk Next 会剥离那里的挂载）----------
mkdir -p "$STAGE" || { log "mkdir $STAGE 失败"; exit 1; }
cp -f "$MODDIR"/payload/*.so "$STAGE"/ 2>/dev/null
cp -f "$MODDIR"/payload/manifest.xml "$STAGE"/manifest.xml 2>/dev/null
cp -f "$MODDIR"/payload/bt_audio_policy.xml "$STAGE"/bt_audio_policy.xml 2>/dev/null

chmod 0644 "$STAGE"/*.so "$STAGE"/manifest.xml "$STAGE"/bt_audio_policy.xml 2>/dev/null
# 标签必须与 /vendor 上原件一致，否则目标域读不到
chcon u:object_r:vendor_file:s0 "$STAGE"/*.so 2>/dev/null
chcon u:object_r:vendor_configs_file:s0 "$STAGE"/manifest.xml 2>/dev/null
chcon u:object_r:vendor_configs_file:s0 "$STAGE"/bt_audio_policy.xml 2>/dev/null
chmod 0755 "$STAGE"
log "载荷: $(ls $STAGE/*.so 2>/dev/null | wc -l) 个 .so"

# ---------- 2) ld.config 原地写入（同 inode，不能 mv）----------
CFG=/linkerconfig/ld.config.txt
ANCHOR='namespace.default.search.paths += /vendor/${LIB}/egl'
if [ -f "$CFG" ] && ! grep -q "data/vendor/lhdcv5" "$CFG"; then
  if grep -qF "$ANCHOR" "$CFG"; then
    awk -v a="$ANCHOR" '
      /^\[vendor\]$/ { inv=1 }
      /^\[/ && $0 != "[vendor]" { inv=0 }
      { print }
      inv==1 && $0 == a {
        print "namespace.default.search.paths += /data/vendor/lhdcv5"
        print "namespace.default.permitted.paths += /data/vendor/lhdcv5"
      }
    ' "$CFG" > /data/local/tmp/ld.new 2>>"$LOG"
    if [ -s /data/local/tmp/ld.new ]; then
      cat /data/local/tmp/ld.new > "$CFG"
      log "ld.config 原地写入完成（补丁行=$(grep -c data/vendor/lhdcv5 $CFG)）"
    else
      log "ld.config awk 输出为空"
    fi
  else
    log "ld.config 锚点行缺失"
  fi
else
  log "ld.config 已有补丁或不存在"
fi

# ---------- 3) 挂载 ----------
CHANGED=0
mount_one() {
  if [ -f "$1" ] && [ -f "$2" ]; then
    mount --bind "$1" "$2" && { CHANGED=$((CHANGED+1)); log "挂载 OK $2"; } || log "挂载 FAIL $2"
  else
    log "跳过（文件缺失）$2"
  fi
}

# 3a) shim 顶替 MTK HIDL 2.2 实现（dlopen 路径，非 exec）
mount_one "$STAGE/shim.so" "$V/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so"
# 3b) AIDL 版音频 HAL 模块
mount_one "$STAGE/audio.bluetooth.default.so" "$V/lib64/hw/audio.bluetooth.default.so"
# 3c) VINTF：加入 AIDL 声明（必须在 servicemanager 读 VINTF 之前）
mount_one "$STAGE/manifest.xml" "$V/etc/vintf/manifest.xml"
# 3d) BT 音频策略：放开采样率到 192 kHz
mount_one "$STAGE/bt_audio_policy.xml" "$V/etc/bluetooth_audio_policy_configuration.xml"

log "=== 完成，挂载 $CHANGED 项 ==="

# ---------- 4) 关闭 A2DP 硬件 offload ----------
# 本机策略 persist.bluetooth.a2dp_offload.cap=sbc-aac 只把 SBC/AAC 交给
# A2DP_HARDWARE_OFFLOAD 通路，而该通路在 xaga 上起不来（AIDL offload provider
# 的 startSession 直接返回，没有 streamStarted，见 MtkBTAudioProviderA2dpHW）。
# 关掉 offload 后 SBC/AAC 会落到 A2DP_SOFTWARE 通路（MtkBTAudioProviderA2dpSW），
# 该通路已验证可用（LHDC V5 走的就是它）。LHDC 本来就不在 offload 列表里，不受影响。
setprop persist.bluetooth.a2dp_offload.disabled true
log "A2DP offload 已关闭（persist.bluetooth.a2dp_offload.disabled=$(getprop persist.bluetooth.a2dp_offload.disabled)）"
