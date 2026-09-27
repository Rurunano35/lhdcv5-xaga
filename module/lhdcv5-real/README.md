# 交付模块：lhdcv5-real

在 xaga 上打通 LHDC V5 通路（原生 `codec_type=12` + 192 kHz）的单一 KernelSU 模块。

## 组成

| 部分 | 文件 | 作用 |
|---|---|---|
| **Zygisk 补丁** | `zygisk/arm64-v8a.so` | 解除 `createCodec` 的机型白名单（G1）；抬高 ABR 码率上限；让用户改过的采样率跨重连保持 |
| **开机挂载** | `post-fs-data.sh` + `payload/` | 点亮 AIDL 服务、加入 VINTF 声明、放开采样率 |
| **关闭 A2DP offload** | `post-fs-data.sh` 第 4 步 | 把 SBC/AAC 从起不来的硬件 offload 通路挪到软件通路 |

两部分缺一不可：
- 去掉 Zygisk 部分 → V5 在编解码器创建阶段被丢弃（**已实测**）
- 去掉挂载部分 → 栈仍走 HIDL，V5 被伪装成 V3

**打包约束**：`module.prop` 里的 `id` 必须与模块目录名完全一致。KernelSU 按目录名定位模块，
而 `ksud module list` 上报的是 `module.prop` 的 `id`；两者不一致时管理器会用错的 id 调用
`ksud module disable`，报 `Module xxx not found`，表现为**模块无法手动禁用**。

## ABR 码率上限（上限 = 耳机宣告的最高档位）

Zygisk 部分除机型白名单外，还把 LHDC V5 自适应档（ABR）的码率上限从 400 kbps 抬到
**耳机自己宣告的最高档位**。链路与证据见 `docs/LHDC-V5-通路-实现报告.md` §5.5：

| # | 位置（`liblhdcv5BT_enc.so`） | 改什么 |
|---|---|---|
| 1 | `.rodata` 0x2ac8 / 0x2ab0 / 0x2ae0 | 三张 ABR 阶梯表的**顶格**由 400 改为 900 kbps |
| 2 | `.bss` 0x8310 | 已到顶格的索引退一格，使顶格值也能被下发 |
| 3 | `.text` 0x4f34 / 0x50a0 | 两个站点各改一条 `b`，跳到下面两段跳板 |
| 4 | `.text` 0x6724..0x6750 | 两段跳板（44 字节，写在 PLT0 死槽里） |

第 3、4 项是本模块唯一改 `.text` 的地方：原实现把降档落点写死成表里最小的那格（48k 为
128 kbps），从顶格 900 一次就掉到底；改后**一次只降一格**（900→400→320→…）。

跳板的宿主是 `liblhdcv5BT_enc.so` **`.text` 末尾的 12 字节对齐填充 + PLT0 槽**
（`0x6724`..`0x6750`，44 字节）：该库是 `-z now` 构建（`DT_FLAGS=DF_BIND_NOW`、
`DT_FLAGS_1=DF_1_NOW`，`.rela.plt` 的 addend 全为 0），没有惰性绑定，全库也没有任何
`b`/`bl`/`b.cond` 跳进这段，因此是**死代码**。选这里的关键原因是它与**无损模式**的实现
毫无关系 —— 上一版曾把跳板写进无损提升分支（`0x50a8` 起），换支持无损的耳机会踩到，
现已完全避开。宿主选择的安全依据与写入前的指纹校验见实现报告 §5.5.7。

**上限由耳机宣告决定，模块不覆盖**：核心库本身就把目标码率夹在
`[min_bitrate_inx, max_bitrate_inx]` 之间，而 `max_bitrate_inx` 来自耳机在编解码器配置里
宣告的档位。本机耳机实测在「高音质」档宣告 7（= 900 kbps）、低音质档只宣告 5（= 400 kbps），
于是：

| 耳机宣告 | ABR 实际上限 |
|---|---|
| 7（`LHDCV5_QUALITY_HIGH`） | **900 kbps** |
| 5（`LHDCV5_QUALITY_LOW`） | 400 kbps（保持耳机许可） |

也就是说，**想要更高的 ABR 上限，请在耳机侧的音质设置里选「高音质」**。

阶梯顶格取 900 而非更高：900 在全部 5 组采样率阶梯里都存在（索引 7），且恰好等于耳机
能宣告的最高档位，请求值与许可值一致，不依赖 clamp 去回收超额的请求。

**全部为内存补丁，都在 `liblhdcv5BT_enc.so`，磁盘零写入。**
改 `.text` 的方式见实现报告 §5.5.3：本机 SELinux 下 `mprotect` 加回执行位会被 execmod
拒绝并把页留在不可执行状态（会崩），`/proc/self/mem` 也打不开；可行做法是**一步到位的
`mprotect(R|W|X)`** —— 页自始至终可执行，没有崩溃窗口。

## 安装

```bash
adb push lhdcv5-real /data/adb/modules/
adb shell su -c 'chmod 0755 /data/adb/modules/lhdcv5-real/post-fs-data.sh'
adb reboot
```

整个目录即模块内容，无需打包成 zip。

## 验证

```bash
# 挂载日志（应有 4 项 OK）
adb shell su -c 'cat /data/local/tmp/lhdcv5-aidl.log'

# 编解码器与采样率
adb shell su -c 'dumpsys bluetooth_manager | grep -oE "mCodecConfig: \{[^}]*\}" | head -1'
#   期望：codecName:LHDC V5, mCodecType:12, mSampleRate:0x20(192000)

# ABR 补丁是否落地（注意 2 MiB 日志缓冲会在开机时冲掉模块日志，
# 需在蓝牙进程重启后再看，或先 `logcat -c`）
adb shell su -c 'logcat -d -b all | grep LHDCV5A'
#   期望：ABR 表 {44100,48000,96k/192k} … 读回一致；构建已确认，启用 ABR 索引退格；
#         降档跳板 44 字节写入 0x6724..0x6750（读回一致）；
#         降档落点 -> 跳板A / 降档回写 -> 跳板B … 读回一致

# 上限是否等于耳机宣告
adb shell su -c 'logcat -d -b all | grep lhdcv5BT_enc | grep "Update Max"'
#   期望：Update Max target bitrate(LHDCV5_QUALITY_HIGH)      ← 索引 7 = 900 kbps

# ABR 实际上爬与降档（需耳机已连接且有音频在播放，约 1 分钟一条）
adb shell su -c 'logcat -d -b all | grep -a ABR_ADJ'
#   期望出现 (UP) bitrate(400)[4] to bitrate(900)[5] 这类越过 400 的记录，
#   以及 (DN) … to bitrate(400) → to bitrate(320) 这样一格一格的降档；
#   **不应**再出现 to bitrate(128)

# 模块日志被冲掉时的直接核对：从蓝牙进程内存里读补丁字节
#   （B = liblhdcv5BT_enc.so 的 load bias，见报告 §5.5.6）
adb shell su -c "dd if=/proc/\$(pidof com.android.bluetooth)/mem bs=16 count=4 \
  skip=\$((B+0x6720))/16 2>/dev/null | od -An -tx1 -v"
#   期望 0x6724 起：e91b40b9 29050051 2905891a 785b69b8 a13300d1 01faff17 …
```

完整清单见 `docs/LHDC-V5-通路-实现报告.md` §6.2 与 §5.5.6。

## 回退

### 完整卸载（推荐）

模块带 `uninstall.sh`：KernelSU 在「移除模块」后的**下次开机**、post-fs-data 阶段以 root
执行它（cwd = 模块目录），随后才删掉模块目录。它会清掉模块写在**模块目录之外**的东西。

```bash
# 在 KSU 管理器里移除 lhdcv5-real；等价命令行：
adb shell su -c 'ksud module uninstall lhdcv5-real'
adb reboot
```

卸载脚本做的事（日志只进 logcat，不落盘）：

- **删除** `persist.bluetooth.a2dp_offload.disabled` —— 它落在
  `/data/property/persistent_properties`，**与模块目录无关，删模块不会清掉它**。
  用 `ksud resetprop -p -d`；`setprop … ""` 只是持久化一个空值条目，不算删。
- 删除本模块的落地产物与中间文件：`/data/vendor/lhdcv5/`、
  `/data/misc/bluedroid/lhdcv5_sr.conf`、`/data/local/tmp/ld.new`、
  `/data/local/tmp/lhdcv5-aidl.log`。

（本项目历史上手工推入 `/data/local/tmp` 的临时文件不属于模块产物，脚本刻意不碰。）

### 只停用、不清理

```bash
adb shell su -c 'touch /data/adb/modules/lhdcv5-real/disable && reboot'
```

模块不再加载，但**什么都不清理**：`/data/vendor/lhdcv5/`、offload 属性、采样率偏好文件都还在。
想彻底回退请用上面那条。

### 不用脚本时的手工回退

```bash
adb shell su -c 'rm -rf /data/adb/modules/lhdcv5-real'
adb shell su -c 'ksud resetprop -p -d persist.bluetooth.a2dp_offload.disabled'
adb shell su -c 'rm -rf /data/vendor/lhdcv5 /data/misc/bluedroid/lhdcv5_sr.conf \
                        /data/local/tmp/ld.new /data/adb/lhdcv5.log'
```

### 什么会自己消失、什么不会

**重启即自愈，无需处理**：

- `/vendor` 下被 bind 顶替的 4 个文件 —— bind mount 只存在于内存；`/vendor` 本身是
  erofs 只读，模块从来没能写它。**因此「`/vendor` 原件 sha256 不变」这条恒成立，
  不能当作回退成功的证据。**
- `/linkerconfig/ld.config.txt` —— tmpfs，每次开机由系统重建。
- Zygisk 的内存补丁 —— 随进程消失。

**必须清（脚本已处理）**：`persist.bluetooth.a2dp_offload.disabled=true`，以及上面那些文件。

**不会自己消失但无害**：`bt_config.conf` 里 `Codecs` 列表中的 `LHDC V5`（下次 BT 启动会重写）。

卸载脚本刻意不写任何文件（日志只进 logcat：`adb logcat -d -s LHDCV5U`），
所以卸载完成后模块在磁盘上**零残留**。

### 怎么确认回退成功

```bash
# 不再有 bind 到 /vendor 的条目
adb shell 'mount | grep vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio | wc -l'   # 期望 0
# offload 回到 ROM 默认（/vendor/build.prop:435 = false）
adb shell su -c 'getprop persist.bluetooth.a2dp_offload.disabled'                          # 期望空
# 落地产物已清
adb shell su -c 'ls /data/vendor/lhdcv5'                                                   # 期望 No such file
```

**最关键的判据需要耳机连着**：准入补丁只在内存里，回退重启后
`dumpsys bluetooth_manager` 的 `mCodecsLocalCapabilities` 里应当**不再出现 LHDC V5**
（注意 `codecConfigPriorities` 里那条 `LHDC V5: 8003` 是 ROM 自带的静态表，一直在，不算）。

## 构建（可选）

`zygisk/arm64-v8a.so` 与模块内已包含，无需构建即可安装。若要重新构建：

```bash
cd zygisk-src && NDK=/path/to/android-ndk-r27d ./build.sh
```

`payload/shim.so` 与 `payload/shimsym.so` 的源码在仓库根目录的 `shim/`：

```bash
cd ../../shim && NDK=/path/to/android-ndk-r27d ./build.sh
```

> 构建脚本会自动校验两个易漏的要点：**不得依赖 `libc++_shared.so`**（会导致模块加载
> 失败且无任何日志），以及 **`HIDL_FETCH_*` / `zygisk_module_entry` 必须导出**。

## payload 说明

| 文件 | 来源 / 处理 |
|---|---|
| `android.hardware.bluetooth.audio-impl.so` | 取自 malachite 固件（AOSP-AIDL v3）；已把冗余 DT_NEEDED 之一改写指向 `shimsym.so` |
| `audio.bluetooth.default.so` | 同上（AIDL 版音频 HAL 模块） |
| `libbluetooth_audio_session_aidl_mtk.so` 等 | 同上（**含 192 kHz 支持**） |
| `real_hidl22.so` | xaga 原 `@2.2-impl.so`，DT_SONAME 已改写以避免与 shim 冲突 |
| `shim.so` / `shimsym.so` | 本项目构建 |
| `manifest.xml` | xaga 原 VINTF 清单 + AIDL 声明 |
| `bt_audio_policy.xml` | xaga 原 BT 音频策略 + `176400 192000` |

各文件的目标路径、SELinux 标签见 `post-fs-data.sh`。
