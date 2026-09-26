# D3 —— 路线设计：「栈内 V5 转换（不伪装 codec_type）」

> 任务：设计并验证「在 libbluetooth_jni.so 内提供一个 HIDL 版 `A2dpLhdcV5ToHalConfig`，
> 让 codec_type=12 在 HIDL 路径上被正确处理，不再把 12 改写成 10」这条路线。
>
> 采集方式：全程只读（adb shell 读取 / dumpsys / logcat / 本地二进制反汇编）。
> 未修改设备任何状态；未启用已停用的 `lhdcv5` 模块。
>
> 原始证据：`d:/Cache/Hyperos/lhdcv5-tr/analysis/raw/d3/d3_evidence.txt`
> 脚本：`d:/Cache/Hyperos/lhdcv5-tr/analysis/scripts/d3_{plt,any,xref,sym,sym2}.py`

---

## 0. 结论摘要

| 问题 | 结论 |
|---|---|
| (a) execmem 是否允许？ | **允许**。设备策略 `(allow appdomain self (process (execmem)))`，且 `bluetooth ∈ appdomain`。报告「bluetooth 域无 execmem 规则」**是错的**（那只是 execmod）。 |
| (a) execmod 是否允许？ | 不允许（无任何 allow）。但**新函数根本不需要它**：模块 `.so` 标签为 `system_lib_file`，而 `(allow domain system_lib_file (file (read getattr map execute open)))` 对**所有域**放行 → 编译进模块 `.so` 的函数天然可执行。 |
| (a) 「table[12] 指向我们自己的函数」可行吗？ | **不可行**，且与 execmem 无关。跳转表表项是**无符号字节**，目标 = `0x825f34 + 表项×4`，**只能向前跳 1020 字节**，物理上够不到模块代码。 |
| (a) 那注入点在哪？ | **`A2dpLhdcV3ToHalConfig` 的 GOT 槽（`0xf98d80`）**。该函数**全库只有 1 个调用点**（`0x826090`，即 table[10]/table[12] 共用的 stub），重定向它即可让 table[12] 走到我们的实现。**无需分配任何新可执行内存。** |
| (b) V5 能否完整映射到 HIDL？ | **不能**。HIDL `LhdcParameters` 实测 **8 字节 5 字段**（`sampleRate/channelMode/bitsPerSample/isLLEnabled/isLLSupported`），**无版本号、无 CIE、无码率档位、无 AR/JAS/META/Lossless**。 |
| (c) 能到什么程度？ | **只能"路由为真、载荷为伪"**。HIDL 边界的 `codecType` 对 V3/V5 **都是 `0x20`(LHDC)** —— 12 从未到达 HAL。所以「不伪装 codec_type」在 HIDL 边界上是**空操作**：V5 转换函数产出的字节与现状**逐字节相同**。 |
| (d) HAL 侧能否补丁？ | **能注入（ptrace），但不值得**。HAL 是 pid 1006 `u:r:mtk_hal_audio:s0`、PPID=1（**非 zygote 子进程 → Zygisk 无法注入**）；不过 root 所在 `u:r:ksu:s0` 被 KernelSU 设为 **permissive**，ptrace 技术可行。但 HAL 软件通路根本不读 codec 配置。 |
| (e) 相比现状多得到什么？ | **功能收益 = 0**（载荷逐字节相同）。非功能收益 ≈ 0（补丁点从 2 个 GOT 槽减到 1 个，但多出 1 个结构体偏移依赖）。 |
| (f) 该不该做？ | **不值得做**。除非目标只是"语义诚实"。V5 通路必须走 MTK AIDL（`Lhdcv5Configuration` 现成），而 AIDL 实现库在设备上不存在。 |

---

## 1. 现状复核（独立复算，全部与既有报告一致）

### 1.1 跳转表与错误分支

```
table@0x2c5620 = 00 26 46 46 4b 5a 5a 5a 5a 50 55 5a 5a 00 26 00
目标 = 0x825f34 + 表项*4   （0x825f24 adr x10,#0x825f34；0x825f28 ldrb w11；0x825f2c add x10,x10,w11,lsl#2）
  idx  9 (LHDC_V2) -> 0x50 -> 0x826074
  idx 10 (LHDC_V3) -> 0x55 -> 0x826088
  idx 12 (LHDC V5) -> 0x5a -> 0x82609c   ← 错误分支
```

错误分支 `0x82609c` 内容（复算）：

```
0x8260a8  adrp x1, #0x228000 ; add x1,x1,#0xb7e   -> 0x228b7e
          字符串 = "vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/mediatek/
                    audio_hal_interface/hidl/a2dp_encoding_hidl.cc"
0x8260b4  mov  w2, #0x167                          -> 行号 359
0x8260d8  adrp x1, #0x2b4000 ; add x1,x1,#0x5fc   -> 0x2b45fc
          字符串 = ": Unknown codec_type="
0x8260e8  ldr  w1, [sp, #0x20]                     -> 打印 codec_type
```

四要素（文件名 / 行号 359 / 函数名 / 消息）与设备日志 `a2dp_encoding_hidl.cc(359) ... Unknown codec_type=12` 全吻合。

### 1.2 分发函数的骨架（`a2dp_get_selected_hal_codec_config` @0x825ec0）

```
0x825eec  bl   bta_av_get_a2dp_current_codec        ; x19 = A2dpCodecConfig*
0x825f0c  bl   A2dpCodecConfig::getCodecConfig      ; 56 字节 sret 到 sp+0x20
0x825f10  ldr  w8,[sp,#0x20]                        ; codec_type
0x825f14  cmp  w8,#0xe ; b.hi 0x82609c              ; >14 -> 错误分支
0x825f28  ldrb w11,[x9,x8] ; br x10                 ; 跳转表分发
   ... 各 codec 分支 ...
0x826088  (idx 10 / 打补丁后的 idx 12)
0x826088  mov  x0,x20 ; mov x1,x19
0x826090  bl   A2dpLhdcV3ToHalConfig(out, cfg)      ; ★ 全库唯一调用点
0x826094  tbz  w0,#0, 0x825f44                      ; 失败 -> 返回 false
0x826098  b    0x825fdc                             ; 成功 -> 公共尾
0x825fdc  mov  x0,x19
0x825fe0  bl   A2dpCodecConfig::getTrackBitRate()
0x825fe8  str  w0,[x20,#4]                          ; out->encodedAudioBitrate = 实际码率
0x826010  bl   bta_av_co_get_encoder_effective_frame_size
0x826028  strh w8,[x20,#8]                          ; out->peerMtu
```

### 1.3 调用点统计（决定补丁最小面）

| 函数 | PLT 桩 | 调用点数 |
|---|---|---|
| `A2dpLhdcV3ToHalConfig` | 0xf4e9f0 | **1**（0x826090） |
| `A2dpLhdcV2ToHalConfig` | 0xf4ea00 | 1（0x82607c） |
| `A2dpCodecConfig::getCodecConfig` | 0xf48170 | **46** |
| `A2dpCodecConfig::getCodecSpecificConfig` | 0xf48240 | 24 |

> 现状 P2 重定向 `getCodecConfig` 的 GOT 槽，等于给这 **46 个调用点**全部加了一层间接跳转；
> 而"V5 转换"设计只需要动那 **1 个**调用点所在的 GOT 槽。

---

## 2. (a) execmem / execmod / 模块代码的可执行性

### 2.1 策略文本（设备自身，权威）

设备 **没有** `precompiled_sepolicy`（`/system/etc/selinux/` 与 `/vendor/etc/selinux/` 均无），
因此运行时策略就是由这些 CIL 在开机时编译出来的 → CIL 文本即权威策略源。

```
$ adb shell "su -c 'grep -n -E \"execmem|execmod\" /system/etc/selinux/plat_sepolicy.cil'"

871:   (typeattributeset appdomain (bluetooth ephemeral_app gmscore_app ... ))
17419: (allow appdomain self (process (execmem)))                 ← ★
10481: (allow hal_drm self (process (execmem)))
19205: (allow app_zygote self (process (execmem)))
29831: (allow webview_zygote self (process (execmem)))
30064: (allow zygote self (process (execmem)))
24573/28451/28773/28963: (neverallow {perfetto|system_server|traced|traced_probes} self (process (execmem)))
```

- `bluetooth` **在 `appdomain` 里**（第 871 行）。
- `(allow appdomain self (process (execmem)))`（第 17419 行）⇒ **`u:r:bluetooth:s0` 可以创建匿名可执行内存**。
- 没有任何 neverallow 与之冲突（neverallow 是编译期检查；策略能编译通过即说明 allow 有效）。
- 与 execmod 无关：`grep -n "^(allow bluetooth .*execmod" plat_sepolicy.cil` → **0 命中**（默认拒绝）。

> **行号同一性复核**（证明本地副本 == 设备文件）：
> ```
> $ adb shell "su -c 'sed -n \"871p;17419p;7787p\" /system/etc/selinux/plat_sepolicy.cil'"
> 871  : (typeattributeset appdomain (bluetooth ephemeral_app gmscore_app ... ))
> 7787 : (allow domain system_lib_file (file (read getattr map execute open)))
> 17419: (allow appdomain self (process (execmem)))
> ```
> 三行内容与本地副本逐字一致 ⇒ 引用可信。

> **对既有报告的纠正**：技术文档 §4.2 写「AOSP 源码策略 bluetooth.te 中该域**无 execmod / execmem 规则**」——
> 后半句错误。`execmod` 确实没有 allow；`execmem` 通过 `app_domain()` 宏（`app_domain(bluetooth)`，
> 见 `reference/aosp-src/r7/sepolicy/bluetooth.te:5`）从 `appdomain` 继承，是**放行的**。
> 这一点不影响既有实现（它选了 GOT 路线），但影响本路线的可行性判断。

### 2.2 但 execmem 根本不需要 —— 模块 `.so` 本身对所有域可执行

```
$ adb shell "su -c 'ls -Zd /data/adb/modules/lhdcv5/zygisk/arm64-v8a.so'"
u:object_r:system_lib_file:s0  /data/adb/modules/lhdcv5/zygisk/arm64-v8a.so     ← 注意不是 adb_data_file
$ adb shell "su -c 'ls -Zd /data/adb/modules'"
u:object_r:adb_data_file:s0    /data/adb/modules

$ grep -n "^(allow domain system_lib_file (file" plat_sepolicy.cil
7787: (allow domain system_lib_file (file (read getattr map execute open)))     ← ★ 所有域
```

KernelSU 把 zygisk 模块 `.so` 重新打标为 `system_lib_file`，而第 7787 行对**所有域**放行
`read/getattr/map/execute/open`。因此：

- 模块 `.so` **可以在 `u:r:bluetooth:s0` 里被 map 并执行**；
- 把新函数**编译进模块 `.so`**（构建期完成）即可，**运行期不需要 execmem、也不需要 execmod**；
- 反过来，`bluetooth` **不能**读 `/data/adb/modules/**` 目录本身（`grep "^(allow bluetooth adb_data_file"` → 0 命中），
  所以文件路径的 `dlopen` 会卡在目录搜索权限上 —— 这正是 Zygisk Next 需要代劳的原因。

### 2.3 现有实现已经证明模块代码在 bluetooth 域可执行

- 模块是标准 Zygisk 模块，走 `postAppSpecialize` → `pltHookRegister` → `pltHookCommit`
  （`module/lhdcv5/jni/module.cpp:332-400`），并把 3 个 GOT 槽改写到**模块自己的函数**
  `hooked_osi_property_get` / `hooked_get_codec_config` / `hooked_lhdc_v3_to_hal`。
- 文档 §5.1 的模块日志（`/data/adb/lhdcv5.log` 之外的运行期日志）显示三处 GOT 写入并读回成功，
  且功能端到端通过（96 kHz 实测 577,148 B/s）。
- 该日志中的 `avc: denied { execmod } scontext=u:r:bluetooth:s0 tcontext=u:object_r:system_lib_file:s0`
  来自模块自己的 execmod 探针 —— 这条 AVC 反证：**映射已经建立**（否则不会走到 mprotect 的 execmod 检查），
  即 `bluetooth` 对 `system_lib_file` 的 `map+execute` 是通的。

> **本节的结论**：新增一个函数不需要任何新权限。`execmem` 是否放行只是"备选路线是否也通"的问题，
> 而答案是**通**（§2.1）。任务描述里"若不允许，有没有替代"这一分支不需要用到。

### 2.4 附带核实：Zygisk Next 的加载形态

```
/data/adb/zygisksu/memory_type = 1        (webui: zygiskd memory-type {anonymous|default})
/data/adb/zygisksu/denylist_enforce = 2   (仅还原挂载)
```

`memory_type=anonymous` 表示模块代码以匿名内存投递。**但这条不构成本路线的必要条件**，
因为 §2.2 已经证明文件映射路线同样可行。

可观测的对照（只读）：pid 11892 `zn-zygisk-companion64`（域 `u:r:ksu:s0`）里
`/data/adb/modules/playintegrityfix/zygisk/arm64-v8a.so` 是 `r-xp` **文件映射**。
未能在任何**目标应用进程**里观测到同款映射（lhdcv5 已停用；其余已启用模块当前无对应目标进程在跑），
故"目标进程内到底是文件映射还是匿名映射"标记为**未验证**——对本路线无影响。

---

## 3. (b) V5 → HIDL 转换设计

### 3.1 全部相关结构体布局（反汇编实测，非推测）

**① `CodecConfiguration`（MTK HIDL 2.1/2.2）**

字段清单来自 AOSP `hardware/interfaces/bluetooth/audio/2.0/types.hal:225`；
偏移由 MTK 二进制反汇编交叉验证：

```c
struct CodecConfiguration {          // 偏移     验证指令
    CodecType codecType;             // 0x00     0x82a938 str w8,[x19],#0xc   (值 0x20 = LHDC)
    uint32_t  encodedAudioBitrate;   // 0x04     0x825fe8 str w0,[x20,#4]
    uint16_t  peerMtu;               // 0x08     0x826028 strh w8,[x20,#8]
    bool      isScmstEnabled;        // 0x0a     0x8263e0 ldrb w0,[x20,#0xa]
    /* pad 0x0b..0x0c */
    CodecSpecific config;            // 0x0c     0x826030 add x0,x20,#0xc
};
```

**② `CodecSpecific`（safe_union）** —— 变体成员由 hal22.so 日志字符串穷举：

```
.sbcConfig / .aacConfig / .aptxConfig / .ldacConfig / .lhdcConfig / .leAudioCodecConfig / .pcmConfig
```

**没有 `vendorConfig`，也没有 `lhdcv5Config`。** 判别值：`lhdcConfig = 4`
（APEX `vendor.mediatek.hardware.bluetooth.audio@2.1.so` 的 setter @0x31120：`cmp w8,#4`）。
布局：`_hidl_d` u8@+0x00，载荷（union）@+0x04。

**③ `LhdcParameters` = 8 字节**（setter @0x31120 复制**恰好 8 字节**到 `CodecSpecific+4`）：

```
+0x00  uint32 sampleRate          (HIDL SampleRate 枚举值，与内部位掩码同值)
+0x04  uint8  channelMode         (1=MONO, 2=STEREO)
+0x05  uint8  bitsPerSample       (1=16bit, 2=24bit, 4=32bit)
+0x06  uint8  isLLEnabled
+0x07  uint8  isLLSupported       ← 全库无人写，恒为 0
```

设备日志给出唯一权威字段清单（`artifacts/logs/a2dp_raw.log:341752`）：

```
.lhdcConfig = {.sampleRate = RATE_96000, .channelMode = STEREO, .bitsPerSample = BITS_24,
               .isLLEnabled = Disabled, .isLLSupported = Unsupported}
```

**④ `btav_a2dp_codec_config_t`（`getCodecConfig()` 返回，56 字节）**

```
+0x00 u32 codec_type        +0x18 int64 codec_specific_1
+0x04 u32 codec_priority    +0x20 int64 codec_specific_2   ← V3 转换函数只读它的 bit0
+0x08 u32 sample_rate       +0x28 int64 codec_specific_3
+0x0c u32 bits_per_sample   +0x30 int64 codec_specific_4
+0x10 u32 channel_mode      (0x14 padding)
```

（`getCodecConfig` @0x764800 从对象 `[0x58,0x90)` 整块拷贝 0x38 字节 → 大小 56 确认。
`str w8,[x19],#0xc` 之前的 `str q0` 清零 0x40 字节也与此吻合。）

**⑤ V3 转换函数只读这 5 个位置**（`0x82a8b0..0x82ab90` 全函数扫描）：

| 读自 | 偏移 | 用途 |
|---|---|---|
| `ldr w8,[sp,#0x10]` | +0x00 | codec_type，**要求 == 0xa** |
| `ldr w8,[sp,#0x18]` | +0x08 | sample_rate（掩码校验） |
| `ldr w8,[sp,#0x1c]` | +0x0c | bits_per_sample ∈ {1,2,4} |
| `ldr w9,[sp,#0x20]` | +0x10 | channel_mode ∈ {1,2} |
| `ldrb w8,[sp,#0x30]` | +0x20 | codec_specific_2 & 1 → isLLEnabled |

**`codec_priority` / `codec_specific_1` / `codec_specific_3` / `codec_specific_4` 全部被丢弃。**
且它调用了 `getCodecSpecificConfig()`（0x82a924，填 0x3c 字节缓冲到 `x29-0x50`），
**但全函数没有任何指令读取该缓冲** → **死调用**，LHDC 的 CIE（`tBT_A2DP_OFFLOAD.codec_info[]`，
起始偏移 0x1a，见 `0x7637c0 strb w8,[x20,#0x1a]`）**完全不进入 HIDL 配置**。

### 3.2 字段映射表（V5 → HIDL）

| V5 侧来源 | HIDL 目标 | 是否送达 | 说明 |
|---|---|---|---|
| `codec_type = 12` | `codecType` | ❌ **信息丢失** | V3/V5 都写 `0x20`(LHDC)，HIDL 枚举无版本位 |
| `sample_rate` (+0x08) | `lhdcConfig.sampleRate` | ✅ 原样透传 | 掩码 `0x800000008000808B`（对 `1<<(v-1)`）允许 {1,2,4,8,0x10,0x20,0x40}+特例 0x80 ⇒ **含 176400/192000**，无钳位 |
| `bits_per_sample` (+0x0c) | `lhdcConfig.bitsPerSample` | ✅ | {1,2,4} |
| `channel_mode` (+0x10) | `lhdcConfig.channelMode` | ✅ | {1,2} |
| `codec_specific_2 & 1` | `lhdcConfig.isLLEnabled` | ✅ | 仅 HIDL 记录用 |
| （无人写） | `lhdcConfig.isLLSupported` | ❌ | 恒 `Unsupported`；**这是整个结构里唯一的空闲字节** |
| `getTrackBitRate()` | `encodedAudioBitrate` | ✅ | 由**公共尾**填（0x825fe0/0x825fe8），实测 400000/900000/9999999 |
| 有效帧长 | `peerMtu` | ✅ | 0x826028，实测 660 |
| **CIE P6（采样率能力）** | — | ❌ **无字段** | 经 `getCodecSpecificConfig` 可得，HIDL 无容器 |
| **CIE P7（位深 + 码率上下限）** | — | ❌ | 同上 |
| **CIE P8（版本号 + 帧长）** | — | ❌ | ★ **V5 版本号唯一可能的载体，HIDL 无字段** |
| **CIE P9（AR/JAS/META/LL/LLESS96K/LLESS24Bit/LLESS48K）** | — | ❌ | V5 专有特性位 |
| **CIE P10（LLESSRaw）** | — | ❌ | Lossless 原始配置 |
| 帧长/MTU 控制 | `peerMtu` | 部分 | 仅 2 字节且已被"有效帧长"占用 |

### 3.3 对照：MTK AIDL 的 V5 转换函数（V5 的参考实现）

`aidl::codec::A2dpLhdcv5ToHalConfig` @`0x83fd80`（本机为不可达通路上的活代码）：

```
0x83fdd0  cmp w8,#0xc ; b.eq ...        ; ★ 接受 codec_type == 12
0x83fdd8  cmp w8,#0xa ; b.ne <fail>     ; 也接受 10
0x83fe14  mov w8,#0xb -> str w8,[x19]   ; AIDL CodecType = 11 = V5
0x83fe24  mov w8,#9   -> str w8,[x19]   ; AIDL CodecType =  9 = V3   ← ★ 版本信息被保留
0x83fe48  跳转表 @0x2c58e4 采样率 -> Hz 常量 (44100/48000/88200/96000/176400/192000/16000/24000)
0x83ffb0+ 从 tBT_A2DP_OFFLOAD 缓冲偏移 0x20.. 起读取，写入
          Lhdcv5Configuration[0x06]/[0x08]/[0x0c]/[0x10]/[0x14] 及 std::vector<uint8_t> byte[]
          （缓冲 0x1a 起 = codec_info[]，故 0x20 起 = codec_info[6] = CIE P6）
```

⇒ **AIDL 是唯一能保留 LHDC 版本 + 完整 CIE 的通路**，这也印证了 R1/R4 的结论。
但设备上 **不存在任何 AIDL 实现库**（`/vendor/lib64/hw/` 只有 HIDL impl；vintf manifest 无 `format="aidl"`）。

### 3.4 设计：栈内"V5 转换"（唯一可行形态）

**为什么不能用「table[12] → 我们的函数」**

```
0x825f24  adr  x10, #0x825f34
0x825f28  ldrb w11, [x9, x8]      ; 表项是【无符号字节】
0x825f2c  add  x10, x10, w11, lsl #2
0x825f30  br   x10
```

目标 = `0x825f34 + 表项×4`，表项 ∈ [0,255] ⇒ **只能向前跳 1020 字节**（最大 0x826330）。
模块代码在完全不同的映射里 —— **跳转表在物理上够不到**。
（复算：0x826330 落在同一个分发函数的日志尾里（`ldrb w8,[sp,#0x90]` / `bl _ZdlPv` /
`bl basic_string::append` / `bl to_string`），既不是代码洞，也不可能承载我们的实现。）

**正确形态：重定向 `A2dpLhdcV3ToHalConfig` 的 GOT 槽**

该函数**全库只有 1 个调用点**（0x826090），而该调用点正是 table[10] **和** table[12] 共用的 stub。
所以：

```
① P0  不变：GOT 0xf94428 (osi_property_get) → hooked_osi_property_get（白名单）
② P1  不变：.rodata 0x2c562c  table[12] 0x5a → 0x55（路由到 V3 stub @0x826088）
③ P2' 改：GOT 0xf98d80 (A2dpLhdcV3ToHalConfig) → hooked_lhdc_v5_to_hal
          —— 该 hook 内部【直接实现】转换，接受 codec_type ∈ {10,12}
④ 删除：GOT 0xf95940 (getCodecConfig) 重定向 + thread_local g_in_lhdc_conversion
```

`hooked_lhdc_v5_to_hal` 伪代码（约 40 行）：

```cpp
// 真实 getCodecConfig 地址：直接读 GOT 槽 0xf95940（重定位后即为真地址），
// 或 dlsym(RTLD_DEFAULT, "_ZN15A2dpCodecConfig14getCodecConfigEv")。
using get_cfg_t = CodecConfig (*)(void*);                 // 56 字节，sret
using v3_t      = bool (*)(void* out, void* cfg);

static get_cfg_t real_get_cfg = nullptr;                  // 从 GOT 读出
static v3_t      real_v3      = nullptr;                  // 从 GOT 读出（重定向前保存）

bool hooked_lhdc_v5_to_hal(void* out, void* cfg) {
    CodecConfig c = real_get_cfg(cfg);                    // ★ 不再改写任何字段
    if (c.codec_index != 10 && c.codec_index != 12)       // 只处理 LHDC V2? 否：V3/V5
        return real_v3(out, cfg);                         // 兜底（实际不会走到）

    // ---- 校验（照抄 V3 转换函数的规则，无钳位）----
    if (!sample_rate_ok(c.sample_rate))   return false;   // 掩码 0x800000008000808B / 特例 0x80
    if (!bits_ok(c.bits_per_sample))      return false;   // {1,2,4}
    if (!channel_ok(c.channel_mode))      return false;   // {1,2}

    // ---- 直接按实测布局写 HIDL 结构 ----
    *(uint32_t*)((char*)out + 0x00) = 0x20;               // codecType = LHDC
    *(uint8_t *) ((char*)out + 0x0c) = 4;                 // config._hidl_d = lhdcConfig
    struct __attribute__((packed)) P {                    // LhdcParameters, 8 字节
        uint32_t sample_rate; uint8_t ch; uint8_t bits; uint8_t ll; uint8_t llsup;
    } p { c.sample_rate, c.channel_mode, c.bits_per_sample,
          (uint8_t)(c.codec_specific_2 & 1), 0 };
    *(P*)((char*)out + 0x10) = p;                         // config.lhdcConfig
    return true;
    // encodedAudioBitrate / peerMtu 由调用方公共尾 (0x825fdc) 填，与今天完全相同
}
```

要点：

- **不需要 execmem、不需要 execmod、不需要新的可执行页** —— 全部代码在模块 `.so` 里（§2.2）。
- **不需要 HIDL setter 的地址** —— 直接按实测偏移写 8 字节即可（`LhdcParameters` 是 POD，
  且调用方已把整个 `CodecConfiguration` 清零，union 中前一活跃成员 `sbcConfig` 也是 POD，
  不存在析构/泄漏问题；这与 setter 自身的行为（`_hidl_d = 4` + 复制 8 字节）等价）。
- **`codec_type` 全程保持 12**，没有任何"伪装"。

---

## 4. (c) 严格技术边界：HIDL 上「V5」能到什么程度

### 4.1 一个必须先澄清的事实：**12 从来没有到过 HAL**

- HIDL `CodecType` 是**与版本无关的位枚举**：`SBC=1 AAC=2 APTX=4 APTX_HD=8 LDAC=0x10 LHDC=0x20`。
- `A2dpLhdcV3ToHalConfig` 写的是 `mov w8,#0x20` → `codecType = LHDC`。
- 设备日志 `.codecType = LHDC` 对 V3 与 V5 **完全一样**。

⇒ **「不伪装 codec_type」在 HIDL 边界上是空操作**：HIDL 侧看到的一直是"LHDC"这个通用值，
"伪装"只发生在**栈内部**（为了满足 `cmp w8,#0xa`）。P1+P2 伪装的是**分发与校验**，不是 HAL 的语义。

### 4.2 能做到什么 / 做不到什么

| 目标 | 可达性 | 说明 |
|---|---|---|
| 「codec_type 保留 12，且 HAL 接受」 | ✅ **可达** | 即 §3.4 的设计：HAL 收到 `codecType=0x20`（它本来也只能收到这个），栈内 12 不再被改写 |
| 「HAL 收到的字节与现状不同」 | ❌ **不可达** | V3 转换函数**零钳位、零改写**，只透传 5 个与版本无关的字段；V5 转换函数写出的字节**逐字节相同** |
| 「HAL 收到 LHDC 版本号」 | ❌ **不可达（HIDL）** | `LhdcParameters` 8 字节无版本字段；唯一空闲字节是 `isLLSupported` |
| 「HAL 收到 CIE（AR/JAS/META/Lossless/帧长/码率档位）」 | ❌ **不可达（HIDL）** | `CodecSpecific` 变体成员只有 7 个，无 V5 容器；`vendorConfig` 逃生口只有 **AIDL** 有 |
| 用 `isLLSupported` 当 V5 标记 | ⚠️ 理论可行 | 结构上唯一空闲字节。但**没有任何消费者**（见 §5.1），且语义撒谎（V5 本身支持 LL） |
| 用 `encodedAudioBitrate`/`peerMtu` 承载 V5 数据 | ❌ | 已被"实际码率"和"有效帧长"占用，且公共尾会覆写 |

### 4.3 是否必须改 HAL？

**功能上：不必；语义上：必须出新 `.hal` 才能原生送达。**

- 软件编码通路（本机实际走的）**完全不读 codec 配置**：
  - `A2dpSoftwareAudioProvider::startSession` 只查 `getDiscriminator()==0` + `IsSoftwarePcmConfigurationValid`；
  - 实测日志只有 `.pcmConfig = {...}` 被消费（R3/R7/R8 已证，本轮复算一致）。
- HIDL 侧 `lhdcConfig` **7/7 调用点全部是日志字符串拼接**（本轮独立复核）：
  ```
  hal22.so:  xref 到 ".lhdcConfig = " 的 4 处 -> 0x14344 / 0x19098 / 0x1bbe8 / 0x206a0
  session:   xref 到 ".lhdcConfig = " 的 3 处 -> 0xb188  / 0x13f50  / 0x18674
  抽查 0x14344 上下文：adrp/add 取串 -> bl 0x24460(string::append) -> bl 0x24510 —— 纯日志构造
  ```
- `audio.bluetooth.default.so` 里 **"LHDC" 字样计数 = 0**（HAL 模块与 codec 无关）。
- `audio.primary.mediatek.so` 里只有音频格式枚举名 `AUDIO_FORMAT_LHDC` / `AUDIO_FORMAT_LHDC_LL`。

⇒ 即使把 HIDL 结构塞满，**HAL 也不会因此多做任何事**。要"V5"生效，必须
**厂商出新 `.hal`（加 `lhdcv5Config`）+ 出 AIDL 实现** —— 等价于要求厂商出固件。

---

## 5. (d) HAL 侧能否做同样的内存补丁

### 5.1 HAL 进程画像（实测）

```
$ adb shell "su -c 'ps -eZ | grep -E \"bluetooth|hal_audio\"'"
u:r:mtk_hal_audio:s0   bluetooth  1006  1  android.hardware.audio.service.mediatek
u:r:bluetooth:s0       bluetooth  2688  996 com.android.bluetooth     ← PPID 996 = zygote64
```

- **PPID = 1（init 直接拉起）→ 不是 zygote 子进程 → Zygisk 结构上无法注入**
  （Zygisk 只在 `preAppSpecialize`/`postAppSpecialize` 这两个 zygote 特化点工作）。
- `mtk_hal_audio` **不在 `appdomain`**（`grep typeattributeset appdomain ... mtk_hal_audio` → 0 命中）
  ⇒ **没有 `execmem`**；`grep "mtk_hal_audio.*execmod"` → 0 命中 ⇒ **没有 `execmod`**。
  ⇒ 在该进程里既不能新建可执行页，也不能把已写过的文件映射恢复为可执行。

### 5.2 但仍然"能注入"

KernelSU 的 `u:r:ksu:s0` 被显式设为 **permissive**：

```c
// external/kernelsu/ksu_src/KernelSU-3.3.0/kernel/selinux/rules.c
87:  ksu_permissive(db, KERNEL_SU_DOMAIN);            // u:r:ksu:s0
98:  ksu_allow(db, KERNEL_SU_DOMAIN, ALL, ALL, ALL);
139: ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "execute");
```

且设备 **无 Yama**（`/proc/sys/kernel/yama/ptrace_scope` 不存在）。
⇒ 以 root（`u:r:ksu:s0`）**ptrace 任何进程、直接写其内存**在技术上可行
（`PTRACE_POKETEXT` 是内核对目标地址空间的直接写入，不经过 `mprotect`，因此**绕开 execmod/execmem**）。

### 5.3 但"能"不等于"该"

1. **收益为零**：HAL 软件通路不读 codec 配置；`lhdcConfig` 只进日志（§4.3）。
2. **设备上根本没有 AIDL 实现可补**：`vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`
   只是接口库；无任何 `IBluetoothAudioProviderFactory` AIDL 服务进程。
3. **风险极高**：pid 1006 同时承载 `audio.bluetooth.default.so`（audioserver 的 BT audio HAL module），
   崩溃会拖垮整机音频。
4. **与项目约束冲突**：需要引入 ptrace 注入器或 KPM，破坏"只读/最小改动"的既有设计。

⇒ **结论：技术上可行，实践上不值得，且无功能收益。**

---

## 6. (e) 与现有实现相比多得到什么

### 6.1 功能差异：0

逐项对照（HAL 边界，实测日志为准）：

| HAL 收到的字段 | 现状（P0+P1+P2 伪装 V3） | 「V5 栈内转换」 |
|---|---|---|
| `codecType` | `LHDC` (0x20) | `LHDC` (0x20) — **相同** |
| `encodedAudioBitrate` | 实际码率（400000/900000/9999999） | 相同（公共尾填，不受转换函数影响） |
| `peerMtu` | 660 | 相同 |
| `isScmstEnabled` | 0 | 相同 |
| `lhdcConfig.sampleRate` | 原样（含 96000/176400/192000） | 相同（V3 转换函数零钳位） |
| `lhdcConfig.channelMode` / `bitsPerSample` | 原样 | 相同 |
| `lhdcConfig.isLLEnabled` | `codec_specific_2 & 1` | 相同 |
| `lhdcConfig.isLLSupported` | `Unsupported` | 相同（无人写） |
| CIE / 版本号 | 不送达 | **仍不送达**（HIDL 无字段） |

⇒ **送到 HAL 的字节逐字节相同。** 96 kHz 保留、位深保留、码率保留 —— 与今天一致。

### 6.2 非功能差异：一增一减，净值 ≈ 0

**收益**
- 语义诚实：`codec_type` 全程为 12，不再出现"12 被临时改写成 10"。
- 补丁面收窄：从「改写 `getCodecConfig` GOT（**46 个调用点**受影响）+ 一个 thread_local 标志
  + 改写 `A2dpLhdcV3ToHalConfig` GOT」减为「只改写 `A2dpLhdcV3ToHalConfig` GOT（**1 个调用点**）」。
- 去掉一个跨函数的 thread_local 状态，少一类竞态/泄漏隐患。

**代价**
- 转换逻辑从"复用库内既有函数"变成"我们自己按硬编码偏移写结构体"：
  新增对 `out+0x0c` / `out+0x10` 两个偏移的依赖，以及 `CodecConfiguration` 字段布局的知识。
  即**把一处风险换成另一处风险**（都随 APEX 升级失效）。
- 需要自己复刻校验规则（掩码/枚举集），多一处可能写错的地方。
- 若 `A2dpLhdcV3ToHalConfig` 未来被用于 LHDC V2 之外的其他 codec，兜底逻辑要正确（本设计已兜底）。

### 6.3 判断

> **不值得做。**
> 它不解决任何用户可感知的问题（HAL 载荷不变），也不解除任何硬约束（HIDL 结构仍无 V5 字段），
> 只是把一个"内部改写 codec_type"的实现换成"内部按偏移写结构体"的实现。
> 唯一的正当理由是想让代码语义上不再出现"伪装成 V3"这一行为——属于工程洁癖，不是功能需求。
>
> 若哪天要让 HAL 携带 V5 语义，**唯一路径是 AIDL**（`Lhdcv5Configuration` 已存在且能保留版本号 + CIE），
> 而它要求：厂商 AIDL 实现库 + VINTF `format="aidl"` 声明 + service_contexts 条目 + SELinux 规则
> + `libbluetooth_audio_session_aidl.so`（设备全缺）。等价于要求厂商出固件。

---

## 7. (f) 可行性结论与前置条件清单

### 7.1 结论

| 方案 | 可行性 | 功能收益 |
|---|---|---|
| **现状：P0+P1+P2 伪装 V3** | ✅ 已实现并验证 | — |
| **栈内 V5 转换（§3.4 设计）** | ✅ **技术完全可行**，且不需要任何新 SELinux 权限 | **0** |
| table[12] → 模块新函数 | ❌ **物理不可行**（跳转表只有 +1020 字节前向可达） | — |
| HAL 进程内补丁 | ⚠️ 技术上可行（ksu permissive + ptrace），实践上不可取 | 0（HAL 不读 codec 配置） |
| 让 HAL 原生携带 V5 | ❌ 需厂商新 `.hal` + AIDL 实现 = 出固件 | 0（软件通路不消费） |
| 让 HAL 走 AIDL 通路 | ❌ 设备零 AIDL 实现（R1/R3/R6/R7 已四重否定） | 负（MTK AIDL PCM 分支硬编码 `isLowLatencyEnabled=0`） |

### 7.2 若仍要实现 §3.4，前置条件清单

| # | 条件 | 现状 | 获取方式 |
|---|---|---|---|
| C1 | 模块 `.so` 可被 `u:r:bluetooth:s0` map+execute | ✅ 满足 | 标签 `system_lib_file` + `allow domain system_lib_file (file (read getattr map execute open))`（plat CIL:7787） |
| C2 | 需要可执行内存时 `execmem` 放行 | ✅ 满足（但本设计不需要） | `allow appdomain self:process execmem`（plat CIL:17419），`bluetooth ∈ appdomain`（:871） |
| C3 | 绕过 `createCodec` 白名单 | ✅ 已有（P0） | GOT 0xf94428 重定向 |
| C4 | `table[12]` 路由到 LHDC 转换分支 | ✅ 已有（P1） | `.rodata` 0x2c562c `0x5a → 0x55` |
| C5 | `A2dpLhdcV3ToHalConfig` GOT 槽可重定向 | ✅ 满足 | 0xf98d80 在 `.got.plt`（`r--p` RELRO 段），`mprotect(RW)` 可写 |
| C6 | 新 hook 能取到真实 `getCodecConfig` | ✅ 满足 | 直接读 GOT 0xf95940（重定位后为真地址）或 `dlsym(RTLD_DEFAULT, "_ZN15A2dpCodecConfig14getCodecConfigEv")`（`.dynsym` 已导出，`st_value=0x764800`） |
| C7 | 知道 `CodecConfiguration` / `CodecSpecific` / `LhdcParameters` 偏移 | ✅ 本轮实测（§3.1） | 硬编码：`codecType@+0x00`、`_hidl_d@+0x0c`、`LhdcParameters@+0x10` |
| C8 | 身份校验（防 APEX 升级后误写） | ✅ 沿用现有三字节校验 | P0/P1/P2 原字节 `c0050054` / `5a` / `c1120054` |
| C9 | **不需要**任何 SELinux 策略改动 | ✅ | 本轮已证 |
| C10 | **不需要**任何新挂载 | ✅ | 本轮已证 |

⇒ **前置条件全部已满足**，实现成本约 1 个函数、约 40 行。**但收益为 0。**

---

## 8. 对既有结论的修正 / 新增事实

| # | 既有说法 | 本轮核实 |
|---|---|---|
| 1 | 技术文档 §4.2「bluetooth 域无 execmod / **execmem** 规则」 | **后半句错误**。execmod 无 allow（正确）；execmem **有**（`allow appdomain self:process execmem`，bluetooth ∈ appdomain）。 |
| 2 | 任务描述「table[12] 指向我们自己的函数，需要 execmem」 | 前提不成立：**跳转表只能向前跳 1020 字节**（无符号字节表项），够不到模块代码；而 V5 转换的注入点是 `A2dpLhdcV3ToHalConfig` 的 **GOT 槽**（全库仅 1 个调用点）。 |
| 3 | R3/R8「HAL 只吃 `pcmConfig`」 | **成立**，且本轮补强：`CodecConfiguration` 里 `encodedAudioBitrate` / `peerMtu` 确实被填了真值（公共尾 0x825fdc），但软件通路仍不消费。 |
| 4 | 「HIDL `lhdcConfig` 无 V5 字段」 | **成立且已量化**：`LhdcParameters` = **8 字节 / 5 字段**，唯一空闲字节是 `isLLSupported`（+0x07）。 |
| 5 | R8「`A2dpLhdcV3ToHalConfig` 的 `getCodecSpecificConfig()` 是死调用」 | **成立**（全函数扫描：无任何指令读取该 0x3c 字节缓冲）。**这是 V5 CIE 被丢弃的确切位置。** |
| 6 | 新增 | HIDL `CodecSpecific` 变体成员穷举 = `sbcConfig / aacConfig / aptxConfig / ldacConfig / lhdcConfig / leAudioCodecConfig / pcmConfig`；`lhdcConfig` 判别值 = **4**；**无 `vendorConfig`、无 `lhdcv5Config`**。 |
| 7 | 新增 | `CodecConfiguration` 精确布局（`codecType@0x00`、`encodedAudioBitrate@0x04`、`peerMtu@0x08`、`isScmstEnabled@0x0a`、`config@0x0c`），由 AOSP `types.hal:225` + 三处反汇编交叉确认。 |
| 8 | 新增 | KernelSU `u:r:ksu:s0` 为 **permissive**（`rules.c:87`）+ `allow ksu * * *` + 无 Yama ⇒ root 可 ptrace 任意进程（含 HAL）。 |
| 9 | 新增 | 模块 `.so` 标签为 `system_lib_file`（非 `adb_data_file`），`allow domain system_lib_file:file {read getattr map execute open}` ⇒ **任意域可 map+execute 模块代码**，这是"新函数可执行"的依据。 |
| 10 | 新增 | 设备**无 `precompiled_sepolicy`** ⇒ 运行时策略由 `/system/etc/selinux/*.cil` + `/vendor/etc/selinux/*.cil` 开机编译，CIL 文本即权威策略源（策略论证因此成立）。 |
| 11 | 新增 | `A2dpLhdcV3ToHalConfig` 全库**只有 1 个调用点**（0x826090）；`getCodecConfig` 有 **46 个**调用点 ⇒ 现状 P2 的 GOT 重定向面比必要的大得多。 |
| 12 | 新增 | HIDL V3 转换函数**不写** `codec_priority` / `codec_specific_1` / `codec_specific_3` / `codec_specific_4`。 |

---

## 9. 未验证项 / 已知不确定

1. **模块代码在目标进程内的映射形态**（文件映射 vs 匿名映射）：lhdcv5 已停用，其余已启用模块当前无对应目标进程在跑，只读约束下无法观测。对结论无影响（两条路线都通）。
2. **Zygisk Next `memory_type` 语义的官方描述**：二进制被混淆（1.9 MB 里仅 85 条 ≥8 字符的 ASCII 串），webui 为压缩 Vue 包，未取到人读文案；仅从 `zygiskd memory-type {anonymous|default}` 的命令行推断。
3. **KernelSU 注入的 `memfd_file` 类**：`rules.c:139-143` 有 `allow domain ksu memfd_file {execute,map,read,write,getattr}`，但 `/sys/fs/selinux/policy` 里未检出 `memfd_file` 字样（`tr`+`grep` 粗查），该类是否真实存在于本机策略**未验证**。
4. **`Lhdcv5Configuration` 字段名**：AIDL C++ 不内嵌字段名，仅能给出偏移（0x00/0x04/0x05/0x06/0x08/0x0c/0x10/0x14 + 0x18 byte[]）。
5. **`mtk_hal_audio` 的 ptrace 实测**：只做了策略推导（ksu permissive），**未实际执行**（违反只读约束）。
6. **`A2dpLhdcV2ToHalConfig` 是否也丢弃 CIE**：未逐函数扫描（对结论无影响，V2 不在目标内）。

---

## 附：本轮新增脚本

| 脚本 | 用途 |
|---|---|
| `analysis/scripts/d3_plt.py` | libbluetooth_jni 反汇编 + PLT→符号解析（`.rela.plt` 9727 条） |
| `analysis/scripts/d3_any.py` | 任意 ELF 的 VA→偏移安全反汇编（用于 hal22.so / APEX 接口库） |
| `analysis/scripts/d3_xref.py` | adrp+add 字符串交叉引用扫描 |
| `analysis/scripts/d3_sym.py` / `d3_sym2.py` | 合并 `.dynsym` + `.gnu_debugdata` 的符号查找 |

原始证据：`analysis/raw/d3/d3_evidence.txt`
本轮拉取的设备文件：`analysis/raw/d3/apex_vendor.mediatek.hardware.bluetooth.audio@2.{1,2}.so`
（仅 `adb pull`，未写入设备）
