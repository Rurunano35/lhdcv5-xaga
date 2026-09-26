#!/system/bin/sh
# LHDC V5 AIDL 移植 —— 临时 bind-mount 测试
# 用法: sh /data/local/tmp/lhdcv5port/mount.sh [libs|all|umount]
SRC=/data/local/tmp/lhdcv5port

LIBS="lib64/hw/audio.bluetooth.default.so
lib64/libbluetooth_audio_session_aidl.so
lib64/libbluetooth_audio_session_aidl_mtk.so
lib64/libbluetooth_audio_session_mediatek.so
lib64/android.hardware.bluetooth.audio-impl.so
lib64/vendor.mediatek.hardware.bluetooth.audio-impl.so
lib64/android.hardware.bluetooth.audio-V3-ndk.so
lib64/vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so"

OTHER="etc/vintf/manifest/bluetooth_audio.xml"
SVC="bin/hw/android.hardware.audio.service.mediatek"

relabel() {
  chcon -R u:object_r:vendor_file:s0 $SRC/lib64 $SRC/bin $SRC/etc 2>/dev/null
  echo "--- labels ---"
  ls -laZ $SRC/lib64 2>/dev/null | head -3
}

do_mount() {
  for f in $1; do
    mount -o bind $SRC/$f /vendor/$f && echo "  MOUNTED $f" || echo "  FAIL    $f"
  done
}

do_umount() {
  for f in $SVC $OTHER $LIBS; do
    umount /vendor/$f 2>/dev/null && echo "  UMOUNTED $f"
  done
}

case "$1" in
  libs)
    relabel
    do_mount "$LIBS"
    do_mount "$OTHER"
    ;;
  all)
    relabel
    do_mount "$LIBS"
    do_mount "$OTHER"
    do_mount "$SVC"
    ;;
  umount)
    do_umount
    ;;
  verify)
    echo "--- 挂载状态 ---"
    mount | grep -E "vendor/(lib64|bin|etc)" | head -20
    echo "--- 读回校验 ---"
    for f in $LIBS $OTHER $SVC; do
      if [ -f /vendor/$f ]; then
        printf "  %-70s %s\n" "$f" "$(sha256sum /vendor/$f | cut -c1-16)"
      fi
    done
    ;;
  *)
    echo "usage: $0 [libs|all|umount|verify]"
    ;;
esac
