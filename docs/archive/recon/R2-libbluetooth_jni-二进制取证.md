# R2 — libbluetooth_jni.so 二进制取证（本设备真值）

> 目标文件：`d:/Cache/Hyperos/xaga-lhdcv5/artifacts/libs/libbluetooth_jni_orig.so`
> SHA256 = `bedfcaa09b5246f4ddc610217a2a000425d21d581e59015fa6143639c9038347`（已复算，与原始一致）
> 设备：Redmi Note 11T Pro (xaga / MT6895) / HyperOS OS2.0.12.0.ULOCNXM / Android 14
> 方法：capstone 5.0.7 + pyelftools 0.33 + NDK r27d llvm-objdump/llvm-readelf/llvm-nm（交叉验证）
> 脚本目录：`d:/Cache/Hyperos/lhdcv5-tr/analysis/scripts/r2_*.py`（输出同名 `.txt`）

**地址约定**：`libbluetooth_jni.so` 的 `.text / .rodata / .plt / .got / .got.plt / .data.rel.ro` 全部满足
`sh_addr == sh_offset`，**VA 即文件偏移**。唯一例外是 `.data`（`VA = 文件偏移 + 0x1000`）与 `.bss`（NOBITS，无文件映像）。
已逐节复算确认（见 `r2_00_sanity.py`）。

---

## 0. 结论速览

| 问题 | 结论 | 强度 |
|---|---|---|
| 是否存在 HIDL 版 LHDC V5 转换函数？ | **不存在**。所有 `*hidl*` 命名空间下 **零个** 含 V5 的符号 | 已验证 |
| AIDL 版 V5 转换函数存在吗？ | **存在两套**：MTK 与 AOSP 各一 | 已验证 |
| AIDL 的 codec_type 跳转表把 12 路由到哪？ | **正确路由到 `A2dpLhdcv5ToHalConfig`** —— AIDL 通路不需要补跳转表 | 已验证 |
| HIDL/AIDL 如何选择？ | `AServiceManager_checkService()` 探测 + HIDL `getService`；**不读任何属性** | 已验证 |
| 有运行时开关能强制走 AIDL 吗？ | **没有**。需要 vendor 侧注册 AIDL 服务 | 已验证 |
| 本机为何走 HIDL？ | `/vendor/etc/vintf/manifest.xml` 只有 `format="hidl"` 的 2.1/2.2；AIDL -ndk 库在设备上**根本不存在** | 已验证 |
| 报告称 AIDL `A2dpLhdcv5ToHalConfig` 是"死代码" | **表述不准确**。它是**活代码**（`aidl::a2dp::setup_codec` 会调它），只是**所在通路不可达** | 已验证 |
| P1 跳转表内容 | 与报告**逐字节一致**；table[12]=0x5a → 错误分支 | 已验证（独立复算） |
| P0 白名单 | 5 个机型代号，**立即数编码**（不在 .rodata） | 已验证 |
| V5 除白名单外的门禁 | 至少还有 5 处（见 §7） | 已验证 |

---

## 1. 符号来源与可靠性

`.so` **没有 `.symtab`**（已 strip），但有两套可用的符号：

| 来源 | 条目数 | 覆盖 | 用途 |
|---|---|---|---|
| `.dynsym` | 17,414（FUNC+OBJECT+NOTYPE） | 仅**导出**符号（含大量 C++ 符号，此库未做可见性收敛） | 主力 |
| `.gnu_debugdata`（XZ 压缩的 mini-debuginfo） | 17,646 FUNC | **部分**函数（含匿名命名空间静态函数） | 补充 |

**关键**：两套都不完整，必须**合并**使用。
例：`(anonymous namespace)::a2dp_get_selected_hal_codec_config`（HIDL 分发函数，0x825ec0）
**只存在于 `.gnu_debugdata`**；而 `vendor::mediatek::bluetooth::audio::aidl::a2dp::setup_codec` 只存在于 `.dynsym`。

> 陷阱：`llvm-objdump` 把 0x825f0c 归属到 `hidl::a2dp::setup_codec`（0x825ae0），因为它是
> "最近的导出符号"。但 `.dynsym` 里 `setup_codec` 的 size=984 → 只到 0x825eb8，**已越界**。
> 真实归属是 0x825ec0 的匿名命名空间函数（size=7788）。**不要用 objdump 的符号归属做判断。**

复算脚本：`r2_00_sanity.py`、`r2_01_symsearch.py`、`r2_02_lhdc_syms.py`

---

## 2. 任务 (a)：LHDC 转换函数全枚举（按命名空间）

全部 `*ToHalConfig` 符号（`.dynsym`，demangle 后）。**`codec` 命名空间共 4 套**：

### 2.1 `vendor::mediatek::bluetooth::audio::hidl::codec::`（MTK HIDL）— **无 V5**

| 地址 | 大小 | 函数 |
|---|---|---|
| 0x829b50 | 1108 | `A2dpSbcToHalConfig(V2_1::CodecConfiguration*, A2dpCodecConfig*)` |
| 0x829fb0 | 856 | `A2dpAacToHalConfig` |
| 0x82a310 | 688 | `A2dpAptxToHalConfig` |
| 0x82a5c0 | 752 | `A2dpLdacToHalConfig` |
| **0x82a8b0** | **736** | **`A2dpLhdcV3ToHalConfig`** ← P2 目标 |
| **0x82ab90** | **612** | **`A2dpLhdcV2ToHalConfig`** |

### 2.2 `vendor::mediatek::bluetooth::audio::aidl::codec::`（MTK AIDL）— **有 V5**

| 地址 | 大小 | 函数 |
|---|---|---|
| 0x83ef40 | 1148 | `A2dpSbcToHalConfig(aidl::vendor::mediatek::hardware::bluetooth::audio::CodecConfiguration*, ...)` |
| 0x83f3c0 | 880 | `A2dpAacToHalConfig` |
| 0x83f730 | 720 | `A2dpAptxToHalConfig` |
| 0x83fa00 | 896 | `A2dpLdacToHalConfig` |
| **0x83fd80** | **1476** | **`A2dpLhdcv5ToHalConfig`**（小写 v！） |
| 0x840350 | 728 | `A2dpLhdcV2ToHalConfig`（大写 V） |

### 2.3 `bluetooth::audio::aidl::codec::`（AOSP AIDL）— **也有 V5**

| 地址 | 大小 | 函数 |
|---|---|---|
| 0x86fa20 | 1180 | `A2dpSbcToHalConfig(aidl::android::hardware::bluetooth::audio::CodecConfiguration*, ...)` |
| 0x86fec0 | 880 | `A2dpAacToHalConfig` |
| 0x870230 | 720 | `A2dpAptxToHalConfig` |
| 0x870500 | 896 | `A2dpLdacToHalConfig` |
| 0x870880 | 756 | `A2dpOpusToHalConfig` |
| **0x870b80** | **1600** | **`A2dpLhdcv5ToHalConfig`** |
| 0x8711c0 | 1004 | `A2dpLhdcV2ToHalConfig` |

### 2.4 `bluetooth::audio::hidl::codec::`（AOSP HIDL）— **连 LHDC 都没有**

| 地址 | 大小 | 函数 |
|---|---|---|
| 0x887f10 | 1108 | `A2dpSbcToHalConfig(android::hardware::bluetooth::audio::V2_0::CodecConfiguration*, ...)` |
| 0x888370 | 856 | `A2dpAacToHalConfig` |
| 0x8886d0 | 688 | `A2dpAptxToHalConfig` |
| 0x888980 | 752 | `A2dpLdacToHalConfig` |

> AOSP 上游 HIDL 的 a2dp codec 转换只覆盖 SBC/AAC/aptX/LDAC —— **LHDC 是 MTK 私有扩展**。
> 这解释了为什么 MTK 必须自己写一套 `vendor::mediatek::...::hidl::codec::`。

### 2.5 ★ HIDL 版 V5 是否存在 —— 否定证据

`r2_03_namespaces.py` 直接查询：**命名空间含 `hidl` 且名字含 `v5`（不分大小写）的符号 = 0 个。**

```
=== is there ANY hidl-namespace symbol mentioning V5/v5 ? ===
    (none)
```

因此：
- **HIDL 通路在二进制层面根本不存在 V5 的落点** —— 不是"表项写错"，是**没有函数**。
- 报告 §1 表格中 P1 的处理方式（把 table[12] 指向 V3 转换函数）是这个约束下的**唯一可能**做法。

### 2.6 LHDC V5 编解码器侧符号（用于任务 g）

| 地址 | 大小 | 符号 |
|---|---|---|
| 0x799130 | 244 | `A2dpCodecConfigLhdcV5Source::A2dpCodecConfigLhdcV5Source(priority)` |
| 0x799270 | 96 | `A2dpCodecConfigLhdcV5Source::init()` |
| 0x7992d0 | 8 | `A2dpCodecConfigLhdcV5Source::useRtpHeaderMarkerBit() const` |
| 0x7992e0 | 8560 | `A2dpCodecConfigLhdcV5Base::setCodecConfig(...)` |
| 0x79b490 | 884 | `A2dpCodecConfigLhdcV5Base::setPeerCodecCapabilities(...)` |
| 0x7a3990 | 1552 | `A2DP_VendorLoadEncoderLhdcV5()` |
| 0x7a4260 | 2516 | `a2dp_vendor_lhdcv5_encoder_init(...)` |
| 0x798da0 | 96 | `A2DP_VendorInitCodecConfigLhdcV5(AvdtpSepConfig*)` |
| 0x798d90 | 12 | `A2DP_VendorCodecIndexStrLhdcV5Sink()` ← **存在 Sink 变体** |
| 0x7990d0 | 96 | `A2DP_VendorInitCodecConfigLhdcV5Sink(AvdtpSepConfig*)` |

（完整 203 个含 lhdc 的符号见 `r2_02_lhdc_syms.txt`）

---

## 3. 任务 (b)：HIDL 与 AIDL 两套 a2dp_encoding 并存

**是的，两套都在同一个 .so 里，而且是 MTK 与 AOSP 各一套、共 4 套实现。**

| 实现 | 符号 | 地址 | 大小 |
|---|---|---|---|
| **MTK HIDL** | `vendor::mediatek::bluetooth::audio::hidl::a2dp::setup_codec()` | 0x825ae0 | 984 |
| | `(anonymous namespace)::a2dp_get_selected_hal_codec_config(vendor::mediatek::hardware::bluetooth::audio::V2_1::CodecConfiguration*)` | **0x825ec0** | **7788** |
| **MTK AIDL** | `vendor::mediatek::bluetooth::audio::aidl::a2dp::setup_codec()` | **0x8378f0** | **1800** |
| **AOSP HIDL** | `bluetooth::audio::hidl::a2dp::setup_codec()` | 0x87edb0 | 7388 |
| **AOSP AIDL** | `bluetooth::audio::aidl::a2dp::setup_codec()` | 0x862750 | 2232 |
| 通用分发（MTK） | `vendor::mediatek::bluetooth::audio::a2dp::setup_codec()` | 0x824f90 | 80 |
| 通用分发（AOSP） | `bluetooth::audio::a2dp::setup_codec()` | 0x861c10 | 52 |

### 3.1 关键函数地址

| 函数 | 地址 | 说明 |
|---|---|---|
| `A2dpCodecConfig::createCodec(...)` | **0x763280** (824) | P0 门禁所在 |
| `A2dpCodecConfig::getCodecConfig()` | **0x764800** (92) | P2 重定向目标；返回结构体首字段 = codec_type |
| `A2DP_CodecIndexStr(...)` | 0xf48330 (PLT) | 日志用 |
| `A2dpCodecs::getCodecConfigAndCapabilities(...)` | 0x768be0 (976) | |
| `A2dpCodecs::init()` | 0x766334 附近 | 读 offload 属性 |

### 3.2 ★ AIDL 侧没有独立的 `a2dp_get_selected_hal_codec_config`

对每个 `*ToHalConfig` 做 GOT→PLT→BL 调用者追踪（`r2_08_aidl_path.py`），**每个函数只有 1 个调用点**：

| 被调函数 | GOT 槽 | 唯一调用点 | 所属函数 |
|---|---|---|---|
| `hidl::codec::A2dpLhdcV3ToHalConfig` | 0xf98d80 | 0x826090 | `(anon)::a2dp_get_selected_hal_codec_config` |
| `hidl::codec::A2dpLhdcV2ToHalConfig` | 0xf98d88 | 0x82607c | 同上 |
| `hidl::codec::A2dpLdacToHalConfig` | 0xf98d78 | 0x826068 | 同上 |
| **`aidl::codec::A2dpLhdcv5ToHalConfig`（MTK）** | 0xf98ac0 | **0x837a8c** | **`aidl::a2dp::setup_codec`** |
| `aidl::codec::A2dpLhdcV2ToHalConfig`（MTK） | 0xf98ac8 | 0x837b0c | `aidl::a2dp::setup_codec` |
| **`bluetooth::audio::aidl::codec::A2dpLhdcv5ToHalConfig`（AOSP）** | 0xf994a8 | **0x862928** | **`bluetooth::audio::aidl::a2dp::setup_codec`** |

**即：AIDL 版把 codec_type 分发直接内联在 `setup_codec()` 里（用跳转表 / if-else 链），
没有单独的 `a2dp_get_selected_hal_codec_config` 函数。** 报告若按函数名搜索会漏掉这一点。

### 3.3 报告勘误

> 报告（实现文档 §1）称 AIDL 版 V5 代码是"**死代码**"。
>
> **不准确。** `A2dpLhdcv5ToHalConfig` 是**活代码**：`aidl::a2dp::setup_codec` 的
> codec_type 跳转表 index 10 与 12 都指向它。它只是**所在通路（AIDL）在本机不可达**。
> 区分"死代码"与"不可达通路"对方案设计有实际影响 —— 后者意味着**只要通路打通，转换函数现成可用**。

---

## 4. 任务 (c)：P1 跳转表独立复算

### 4.1 分发代码（capstone 与 llvm-objdump 双工具一致）

```
0x00825f0c  bl      #0xf48170            ; A2dpCodecConfig::getCodecConfig@plt
0x00825f10  ldr     w8, [sp, #0x20]      ; w8 = codec_type
0x00825f14  cmp     w8, #0xe
0x00825f18  b.hi    #0x82609c            ; >14 → 错误分支
0x00825f1c  adrp    x9, #0x2c5000
0x00825f20  add     x9, x9, #0x620       ; x9 = 0x2c5620  跳转表基址
0x00825f24  adr     x10, #0x825f34      ; x10 = anchor
0x00825f28  ldrb    w11, [x9, x8]        ; table[codec_type]
0x00825f2c  add     x10, x10, w11, lsl #2
0x00825f30  br      x10
0x00825f34  mov     x0, x20              ; ← anchor：表项 0 的落点
```

- 所属函数：`(anonymous namespace)::a2dp_get_selected_hal_codec_config` @ **0x825ec0**（size 7788）
- 编码细节：`b.hi` 在 0x825f18；`ldrb` 原始字 `3868692b`；`add` 原始字 `8b0b094a`；`br` 原始字 `d61f0140`

### 4.2 表内容（**独立复算，未照抄报告**）

```
文件偏移 0x2c5620，15 字节：
00 26 46 46 4b 5a 5a 5a 5a 50 55 5a 5a 00 26
 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14     ← 索引 = codec_type
```
与报告**逐字节一致**（`r2_00_sanity.py` 独立读取确认）。

### 4.3 解码（目标 = `0x825f34 + 值×4`，用 PLT→GOT→`.rela.plt` 符号对撞得真实函数名）

| idx | codec | 表项 | 目标 | 实际调用 |
|---|---|---|---|---|
| 0 | SBC | `0x00` | 0x825f34 | `hidl::codec::A2dpSbcToHalConfig` |
| 1 | AAC | `0x26` | 0x825fcc | `hidl::codec::A2dpAacToHalConfig` |
| 2 | aptX | `0x46` | 0x82604c | `hidl::codec::A2dpAptxToHalConfig` |
| 3 | aptX | `0x46` | 0x82604c | 同上 |
| 4 | LDAC | `0x4b` | 0x826060 | `hidl::codec::A2dpLdacToHalConfig` |
| 5–8 | — | `0x5a` | 0x82609c | **错误分支** |
| 9 | LHDC_V2 | `0x50` | 0x826074 | `hidl::codec::A2dpLhdcV2ToHalConfig` |
| 10 | LHDC_V3 | `0x55` | 0x826088 | `hidl::codec::A2dpLhdcV3ToHalConfig` |
| 11 | — | `0x5a` | 0x82609c | **错误分支** |
| **12** | **LHDC V5** | **`0x5a`** | **0x82609c** | **错误分支 ← 阻塞点，确认** |
| 13 | — | `0x00` | 0x825f34 | SBC（回落到 anchor） |
| 14 | — | `0x26` | 0x825fcc | AAC（回落） |

### 4.4 错误分支 0x82609c —— 与设备日志精确对上

```
0x0082609c  mov     w0, #2
0x008260a0  bl      #0xf3e190              ; logging::ShouldCreateLogMessage
0x008260a8  adrp    x1, #0x228000
0x008260ac  add     x1, x1, #0xb7e         ; → 0x228b7e
0x008260b4  mov     w2, #0x167             ; ← 359！
0x008260c8  adrp    x1, #0x241000
0x008260cc  add     x1, x1, #0xd00         ; → 0x241d00
0x008260d8  adrp    x1, #0x2b4000
0x008260dc  add     x1, x1, #0x5fc         ; → 0x2b45fc
```

| 地址 | 字符串 |
|---|---|
| 0x228b7e | `vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/mediatek/audio_hal_interface/hidl/a2dp_encoding_hidl.cc` |
| 0x241d00 | `a2dp_get_selected_hal_codec_config` |
| 0x2b45fc | `: Unknown codec_type=` |

`w2 = 0x167 = 359` 与设备日志 `[ERROR:a2dp_encoding_hidl.cc(359)] a2dp_get_selected_hal_codec_config: Unknown codec_type=12`
**文件名 / 行号 / 函数名 / 消息四要素全部吻合** —— 根因定位正确。

复算脚本：`r2_04a_bytes.py`、`r2_05_tables.py`、`r2_06_resolve.py`、`r2_07_plt_names.py`、`r2_10_all_tables.py`

---

## 5. 任务 (d)：全部 codec_type 跳转表清单

用 capstone 操作数（**非手写位掩码**）扫描整个 `.text`（2,726,936 条指令），
匹配 6 指令分发惯用式 `adrp;add;adr;ldrb;add lsl#2;br`，共命中 **572 处 / 509 个不同表基址**。
其中属于 a2dp codec 分发的是：

| # | 通路 | 表地址 | 表项数 | 所在函数 | [12] 行为 |
|---|---|---|---|---|---|
| 1 | **HIDL MTK** | **0x2c5620** | 15 | `(anon)::a2dp_get_selected_hal_codec_config` @0x825ec0 | **`0x5a` → 错误分支** |
| 2 | **AIDL MTK** | **0x2c577d** | 15 | `aidl::a2dp::setup_codec` @0x8378f0 | **`0x3e` → `A2dpLhdcv5ToHalConfig` ✔** |
| 3 | **AOSP HIDL** | **0x2c5cea** | 15 | `bluetooth::audio::hidl::a2dp::setup_codec` @0x87edb0 | `0x5d` → 错误分支 |
| 4 | **AOSP AIDL** | **无跳转表** | — | `bluetooth::audio::aidl::a2dp::setup_codec` @0x862750 | if/else 链，0x862928 直接调 V5 |

### 5.1 AIDL MTK 表 0x2c577d 全解码（**本任务最重要的发现**）

分发代码：
```
0x00837968  ldur    w8, [x29, #-0x70]     ; codec_type
0x0083796c  cmp     w8, #0xe
0x00837970  b.hi    #0x837aac
0x00837974  adrp    x9, #0x2c5000
0x00837978  add     x9, x9, #0x77d       ; x9 = 0x2c577d
0x0083797c  adr     x10, #0x83798c
0x00837980  ldrb    w11, [x9, x8]
0x00837984  add     x10, x10, w11, lsl #2
0x00837988  br      x10
```

表内容 `00 34 39 39 43 48 48 48 48 5e 3e 48 3e 00 34`：

| idx | codec | 表项 | 目标 | 实际调用 |
|---|---|---|---|---|
| 0 | SBC | `0x00` | 0x83798c | `aidl::codec::A2dpSbcToHalConfig` |
| 1 | AAC | `0x34` | 0x837a5c | `aidl::codec::A2dpAacToHalConfig` |
| 2,3 | aptX | `0x39` | 0x837a70 | `aidl::codec::A2dpAptxToHalConfig` |
| 4 | LDAC | `0x43` | 0x837a98 | `aidl::codec::A2dpLdacToHalConfig` |
| 5–8 | — | `0x48` | 0x837aac | **错误分支** |
| 9 | LHDC_V2 | `0x5e` | 0x837b04 | `aidl::codec::A2dpLhdcV2ToHalConfig` |
| **10** | **LHDC_V3** | **`0x3e`** | **0x837a84** | **`aidl::codec::A2dpLhdcv5ToHalConfig`** |
| 11 | — | `0x48` | 0x837aac | **错误分支** |
| **12** | **LHDC V5** | **`0x3e`** | **0x837a84** | **`aidl::codec::A2dpLhdcv5ToHalConfig`** ✔ |
| 13 | — | `0x00` | 0x83798c | SBC（回落） |
| 14 | — | `0x34` | 0x837a5c | AAC（回落） |

反汇编验证（0x837a84 块）：
```
0x00837a84  add     x0, sp, #0x20
0x00837a88  mov     x1, x20
0x00837a8c  bl      #0xf4e470        ; aidl::codec::A2dpLhdcv5ToHalConfig
0x00837a90  tbnz    w0, #0, #0x837b14
0x00837a94  b       #0x837b7c
```

**结论：AIDL 通路里 codec_type=12 已经被正确路由，无需任何补丁。**
且 AIDL MTK 侧**没有** V3 转换函数（符号表确认），所以 index 10（V3）也指向 V5 转换函数
—— 说明 MTK 认为 V5 的 `Lhdcv5Configuration` 结构足以承载 V3 配置。

### 5.2 AOSP HIDL 表 0x2c5cea（对照，证明 HIDL 侧无 LHDC）

`00 53 58 58 73 5d 5d 5d 5d 5d 5d 5d 5d 00 53` —— 索引 5..12 **全部** `0x5d` → 错误分支。
即 AOSP HIDL 连 LHDC V2/V3 都没有。

### 5.3 同函数内的其他（非 codec_type）跳转表

用同一分发惯用式但索引不同，**不是** codec 分发，列出以免误判：

| 表地址 | 所在函数 | 索引 | 项数 |
|---|---|---|---|
| 0x2c562f | `(anon)::a2dp_get_selected_hal_codec_config` | w0 | 33 |
| 0x2c5650 | 同上 | w8 | 5 |
| 0x2c5670 | 同上 | w0 | 5 |
| 0x2c568c | 同上 | w0 | 5 |
| 0x2c5cf9 | `bluetooth::audio::hidl::a2dp::setup_codec` | w0 | 17 |
| 0x2c5d0a / 0x2c5d1e / 0x2c5d3a | 同上 | w8/w0 | 4/5/5 |

复算脚本：`r2_05_tables.py`（扫描器）、`r2_11_tables_by_fn.py`、`r2_12_aosp_tables.py`

---

## 6. 任务 (e)：HIDL/AIDL 选择逻辑（HalVersionManager）

### 6.1 存在两套

| 命名空间 | ctor | GetHalVersion | GetHalTransport | GetProvidersFactory_2_1 / _2_0 | instance_ptr |
|---|---|---|---|---|---|
| `vendor::mediatek::bluetooth::audio::` | 0x861370 (1284) | 0x860d90 | 0x860de0 | 0x860ef0 / 0x861120 | 0xff42d8 (.bss) |
| `bluetooth::audio::`（AOSP） | 0x87cb70 (948) | 0x87c750 | 0x87c7a0 | 0x87c800 / 0x87c9b0 | 0xff4468 (.bss) |

设备日志前缀是 `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default`
（MTK 私有名），且源码路径为
`vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/mediatek/audio_hal_interface/hal_version_manager.cc`
→ **本机走的是 MTK 那套**。

### 6.2 选择依据：**servicemanager 探测 + HIDL getService，不读任何属性**

MTK ctor 控制流（分支目标已手工反解码验证，见 `r2_16_halver_logs.py`）：

```
0x8613a8  log(INFO, line 141) "HalVersionManager: aidl " + <name@0xff42a8>
0x861410  strh wzr, [x19,#0x28]        ; hal_version_ = 0, hal_transport_ = 0
0x861424  bl AServiceManager_checkService(<name@0xff42a8>)
0x861428  cbz x0, #0x861534            ; 未注册 → 探测第 2 个 AIDL 名
0x86142c  mov w8,#3 ; strb w8,[x19,#0x28]   ; hal_version_ = 3
0x861434  log(INFO, line 155) "HalVersionManager: hidl " + "...@2.2::IBluetoothAudioProvidersFactory"
0x861488  bl android::hardware::defaultServiceManager1_2()
          ... HIDL IBluetoothAudioProvidersFactory::getService() ...
0x861534  bl AServiceManager_checkService(<name@0xff42c0>)
0x861550  cbz x0, #0x861434            ; 未注册 → 走 HIDL
0x861554  mov w8,#0x404 ; strh w8,[x19,#0x28]  ; hal_version_=4, hal_transport_=4
0x86155c  b #0x861844                  ; 返回
```

### 6.3 两个 AIDL 服务名（静态初始化，`_GLOBAL__sub_I_hal_version_manager.cc` @0x8618f0）

```
0x861914  adrp x9,#0xf8e000 ; ldr x9,[x9,#0x860]   ; x9 = *(0xf8e860)
0x861920  ldr x1,[x9]                                ; 基名
0x861934  adrp x1,#0x27c000 ; add x1,x1,#0x342       ; "/default"
0x861958  adrp x8,#0xff4000 ; add x8,x8,#0x2a8       ; → .bss 0xff42a8
```
同样流程第二遍用 GOT 0xf8e898 → `.bss 0xff42c0`。

GOT 槽由 `.rela.dyn` 重定位指向（`llvm-readelf -r` 读出）：

| GOT 槽 | 重定位目标符号 |
|---|---|
| 0xf8e860 | `_ZN4aidl6vendor8mediatek8hardware9bluetooth5audio30IBluetoothAudioProviderFactory10descriptorE` |
| 0xf8e898 | `_ZN4aidl7android8hardware9bluetooth5audio30IBluetoothAudioProviderFactory10descriptorE` |

即两个服务名 = AIDL `descriptor` 字面量 + `"/default"`：
- **AIDL 探测 #1**：`vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` → `hal_version_ = 3`
- **AIDL 探测 #2**：`android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` → `hal_version_ = 4, hal_transport_ = 4`
- 都失败 → HIDL 分支：`vendor.mediatek...@2.2` / `@2.1`，`android...@2.1` / `@2.0`

（`descriptor` 字面量本身不在本 `.so`，由 AIDL -ndk 库提供；但设备日志已打印出实际名字，与该推断一致。）

### 6.4 GetHalTransport 的映射常量

```
0x860e18  mov  x9, #0x300
0x860e1c  movk x9, #0x203, lsl #16
0x860e24  movk x9, #4,     lsl #32      ; x9 = 0x00000004_02030300
0x860e20  cmp  x20, #5
0x860e28  lsr  x8, x9, x8               ; x8 = hal_version_ * 8
0x860e2c  csel w0, w8, wzr, lo
```
→ 版本 0→0, 1→3, 2→3, 3→2, 4→4。

### 6.5 本机实际结果（日志证据）

```
I/droid.bluetooth: [INFO:hal_version_manager.cc(141)] HalVersionManager: aidl vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default
I/droid.bluetooth: [INFO:hal_version_manager.cc(155)] HalVersionManager: hidl vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory
```
（`artifacts/logs/a2dp_raw.log:928043-928044`、`bt_log_full.txt:4992-4994`、`lhdc_param.log:8239-8240`）

line 141 的日志在 `checkService` **之前**无条件打印，line 155 的日志只在两个 AIDL 探测都失败后才打印。
**两条都出现 ⇒ 两个 AIDL 探测均失败 ⇒ 选中 HIDL 2.2。** 与报告一致。

### 6.6 设备侧独立佐证（只读 adb）

```
$ adb shell su -c 'grep -c format="aidl" /vendor/etc/vintf/manifest.xml'
0
$ adb shell su -c 'grep -B3 -A8 bluetooth /vendor/etc/vintf/manifest.xml'
    <hal format="hidl">
        <name>android.hardware.bluetooth.audio</name>
        <transport>hwbinder</transport>
        <version>2.1</version>
        <fqname>@2.1::IBluetoothAudioProvidersFactory/default</fqname>
    </hal>
    <hal format="hidl">
        <name>vendor.mediatek.hardware.bluetooth.audio</name>
        <transport>hwbinder</transport>
        <version>2.2</version>
        <fqname>@2.2::IBluetoothAudioProvidersFactory/default</fqname>
    </hal>
$ adb shell su -c 'ls /vendor/lib64/ | grep -i bluetooth.audio'
android.hardware.bluetooth.audio@2.0.so
android.hardware.bluetooth.audio@2.1.so
libbluetooth_audio_session.so
libbluetooth_audio_session_mediatek.so
vendor.mediatek.hardware.bluetooth.audio@2.1.so
vendor.mediatek.hardware.bluetooth.audio@2.2.so
$ adb shell su -c 'ls /vendor/lib64/vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so'
ls: ...: No such file or directory
$ adb shell su -c 'ls /system/lib64/android.hardware.bluetooth.audio-V3-ndk.so'
ls: ...: No such file or directory
```

**vendor 侧完全没有 AIDL 实现**：无 VINTF `format="aidl"` 声明、无 `*-V1-ndk.so` / `*-V3-ndk.so`、
无 AIDL 服务注册。报告 §4 的"接口代次断层"结论**成立**。

复算脚本：`r2_13_halversion.py`、`r2_14_halver_detail.py`、`r2_16_halver_logs.py`、
`r2_17_service_names.py`、`r2_18_static_init.py`、`r2_19_names_resolve.py`

---

## 7. 任务 (f)：有没有运行时开关能强制走 AIDL？

### 7.1 结论：**没有**

- **HalVersionManager ctor 内不调用任何属性读取函数**（`r2_17_service_names.py` §4 逐指令扫描 `osi_property_get` / `__system_property_get` / `*prop*`，输出为空）。
- 选择逻辑**只有** `AServiceManager_checkService()` 与 HIDL `getService()` 两条探测路径。
- 因此**不存在**"改个属性就能切 AIDL"的开关。

### 7.2 要让栈选 AIDL，必须做到（全在 vendor 侧，非运行时）

1. 提供 AIDL 实现库 `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`（或 AOSP 的 `android.hardware.bluetooth.audio-V3-ndk.so`）
2. 在 `/vendor/etc/vintf/manifest.xml` 增加对应的 `format="aidl"` HAL 声明
3. 由 vendor 侧 init 服务把 `...IBluetoothAudioProviderFactory/default` 注册到 servicemanager

这三件事都要求修改 **vendor 分区**并重新签名/过 AVB —— 与项目"不改挂载、不改 APEX"的约束冲突。

### 7.3 确实存在的 LHDC 相关属性（**都不是**通路选择器）

在 `.so` 内被 `osi_property_get` 实际读取的（`r2_20_gates.py` / `r2_21_lhdc_gate.py`）：

| 属性 | 读取点 | 作用 |
|---|---|---|
| `vendor.bluetooth.lhdc_codec.supported` | `btif_lhdc_codec_is_supported()` @0xc417d8 | 平台开关；`strcmp(buf,"true")==0` |
| `persist.bluetooth.lhdc_codec.enabled` | `BtifAvSource::Init` @0x6ec4c0 | 用户开关 |
| `persist.bluetooth.a2dp.lhdc.whitelist` | `BtaAvCo::SelectSourceCodec` @0x692e30；`avdt_ccb_hdl_discover_cmd` @0x7b2a40 | **按对端设备**的白名单 |
| `persist.bluetooth.lhdcrawsize` | `open_next_lhdc_raw_file` @0x7a0d44 | 调试 raw dump |
| `persist.bluetooth.a2dp_offload.cap` | `A2dpCodecs::init` @0x766884 | offload 能力掩码 |
| `ro.bluetooth.a2dp_offload.supported` | `A2dpCodecs::init` @0x766334 / 0x766348；`ConfigInterfaceImpl::isA2DPOffloadEnabled` @0x53208c | offload 总开关 |

> 注意：报告附录 A 提到的 `persist.bluetooth.lhdc_codec.enabled`、`vendor.bluetooth.lhdc_codec.supported`、
> `persist.bluetooth.a2dp.lhdc.whitelist` 三个属性**确实存在**，已被本任务在二进制中定位到读取点。
> 但它们只影响"**LHDC 是否启用**"，**不影响 HIDL/AIDL 通路选择**。

---

## 8. 任务 (g)：createCodec 白名单以外的其他 LHDC V5 门禁

### 8.1 P0 白名单 —— 独立验证（0x763280，824 B）

```
0x763428  adrp x0,#0x260000 ; add x0,x0,#0xc62   → "ro.product.name"
0x763434  adrp x2,#0x22b000 ; add x2,x2,#0xc67   → ""（默认值）
0x76343c  mov  x1, sp                            → 栈上缓冲区
0x763450  bl   osi_property_get
0x763454  ldr  w8, [sp]                          ; 前 4 字节
0x763458  mov  w10, #0x6f63                      ; "co"
0x76345c  ldrh w9, [sp,#4]
0x763460  movk w10, #0x6f72, lsl #16             ; w10 = "coro"
0x763464  cmp  w8, w10
0x763468  mov  w8, #0x74                          ; 't'
0x76346c  ccmp w9, w8, #0, eq
0x763470  b.eq #0x763528                          ; → "LHDCV5 matches"
0x763474  mov x9,#0x7564 ; movk #0x6863<<16 ; movk #0x6d61<<32 ; movk #0x70<<48   ; "duchamp"
0x76348c  b.eq #0x763528
0x763490..0x7634b0  "zircon"
0x7634b4..0x7634d4  "rothko"
0x7634d8..0x7634fc  "malachite"
0x763500  ... log "%s: %s: LHDCV5 not matches " ; 0x763524 b #0x763584（返回 nullptr）
0x763528  ... log "%s: %s: LHDCV5 matches " ; new A2dpCodecConfigLhdcV5Source
```

- 白名单 = **`corot` / `duchamp` / `zircon` / `rothko` / `malachite`**，与报告一致。
- 5 个名字全部用 `mov/movk` **立即数拼出**，**不在 `.rodata`** → `strings`/`grep` 搜不到（报告此点正确）。
- `b.eq` 原始字节 `c0 05 00 54` @0x763470 —— 与报告一致。

### 8.2 ★ 白名单之外的第二个 createCodec 门禁：`init()`

```
0x76354c  bl   operator new(0x1e8)
0x76355c  bl   A2dpCodecConfigLhdcV5Source::A2dpCodecConfigLhdcV5Source(priority)
0x763560  ldr  x8,[x20] ; ldr x8,[x8,#0x40] ; blr x8   ; ← 虚调用 vptr+0x40
0x763570  tbnz w0, #0, #0x763588                        ; true → 返回对象
0x763574  ldr  x8,[x20] ; ldr x8,[x8,#8] ; blr x8       ; ← vptr+0x08 = deleting dtor
0x763584  mov  x20, xzr                                  ; 返回 nullptr
```

用 `.rela.dyn`（Android packed RELA，需 `llvm-readelf -r` 才读得到）重建 `A2dpCodecConfigLhdcV5Source` 虚表
（`_ZTV27A2dpCodecConfigLhdcV5Source` @0xf6c330，vptr = +0x10 = 0xf6c340）：

| vptr+off | 目标 | 符号 |
|---|---|---|
| +0x00 | 0x799230 | `~A2dpCodecConfigLhdcV5Source()` D1 |
| +0x08 | 0x799240 | `~A2dpCodecConfigLhdcV5Source()` D0（deleting） |
| +0x10 | 0x7992d0 | `useRtpHeaderMarkerBit() const` |
| +0x28 | 0x7992e0 | `A2dpCodecConfigLhdcV5Base::setCodecConfig` |
| +0x30 | 0x764b20 | `A2dpCodecConfig::setCodecUserConfig` |
| +0x38 | 0x79b490 | `A2dpCodecConfigLhdcV5Base::setPeerCodecCapabilities` |
| **+0x40** | **0x799270** | **`A2dpCodecConfigLhdcV5Source::init()`** |
| +0x48 | 0x764780 | `A2dpCodecConfig::isValid() const` |
| +0x50 | 0x7a6640 | `debug_codec_dump(int)` |

即 createCodec 构造后要过 **`init()`**：
```
0x79927c  ldr x8,[x0] ; ldr x8,[x8,#0x48] ; blr x8   ; isValid()
0x799288  tbz w0,#0, 0x7992c0                        ; false → return 0
0x79928c  bl  A2DP_VendorLoadEncoderLhdcV5
0x799290  tbz w0,#0, 0x79929c                        ; 加载失败 → log 后 return 0
0x799294  mov w0,#1
```
→ **`init() = isValid() && A2DP_VendorLoadEncoderLhdcV5()`**。
`A2DP_VendorLoadEncoderLhdcV5` @0x7a3990 构造两个字符串后调 `A2DP_VendorCodecLoadExternalLib`：
- 库名 `liblhdcv5BT_enc.so`（0x2a191b）
- 编码器接口名 `LHDCv5_Encoder`（0x20ee38）

并把句柄缓存到 `0xffdd500`（首次非零即直接返回 true）。
**若 V5 编码器库缺失/加载失败，即使白名单命中也会被丢弃。**

### 8.3 V5 编解码器索引 = 12（与 HAL codec_type 同值）

`A2dpCodecConfigLhdcV5Source` ctor @0x799148-0x799180 在栈上拼出 std::string 与索引：
- `w1 = #0xc` = **12** → `BTAV_A2DP_CODEC_INDEX_SOURCE_LHDC_V5`
- 名字字节：`0x4344484c`→"LHDC"，`0x35562043`→"C V5"，长度 7 → **"LHDC V5"**

> 即 codec **index** 与 HAL **codec_type** 同为 12。这与 `A2dpCodecConfig::getCodecConfig()` 返回结构体
> 首字段（被 P1 表索引、被 V3 转换函数 `cmp w8,#0xa` 校验）是同一个值 —— 报告 §3 的结构体布局推断成立。

### 8.4 LHDC 启用/禁用链（`BtaAvCo` / `BtifAvSource`）

**`BtifAvSource::Init` @0x6ec4c0 附近**读取三个量并打一条日志（字符串 @0x207d34）：
```
'%s: %s: a2dp_offload_enabled_=%d, User: a2dp_lhdc_codec.enabled=%d, Platform: lhdc_codec.supported=%d'
```
- `persist.bluetooth.lhdc_codec.enabled` @0x6ec4c0
- `a2dp_offload_enabled_`
- `vendor.bluetooth.lhdc_codec.supported`（经 `btif_lhdc_codec_is_supported()`）

**`BtaAvCo::ProcessSourceGetConfig` @0x6913d0 区域**：
```
0x69141c  bl  btif_av_get_lhdc_codec_state()
0x691420  tbnz w0,#0, #0x6914e4          ; LHDC 状态非 0 → 不禁用
0x691424  and w8, w20, w23
0x691428  cbz w8, #0x6914e4
0x69145c  ... log '%s: disable %s LHDC codec'   （字符串 @0x20df93）
```
`btif_av_get_lhdc_codec_state()` @0x6ea840 / `btif_av_set_lhdc_codec_state(bool)` @0x6ea830 是一对
全局状态读写（各 16 B），**运行时可被上层翻转**。

**`BtaAvCo::SelectSourceCodec(BtaAvCoPeer*)`**：`persist.bluetooth.a2dp.lhdc.whitelist`（@0x2403a6）
在 0x692e30-0x692e34 载入，用于**按对端 MAC**过滤 LHDC。
同样逻辑也出现在 `avdt_ccb_hdl_discover_cmd` @0x7b2a40。

> ⚠️ **这是"协商层"的第二道按设备门禁**：即便 P0 让 V5 进入能力列表，若对端 MAC 不在
> `persist.bluetooth.a2dp.lhdc.whitelist` 中，仍可能在选择阶段被剔除。
> 项目现有 P0 补丁只处理了 `ro.product.name`，**未覆盖此属性**（实测该属性未设置，故当前不构成阻塞，
> 但换耳机后可能成为新阻塞点）。

### 8.5 offload 能力掩码

`A2dpCodecs::init()` @0x766334 读 `ro.bluetooth.a2dp_offload.supported`（@0x7666634 附近）
与 `persist.bluetooth.a2dp_offload.cap`（@0x766884），据此决定哪些 codec 走 offload。
本机 `persist.bluetooth.a2dp_offload.cap = sbc-aac` → LDAC/aptX/LHDC 一律走软件编码。
与报告 §3.3 的附带发现一致。

### 8.6 门禁清单汇总

| # | 门禁 | 位置 | 本机状态 | 现有补丁是否覆盖 |
|---|---|---|---|---|
| 1 | `ro.product.name` ∈ {corot,duchamp,zircon,rothko,malachite} | `createCodec` @0x763470 | `xaga` 不在名单 → **阻塞** | ✅ P0（GOT 重定向 osi_property_get） |
| 2 | `A2dpCodecConfigLhdcV5Source::init()` = `isValid() && A2DP_VendorLoadEncoderLhdcV5()` | `createCodec` @0x763560-0x763570 | 编码器库存在 → 通过 | 无需 |
| 3 | HIDL 分发表 table[12] | `a2dp_get_selected_hal_codec_config` @0x825f28 | `0x5a` → 错误分支 → **阻塞** | ✅ P1（改 0x55） |
| 4 | V3 转换函数要求 codec_type==10 | `A2dpLhdcV3ToHalConfig` @0x82a900 | V5 的 12 被拒 → **阻塞** | ✅ P2（GOT 重定向 getCodecConfig） |
| 5 | `vendor.bluetooth.lhdc_codec.supported` | `btif_lhdc_codec_is_supported` @0xc417d8 | 未设置（默认 true）→ 通过 | 无需 |
| 6 | `persist.bluetooth.lhdc_codec.enabled` | `BtifAvSource::Init` @0x6ec4c0 | 未设置（运行时=1）→ 通过 | 无需 |
| 7 | `persist.bluetooth.a2dp.lhdc.whitelist`（按对端 MAC） | `BtaAvCo::SelectSourceCodec` @0x692e30 | 未设置 → 通过 | ⚠️ 未覆盖（潜在） |
| 8 | `btif_av_get_lhdc_codec_state()` | `BtaAvCo::ProcessSourceGetConfig` @0x69141c | 运行时=1 → 通过 | 无需 |
| 9 | HIDL/AIDL 通路选择 | `HalVersionManager` ctor @0x861424 | 选 HIDL 2.2 → **本质阻塞** | ❌ 无法用属性绕过 |

---

## 9. 对"实现 LHDC V5 通路"的前置条件（基于本任务取证）

按"是否可在不改 vendor 分区的前提下达成"分类：

### A. 已在二进制中就绪、无需任何工作的部分

- `A2dpCodecConfigLhdcV5Source` / `A2dpCodecConfigLhdcV5Base` 全套实现（setCodecConfig 8560 B、
  setPeerCodecCapabilities 884 B）
- V5 编码器接口（`a2dp_vendor_lhdcv5_encoder_init` 2516 B、`send_frames` 3620 B）
- V5 能力位/特性解析（`A2DP_VendorGetMaxBitRateLhdcV5`、`A2DP_VendorHasJASFlagLhdcV5` 等约 20 个）
- **AIDL MTK 的 codec_type 跳转表已把 12 正确路由到 `A2dpLhdcv5ToHalConfig`**
- AIDL MTK 的 `A2dpLhdcv5ToHalConfig`（1476 B）与 AOSP 的（1600 B）均已编译在内

### B. 缺失、且必须 vendor 侧补齐的部分（第三方不可达）

1. **vendor AIDL HAL 实现库**：`vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`
   （设备上不存在，已验证）
2. **VINTF 声明**：`/vendor/etc/vintf/manifest.xml` 增加 `format="aidl"` 的
   `vendor.mediatek.hardware.bluetooth.audio` 条目（当前 `format="aidl"` 计数为 0，已验证）
3. **服务注册**：`...IBluetoothAudioProviderFactory/default` 注册到 servicemanager
4. **AIDL 侧 `CodecConfiguration` 里承载 V5 字段的结构**
   （二进制中 `aidl::vendor::mediatek::hardware::bluetooth::audio::Lhdcv5Configuration`、
   `Lhdcv5Capabilities`、`Lhdcv5QualityIndex`、`Lhdcv5Version`、`Lhdcv5FrameDuration`、
   `Lhdcv5DataInterval`、`Lhdcv5Specific` 等类型确实存在，但只是**协议栈侧的桩**）

### C. 结论

- 报告的**核心判断成立**：HIDL 侧没有 V5 的接口结构，`codec_type=12` 无法送达 HIDL HAL；
  `HalVersionManager` 的选择完全由 vendor 侧服务注册决定，**无运行时开关**。
- 报告的**一处表述需修正**：AIDL 版 V5 代码不是"死代码"，而是"不可达通路上的活代码"。
  这带来一个方案含义：**若能让 `HalVersionManager` 选中 AIDL，V5 转换无需补丁即可工作**
  （AIDL 表已正确路由 index 12，且 AIDL `A2dpLhdcv5ToHalConfig` 会填充
  `Lhdcv5Configuration`，而不是伪装成 V3）。
- 但选中 AIDL 需要 vendor 侧提供实现库 + VINTF 声明 + 服务注册 ——
  **等价于要求厂商出固件**，与"不改挂载/不改 APEX"的约束不可兼容。
- 因此**内存补丁伪装 V3 仍是本约束下唯一可行方案**；其代价是 V5 参数经 V3 结构
  （`lhdcConfig`）承载，采样率靠"无钳位透传"侥幸保留 96 kHz，而 V5 专有的
  Lossless / JAS / META / AR 等特性位**无法传递给 HAL**。

---

## 10. 脚本索引

| 脚本 | 作用 |
|---|---|
| `r2_common.py` | 公共库：ELF 加载、合并符号表、GOT/PLT、Android packed RELA 解析、capstone 封装 |
| `r2_00_sanity.py` | SHA/节区/VA==offset 校验、三处补丁点原始字节、P1 表原始字节 |
| `r2_01_symsearch.py` | 探测两套符号表的覆盖差异 |
| `r2_02_lhdc_syms.py` | 203 个 LHDC 符号全枚举（mangled + demangled） |
| `r2_03_namespaces.py` | 按命名空间分类 `*ToHalConfig`；HIDL 无 V5 的否定证据 |
| `r2_04a_bytes.py` | HIDL 分发点原始指令字 + 所属函数 |
| `r2_05_tables.py` | 全 `.text` 分发惯用式扫描器（572 处 / 509 表） |
| `r2_06_resolve.py` | HIDL 表项 → 函数解析；错误分支字符串 |
| `r2_07_plt_names.py` | PLT 桩 → GOT → `.rela.plt` 符号名对撞 |
| `r2_08_aidl_path.py` | 每个 `*ToHalConfig` 的唯一调用者追踪 |
| `r2_09_aidl_dispatch.py` | AIDL MTK/AOSP setup_codec 反汇编 |
| `r2_10_all_tables.py` | HIDL 与 AIDL MTK 表全解码 + 函数名 |
| `r2_11_tables_by_fn.py` | 按函数归类跳转表 |
| `r2_12_aosp_tables.py` | 5 个 a2dp_encoding 函数内所有表 + AOSP AIDL 代码 |
| `r2_13_halversion.py` | HalVersionManager 各函数反汇编 |
| `r2_14_halver_detail.py` | ctor 全文 + 服务名/日志字符串 |
| `r2_15_switches.py` | ctor 后半 + 属性字符串普查 |
| `r2_16_halver_logs.py` | 分支目标手工验证 + 日志点映射 |
| `r2_17_service_names.py` | `.bss` std::string 用户 + 两个 ctor 的消费者 + 属性调用扫描 |
| `r2_18_static_init.py` | `_GLOBAL__sub_I_hal_version_manager.cc` 反汇编 |
| `r2_19_names_resolve.py` | 服务名基址解析 |
| `r2_20_gates.py` | createCodec 全文 + LHDC 属性普查 + LoadEncoderLhdcV5 |
| `r2_21_lhdc_gate.py` | LHDC 启用/禁用门禁函数定位 |
| `r2_22_btaavco.py` | BtaAvCo 白名单/禁用逻辑 + LhdcV5Source 虚表 |

---

## 11. 已复算确认的地址速查

| 项 | 值 | 本任务复核 |
|---|---|---|
| `A2dpCodecConfig::createCodec` | 0x763280 (824) | ✅ 符号表一致 |
| 白名单首分支 `b.eq` | 0x763470，原始 `c0 05 00 54` | ✅ 字节一致 |
| 命中目标（"LHDCV5 matches"） | 0x763528 | ✅ |
| `A2dpCodecConfig::getCodecConfig` | 0x764800 (92) | ✅ |
| HIDL 分发函数 | 0x825ec0（**非 0x825F00**，报告写"0x825F00 区域"） | ⚠️ 起始地址应为 0x825ec0 |
| HIDL 跳转表 | 0x2c5620，`00 26 46 46 4b 5a 5a 5a 5a 50 55 5a 5a 00 26` | ✅ 逐字节一致 |
| P1 补丁点 | 0x2c562c：`5a` → `55` | ✅ |
| `A2dpLhdcV3ToHalConfig`（HIDL） | 0x82a8b0 (736) | ✅ |
| `A2dpLhdcV2ToHalConfig`（HIDL） | 0x82ab90 (612) | ✅ |
| P2 校验 | 0x82a900 `cmp w8,#0xa`；0x82a904 `b.ne 0x82ab5c`，原始 `c1 12 00 54` | ✅ 字节一致 |
| `A2dpLhdcv5ToHalConfig`（MTK AIDL） | 0x83fd80 (1476) | ✅ |
| `A2dpLhdcv5ToHalConfig`（AOSP AIDL） | 0x870b80 (1600) | ⚠️ 报告未提及此套 |
| GOT `osi_property_get` | 0xf94428 | ✅ |
| GOT `A2dpCodecConfig::getCodecConfig` | 0xf95940 | ✅ |
| GOT `hidl::codec::A2dpLhdcV3ToHalConfig` | 0xf98d80 | ✅ |
| **AIDL MTK codec_type 表** | **0x2c577d（报告未提及）** | 🆕 本任务发现 |
| **AOSP HIDL codec_type 表** | **0x2c5cea（报告未提及）** | 🆕 本任务发现 |
| **AIDL MTK `setup_codec`** | **0x8378f0 (1800)** | 🆕 |
| **AOSP AIDL `setup_codec`** | **0x862750 (2232)** | 🆕 |
| **MTK HalVersionManager ctor** | **0x861370 (1284)** | 🆕 |
