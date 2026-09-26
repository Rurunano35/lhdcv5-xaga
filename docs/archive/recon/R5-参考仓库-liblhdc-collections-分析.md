# R5 — 参考仓库 liblhdc-collections 深度分析

> 分析日期：2026-09-25
> 仓库：`d:/Cache/Hyperos/lhdcv5-tr/reference/liblhdc-collections/`
> 来源：`https://github.com/sprlightning/liblhdc-collections.git`
> 本地 commit：`09a74e701ff81840e2648122e3abd4f82dbf5ce4`（2026-07-27，单次 squash 提交，无历史可比对）
> 设备：xaga / HyperOS OS2.0.12.0.ULOCNXM / Android 14（分析中全部为只读操作）
> 分析工具：Python 3.12 + pyelftools（`PYTHONPATH=d:/Cache/Hyperos/pylibs`）

---

## 0. 结论速览

| 问题 | 结论 | 证据强度 |
|---|---|---|
| (a) 仓库提供了什么 | **编码器层的"胶水+闭源库"完整包 + Google 的 Rust 版编码器源码 + 若干平台移植样本**；**完全不含 HAL/协议栈侧代码** | 已验证 |
| (b) AOSP/liblhdcv5 是胶水还是完整编解码器 | **纯胶水层**（2387 行 C，零算法）；全部算法在预编译 `liblhdcv5.so` 里 | 已验证 |
| (c) Rust 版能否直接替换闭源 .so | **不能直接替换**。它是闭源 .so 的**功能替代实现**，但导出的符号名完全不同（`lhdcv5_enc_ffi_*` ≠ `lhdcv5_util_*`），且**砍掉了 lossless/JAS/META/AR/VBR/MTU 全部扩展 API** | 已验证 |
| (d) HyperOS 2.0.211.0 的 .so 与设备上的 .so 同版本吗 | **不同**。仓库里那份是 **5.0.4**（`LHDC_V5-5.0.4_220426_114542`），设备上是 **5.0.5**（`LHDC_V5-5.0.5_8c9d77`） | 已验证 |
| (e) 是否含蓝牙协议栈侧代码 | **完全不含 Android 侧协议栈/HAL 代码**；ESP-IDF 目录是 ESP32 Bluedroid 的 **Sink/解码器** 移植，与 Android 编码通路无关（但 CIE 字节布局有参考价值） | 已验证 |
| (f) 帮助边界 | **只解决"编码器算法"这一层**。HAL 层（`Lhdcv5Configuration` 传输）在设备上**不存在实现**，仓库对此零帮助 | 已验证 |

**一句话**：这个仓库把"LHDC V5 编码器算法"这个黑盒打开了（Google Rust 版），但**通路问题不在编码器层**——设备缺的是厂商 HAL 对 `Lhdcv5Configuration` 的实现。仓库对 (f) 的贡献止于编码器。

---

## 1. 分析方法与复现命令

所有结论基于以下可复现操作（只读）：

```bash
# 文件哈希
sha256sum <file>

# ELF 符号/版本串（pyelftools + 正则扫串）
PYTHONPATH="d:/Cache/Hyperos/pylibs" python <script>.py <so-file>

# 设备侧（只读）
export MSYS_NO_PATHCONV=1
ADB="d:/Cache/Hyperos/platform-tools/adb.exe"
"$ADB" shell "su -c 'sha256sum /apex/com.android.btservices/lib64/liblhdcv5.so'"
"$ADB" shell "su -c 'ls -la /vendor/lib64/hw/ | grep -i bluetooth'"
"$ADB" shell "su -c 'grep -A6 -i bluetooth /vendor/etc/vintf/manifest.xml'"
"$ADB" exec-out "su -c 'cat <path>'" > local_copy.so   # 仅读取，不写设备
```

---

## 2. (a) 逐目录说明

### 2.1 `AOSP/liblhdcv5/` — ★ 与"V5 编码通路"最相关

| 文件 | 大小 | 性质 |
|---|---|---|
| `Android.bp` | 1309 B | 构建定义 |
| `release_note` | 319 B | 版本记录，最新一条 = **5.0.6（2022-08-03）** |
| `inc/lhdcv5BT.h` | 2257 B | **BT 侧 API 头**（15 个 `lhdcv5BT_*`） |
| `include/lhdcv5_api.h` | 11653 B | **编解码器 API 头**（34 个 `lhdcv5_util_*` + 16 enum + 1 struct） |
| `include/lhdcv5BT_ext_func.h` | 6116 B | 扩展功能（META/AR）结构体与 API code 定义 |
| `src/lhdcv5BT_enc.c` | 77600 B | **胶水层源码（开源）** |

`Android.bp` 关键点（**证明算法闭源**）：

```python
cc_prebuilt_library_shared {
    name: "liblhdcv5",
    srcs: ["libs/arm64-v8a/liblhdcv5.so",],   # ← 预编译 .so，仓库内 libs/ 目录并不存在
    strip: { none:true, },
}
cc_library_shared {
    name: "liblhdcv5BT_enc",
    srcs: ["src/lhdcv5BT_enc.c",],            # ← 唯一开源的源码
    shared_libs: [ "libcutils", "liblog", "liblhdcv5", ],
}
```

> `libs/arm64-v8a/liblhdcv5.so` 在仓库中**不存在**（Savitech 按授权单独分发）。

### 2.2 `AOSP/liblhdc/` — LHDC V2/V3/V4 编码器（同类结构，非 V5）

结构完全对应：`Android.bp`（同样是 `cc_prebuilt_library_shared` + `liblhdc.so` 预编译）、`release_note`（最新 2022/09/14，LHDCV4 encoder V4.0.6p1）、`inc/lhdcBT.h`(16804 B)、`include/{cirbuf.h, lhdc_api.h, lhdc_cfg.h, lhdc_enc_config.h, lhdc_process.h, lhdcv2_process.h, lhdcv3_process.h, llac_enc_api.h}`、`src/lhdcBT_enc.c`(52748 B)。

**这就是设备当前实际跑的 V3 编码器的同款包**（设备日志 `lhdcBT_get_handle: Version number 2` / `lhdc_encoder_init: ... version code=300`）。
对本任务的价值：**V3 路径的 API 形状参照**，V5 无关。

### 2.3 `AOSP/liblhdc-hyperos2_0_211_0/` — 从 HyperOS 提取的 .so

只含两个文件：`system/lib64/liblhdc.so`(4001592 B)、`system/lib64/liblhdcv5.so`(3542504 B)。
**实测这两个文件与 `AOSP/other_so_files/enc/LHDC-magisk-11_arm64/system/lib64/` 下的同名文件字节完全相同**（见 §5 哈希表）——即该目录与那个 Magisk 模块是同一份来源。
版本实测为 **LHDC 5.0.4**，**不是设备上的 5.0.5**（详见 §5）。

### 2.4 `AOSP/liblhdcdec/`、`AOSP/liblhdcv5dec/` — 解码器（同样"胶水开源 + 算法闭源"）

- `liblhdcv5dec/`：`inc/lhdcv5BT_dec.h`(2243 B)、`include/lhdcv5_util_dec.h`(2470 B)、`src/lhdcv5BT_dec.c`(12522 B) + 预编译 `liblhdcv5dec.so`。release_note 同样到 5.0.6。
- 缺失的正是 `lhdcv5_util_dec.c`（解码算法）。

> 对本任务**无用**（手机是 Source/编码端），但证明了 Savitech 的分发模式：**只给胶水，不给算法**。

### 2.5 `AOSP/other_so_files/` — 杂项二进制

- `dec/lhdc/aarch64|lhdc/x86_64/{liblhdcBT_dec.so, liblhdcBT_enc.so}` — V2/V3 胶水 .so
- `dec/lhdcv5/BEST2500P_libLHDC_V5_5_2_0_SAVI_KEYPRO_UUID.a` — **BES 平台 V5 解码静态库 5.2.0**
- `enc/liblhdcv5.so` — 5.0.4（同 §2.3）
- `enc/LHDC-magisk-11_arm64/` — 一个 2021 年的日文 Magisk 模块（作者 `Re*Index.(ot_inc)`），`module.prop` 自称 `description=Add LHDC Codec`，README 明写"**作った人はLHDCなデバイスを持ってないので動作未確認**"（作者没有 LHDC 设备，未验证能否工作）。内含 `lib/{liblhdc.so, liblhdcBT_enc.so, liblhdcv5.so, liblhdcv5BT_enc.so}` 与 lib64 同名文件。

> ⚠️ 该 Magisk 模块本身**未经作者验证**，且是给 Android 11 时代的 ROM 用的。它的 `liblhdcv5.so` 与 §2.3 那份同源（5.0.4）。

### 2.6 `lhdcv5/`（Rust） — ★ Google 的完整 V5 编码器实现

28 个文件，全部为 **AOSP `android17-release` 分支 `system/audio/codecs/lhdcv5` 模块的原样快照**。

**关键验证**：目录内附带的 `Bluetooth-refs_heads_android17-release-system-audio-codecs-lhdcv5.tar.gz` 解包后与目录内容**逐文件一致（仅 CRLF 差异）**：

```
--- total=28 identical=0 different=28   ← 全部"different"仅因 git checkout 加了 CRLF
NORM-EQ  Android.bp dir=1240 tar=1180
NORM-EQ  Cargo.toml dir=569 tar=538
NORM-EQ  include/lhdcv5_api.h dir=6455 tar=6178
NORM-EQ  src/ffi.rs dir=10337 tar=10038
NORM-EQ  src/enc/process.rs dir=53791 tar=52449
...（28/28 全部 NORM-EQ，即去掉 CR 后字节相同）
```

即：**`lhdcv5/` 目录 = 官方 tarball 的解包结果**，无第三方改动。tarball 内文件时间戳 `Jul 22 00:42`。

内容：Rust 源码 25 个 `.rs`（含 `enc/process.rs` 52 KB 编码核心、`kiss_fft.rs` 21 KB、`lhdc_api/lhdc_api_internal.rs` 30 KB）+ 1 个 C 胶水 `src/lhdcv5BT_enc.c`(28481 B) + 2 个头 + `Android.bp`/`Cargo.toml`/`generate.bash`。

### 2.7 `BES-IHC/` — BES 芯片平台 SDK 摘录（非 Android）

```
a2dp_decoder/a2dp_decoder_lhdc.cpp / a2dp_decoder_lhdcv5.cpp
audio_codec/liblhdc-dec/BEST2500P_libLHDC_V2_V3_V4_4_0_13_SAVI_KEYPRO_UUID.a
audio_codec/liblhdcv5-dec/BEST2500P_libLHDC_V5_5_2_0_SAVI_KEYPRO_UUID.a
audio_codec_lib/liblhdc-dec/inc/lhdcUtil.h + Makefile
audio_codec_lib/liblhdc-enc/inc/{lhdc_cfg.h, lhdc_enc_api.h} + Makefile
audio_codec_lib/liblhdcv5-dec/inc/lhdcv5_util_dec.h + Makefile
```

**全是解码器**（`-dec`）+ 一个 V3 编码头（`liblhdc-enc/inc/lhdc_enc_api.h`）。
**没有 V5 编码器**（`libLHDC_V5_*.a` 是 decoder）。对手机侧编码通路**无用**。

### 2.8 `ESP-IDF/` — ESP32 Bluedroid 的 **Sink/解码** 移植（详见 §6）

### 2.9 `LHDC-V5-Encoder/`、`LHDC-V5-Decoder/` — **空目录**

```bash
$ ls -la LHDC-V5-Encoder LHDC-V5-Decoder
LHDC-V5-Encoder:  total 4  (仅 . 和 ..)
LHDC-V5-Decoder:  total 4  (仅 . 和 ..)
```

`.gitmodules` 声明为 submodule（`https://github.com/WillyBilly06/LHDC-V5-Encoder.git` / `-Decoder.git`），但**未初始化**。README 第 4 节对这两个目录的描述**在当前 clone 中无对应文件**。

> 影响：**`WillyBilly06` 的 C 版 V5 编码器（Google Rust 版的 C 移植）在本仓库中拿不到**，必须另行 clone。
> 同样，开源 LHDC V5 **解码器**（可用于验证码流）也不在本地。

### 2.10 `figures/`、`LICENSE`、`README.md`

- `figures/test_of_LHDC-V5-Decoder.jpg`（367 KB，ESP32 实测照片）
- `README.md` 35 KB，含 LHDC V5 **解码原理**的详细逆向说明（§3.1–3.11）与移植指南（§5）—— 是本仓库**信息密度最高的文本**

---

## 3. (b) `AOSP/liblhdcv5/` 是胶水层还是完整编解码器？

### 3.1 结论：**纯胶水层**

`src/lhdcv5BT_enc.c` 2387 行，`#include` 只有 libc + 两个自家头 + `<cutils/log.h>`：

```c
#include <stdio.h> <string.h> <stdlib.h> <stdint.h> <stdbool.h>
#include "lhdcv5BT.h"
#include "lhdcv5BT_ext_func.h"
#define LOG_TAG "lhdcv5BT_enc"
#include <cutils/log.h>
```

**外部符号统计（对全文件做正则提取）**：

| 外部依赖 | 次数 | 来源 |
|---|---|---|
| `lhdcv5_util_*` | 28 个不同符号 / 共 96 处调用 | **闭源 `liblhdcv5.so`** |
| `ALOGW` / `ALOGD` / `ALOGV` | 147 / 32 / 4 | liblog |
| `malloc` / `free` | 1 / 6 | libc |

**没有任何算法函数、没有 FFT、没有量化/熵编码代码。** 全部实际编码在 `lhdcv5_util_enc_process()` 一个调用里：

```c
int32_t lhdcv5BT_encode(...)
{
  ...
  func_ret = lhdcv5_util_enc_process (handle, p_in_pcm, pcm_bytes,
      p_out_buf, out_buf_bytes, p_out_bytes, p_out_frames);
  ...
}
```

### 3.2 它实现了哪些函数（15 个，与 `inc/lhdcv5BT.h` 1:1）

| # | 函数 | 行号 | 作用 |
|---|---|---|---|
| 1 | `lhdcv5BT_free_handle` | 827 | `lhdcv5_util_free_handle` + `free()` |
| 2 | `lhdcv5BT_get_handle` | 866 | `get_mem_req` → `malloc` → `get_handle` |
| 3 | `lhdcv5BT_get_bitrate` | 942 | `get_target_bitrate`，并校验 [64000, 1000000] |
| 4 | `lhdcv5BT_set_bitrate` | 992 | `adjust_bitrate` / `set_target_bitrate_inx` |
| 5 | `lhdcv5BT_set_max_bitrate` | 1135 | `set_max_bitrate_inx` |
| 6 | `lhdcv5BT_set_min_bitrate` | 1184 | `set_min_bitrate_inx` |
| 7 | `lhdcv5BT_adjust_bitrate` | 1234 | ABR/VBR 状态机（**唯一有实质逻辑的函数**，485–827 行的 `lhdcv5_enc_abr_adjust_bitrate` / `lhdcv5_enc_vbr_adjust_bitrate`） |
| 8 | `lhdcv5BT_set_ext_func_state` | 1333 | AR/LARC/JAS/META 开关 |
| 9 | `lhdcv5BT_init_encoder` | 1390 | 参数校验 + `lhdcv5_util_init_encoder` + ABR/VBR 参数下发 |
| 10 | `lhdcv5BT_get_block_Size` | 1518 | `get_block_Size` |
| 11 | `lhdcv5BT_encode` | 1567 | `enc_process` |
| 12–15 | `lhdcv5BT_{set,get}_user_exconfig` / `set_user_exdata` / `get_user_exApiver` | 2023–2387 | **8 字节 header 的 ex-config 分发器**（META / AR） |

内部 static 函数 9 个：`rate_to_string`、`lhdcv5_enc_lossless_dump_statis`、`lhdcv5_enc_inx_of_abr_bitrate`、`lhdcv5_enc_vbr_adjust_bitrate`、`lhdcv5_enc_abr_adjust_bitrate`、`lhdcBT_code_ver_wrap`、`lhdcBT_set_cfg_meta_v1`、`lhdcBT_get_cfg_meta_v1`、`lhdcBT_set_data_gyro_2d_v1`、`lhdcBT_set_cfg_ar_v3`、`lhdcBT_get_cfg_ar_v1`。

### 3.3 它调用哪些外部符号（= 闭源部分）

28 个，**全部是 `lhdcv5_util_*`**：

```
lhdcv5_util_get_mem_req          lhdcv5_util_get_handle         lhdcv5_util_free_handle
lhdcv5_util_init_encoder         lhdcv5_util_get_block_Size     lhdcv5_util_enc_process
lhdcv5_util_get_target_bitrate   lhdcv5_util_get_bitrate_inx    lhdcv5_util_set_target_bitrate_inx
lhdcv5_util_set_max_bitrate_inx  lhdcv5_util_set_min_bitrate_inx lhdcv5_util_adjust_bitrate
lhdcv5_util_reset_up_bitrate     lhdcv5_util_reset_down_bitrate
lhdcv5_util_reset_up_bitrate_vbr lhdcv5_util_reset_down_bitrate_vbr
lhdcv5_util_set_vbr_up_th        lhdcv5_util_set_vbr_dn_th
lhdcv5_util_set_vbr_up_intv      lhdcv5_util_set_vbr_dn_intv     lhdcv5_util_vbr_process
lhdcv5_util_get_lossless_enabled lhdcv5_util_get_lossless_status
lhdcv5_util_set_ext_func_state   lhdcv5_util_get_ext_func_state
lhdcv5_util_ar_set_cfg           lhdcv5_util_ar_get_cfg          lhdcv5_util_ar_set_gyro_pos
```

**★ 交叉验证**：把设备上真实的 `liblhdcv5BT_enc.so` 拉下来做导入表分析，得到 **28 个 `lhdcv5_util_*` 导入，与源码调用集完全一致（差集为空）**：

```
设备 glue 导入的 lhdcv5_util_* 数量 = 28
AOSP enc.c 源码调用的 lhdcv5_util_* 数量 = 28
源码调用但设备 glue 未导入: []
设备 glue 导入但源码未调用: []
lhdcv5BT.h 声明 = 15; 设备 glue 导出 = 15
头文件声明但设备未导出: []
设备导出但头文件未声明: []
```

→ **`AOSP/liblhdcv5/src/lhdcv5BT_enc.c` 与设备上跑的胶水是同一份代码（或极近的修订）**。字符串层面 40 条格式串中 33 条精确命中，未命中的 7 条多为 ALOGV/调试串（例：`[LLESS_DBG][VBR_ADJ],statisK_BRate,FINAL_DN,%.3f,%u,%u`），说明设备那份是**略早的修订**（设备 5.0.5 vs 仓库 5.0.6）。

### 3.4 结构体与枚举（V5 配置面）

> 完整清单见 `d:/Cache/Hyperos/lhdcv5-tr/reference/notes/R5-lhdcv5_api-结构体枚举清单.md`
> 头文件全文见 `d:/Cache/Hyperos/lhdcv5-tr/reference/notes/R5-AOSP-libhdcv5-headers-full.txt`

#### ★ 最重要的发现：**V5 没有"配置大结构体"**

`lhdcv5_api.h` 里**只有一个 struct**（`lhdcv5_abr_para_t`），且它是 **ABR/VBR 的运行时统计/状态**，不是用户配置。配置是**逐标量参数**传的：

```c
extern int32_t lhdcv5_util_init_encoder
(
    HANDLE_LHDCV5_BT  handle,
    uint32_t          sampling_freq,     // 44100 / 48000 / 96000 / 192000
    uint32_t          bits_per_sample,   // 16 / 24 / 32
    uint32_t          bitrate_inx,       // 0..13（LOW0..AUTO）
    uint32_t          frame_duration,    // 50=5ms / 75=7.5ms / 100=10ms / 10000=1s
    uint32_t          mtu,               // 300..4096
    uint32_t          interval,          // 10 / 20 (ms)
    uint32_t          lossless_supp      // 0/1
);
```

其余配置全部**带外**：码率（`set_target_bitrate_inx`）、MTU（`set_target_mtu`）、lossless（`set_lossless_enabled/status`）、VBR（`set_vbr_*`）、AR/LARC/JAS/META（`set_ext_func_state` + `ST_LHDC_*` 结构体 blob）。

#### 枚举（16 个，完整列表）

| 枚举类型 | 成员（值） |
|---|---|
| `LHDCV5BT_SAMPLE_FREQ_T` | SR_44100=44100, SR_48000=48000, SR_96000=96000, SR_192000=192000 |
| `LHDCV5BT_SMPL_FMT_T` | S16=16, S24=24, S32=32 |
| `LHDCV5_SAMPLE_FRAME_T` | 5MS_44100=240, 5MS_48000=240, 5MS_96000=480, 5MS_192000=960, 10MS_44100=480, 10MS_48000=480, 10MS_96000=960, 10MS_192000=1920, MAX=1920 |
| `LHDCV5_FRAME_DURATION_T` | 5MS=50, 7P5MS=75, 10MS=100, 1S=10000 |
| `LHDCV5_LOSSLESS_FUNC_T` | MAYBE_DISABLE=0, MAYBE_ENABLE=1 |
| `LHDCV5_ENC_INTERVAL_T` | 10MS=10, 20MS=20 |
| **`LHDCV5_QUALITY_T`** | LOW0=0, LOW1=1(128K), LOW2=2(192K), LOW3=3(256K/240K), LOW4=4(320K), LOW=5(400K), MID=6(500K), HIGH=7(900K), HIGH1=8(1000K), HIGH2=9(1100K), HIGH3=10(1200K), HIGH4=11(1300K), HIGH5=12(1400K), **MAX_BITRATE=HIGH5**, **AUTO=13**, UNLIMIT=14, CTRL_RESET_ABR=128, CTRL_END=129, INVALID=130 |
| `LHDCV5_MTU_SIZE_T` | MIN=300, 2MBPS=660, 3MBPS=1023, MAX=4096 |
| `LHDCV5_VERSION_T` | VERSION_1=1, VERSION_INVALID=2 |
| `LHDCV5_ENC_TYPE_T` | UNKNOWN=0, LHDCV5=1, INVALID=2 |
| `LHDCV5_EXT_FUNC_T` | **AR=0, LARC=1, JAS=2, META=3, INVALID=4** |
| `LHDCV5_META_PARAM_T` | LOOP_CNT_MAX=100, LOOP_CNT_STD=20, LEN_FIXED=8, LEN_MAX=128 |
| `LHDCV5_ABR_TYPE_T` | ABR_44K_RES=0, ABR_48K_RES=1, ABR_96K_RES=2, ABR_192K_RES=3, ABR_INVALID=4 |
| `LHDCV5_VBR_TYPE_T` | VBR_48K_RES=0, VBR_INVALID=1 ← **VBR 只有 48K 一档** |
| `LHDCV5_VBR_BITRATE_RANGE_T` | VBR_MIN_BITRATE=900, VBR_MAX_BITRATE=1400 (kbps) |
| `LHDCV5_FUNC_RET_T` | SUCCESS=0, INVALID_INPUT_PARAM=-1 … BUF_NOT_ENOUGH=-11（12 项，见 notes） |

宏：`LHDCV5_ABR_DEFAULT_BITRATE`=LOW(400K)、`LHDCV5_VBR_DEFAULT_BITRATE`=HIGH2(1100K)

#### struct

**`lhdcv5_abr_para_t`**（唯一 struct，ABR/VBR 运行时参数，33 个字段）：`version`, `sample_rate`, `bits_per_sample`, `bits_per_sample_ui`, `upBitrateCnt/Sum`, `dnBitrateCnt/Sum`, `lless_up/dnBitrateSum`, `lless_up/dnBitrateCnt`, `lless_up/dnCheckBitrateCnt`, `lless_up/dnRateTimeCnt`, `lless_upLossyRatioTh`, `lless_dnLosslessRatioTh`, `lless_stat_*`(5), `lastBitrate`, `qualityStatus`, `is_lless_enabled`, `is_lless_on`。

**`HANDLE_LHDCV5_BT`** = `typedef void *` —— 实际是 `malloc(mem_req_bytes)` 出来的裸内存块（见 `lhdcv5BT_get_handle` 实现）。

**`lhdcv5BT_ext_func.h` 的 4 个 `#pragma pack(1)` 结构体**（均以 8 字节 `header[8]` 开头，承载 ex-config 二进制协议）：

| 结构体 | 关键字段 |
|---|---|
| `ST_LHDC_SET_META` | header[8], meta_ver, meta_mem_size, meta_enable, meta_set, meta_metadata_length（后接变长 metadata） |
| `ST_LHDC_GET_META` | header[8], meta_ver, meta_mem_size, meta_st, jas_status |
| `ST_LHDC_AR` | header[8], ver, size, app_ar_enabled, **Ch1..Ch6_Pos**, **12×float PreGain**, **6×float PostGain**, Dry_Val, Wet_Val, **5×Dis**, **5×Rev**, Rev_gain, ThreeD_gain |
| `ST_LHDC_AR_GYRO` | header[8], world_coordinate_x/y/z |

ex-config 分发器（`lhdcBT_code_ver_wrap`）把 buffer 前 8 字节大端解析为 `[ver(4B)][code(4B)]`，code 取 `0x0C000001`(SET_META) / `0x0C000002`(SET_AR) / `0x0C010001`(GET_META) / `0x0C010002`(GET_AR) / `0x0A010001`(GET_SPECIFIC)。

### 3.5 与设备的一致性（独立验证）

| 项 | AOSP 源码/头文件 | 设备实测 | 一致？ |
|---|---|---|---|
| `lhdcv5BT.h` 声明的 15 个函数 | 15 | 设备 `liblhdcv5BT_enc.so` 导出 15 | ✅ |
| `lhdcv5BT_enc.c` 调用的 `lhdcv5_util_*` | 28 | 设备 glue 导入 28 | ✅ |
| `lhdcv5_api.h` 声明的 34 个 `lhdcv5_util_*` | 34 | 设备 `liblhdcv5.so` 导出 36（34 + `get_bitrate_t`/`set_bitrate_t`） | ✅ 超集 |
| 栈 `dlsym` 的名字列表 | — | 见 §7，15 个，与 `lhdcv5BT.h` 完全一致 | ✅ |

---

## 4. (c) `lhdcv5/`（Rust）与 `AOSP/liblhdcv5/` 的关系

### 4.1 定位：**是闭源 .so 的功能替代实现，但不是 ABI 兼容实现**

`lhdcv5/Android.bp` 全文要点：

```python
rust_ffi_static {
    name: "liblhdcv5_encoder_rust",
    crate_name: "lhdcv5_encoder",
    crate_root: "src/lib.rs",
    rustlibs: [ liblibc, liblog_rust, libthiserror, libtracing,
                libtracing_subscriber, libzerocopy, + android:libandroid_logger ],
    min_sdk_version: "36",                    # ← Android 16
    apex_available: [ "com.android.bt" ],     # ← 新 APEX 名
}
cc_library_static {                           # ← 静态库，不是 .so
    name: "liblhdcv5_encoder",
    srcs: [ "src/lhdcv5BT_enc.c" ],           # ← 同名胶水文件，但内容完全不同
    whole_static_libs: [ "liblhdcv5_encoder_rust" ],
    shared_libs: [ "libbase", "liblog" ],
    min_sdk_version: "36",
    apex_available: [ "com.android.bt" ],
}
```

对比 `AOSP/liblhdcv5/Android.bp`（`cc_prebuilt_library_shared` + `cc_library_shared`，`apex_available: com.android.btservices`，`min_sdk_version: Tiramisu`）：

| 维度 | AOSP/liblhdcv5（Savitech 版） | lhdcv5（Google Rust 版） |
|---|---|---|
| 算法实现 | 预编译 `.so`（闭源） | **Rust 源码（开源，25 个 .rs）** |
| 产物类型 | `cc_prebuilt_library_shared` + `cc_library_shared` | `rust_ffi_static` + `cc_library_static`（**静态**） |
| APEX | `com.android.btservices` | `com.android.bt`（新） |
| min_sdk | Tiramisu (33) | **36 (Android 16)** |
| 胶水层调用的 API | `lhdcv5_util_*`（34 个） | **`lhdcv5_enc_ffi_*`（12 个）** |

### 4.2 导出的 API / 头文件对比：**不一致**

**Rust 版 `include/lhdcv5_api.h` 是 cbindgen 自动生成的**（含 Apache 头、`#include <stdarg.h>` 等特征），导出 **12 个 `lhdcv5_enc_ffi_*`**：

```
lhdcv5_enc_ffi_init              lhdcv5_enc_ffi_get_handle       lhdcv5_enc_ffi_free_handle
lhdcv5_enc_ffi_init_encoder      lhdcv5_enc_ffi_get_quality_mode lhdcv5_enc_ffi_get_last_bitrate
lhdcv5_enc_ffi_get_bitrate_index lhdcv5_enc_ffi_set_bitrate_index
lhdcv5_enc_ffi_set_max_bitrate   lhdcv5_enc_ffi_set_min_bitrate
lhdcv5_enc_ffi_get_block_size    lhdcv5_enc_ffi_encode
```

命名体系也换了：`LHDC_*` / `LHDCBT_*`（V3 风格，且大量是 `#define` 而非 enum）+ `HANDLE_LHDC_BT = *const Context`。

**BT 侧头文件对比（`lhdcv5BT.h`，这是栈直接 dlsym 的接口）**：

| 函数 | Savitech 版 | Rust 版 |
|---|---|---|
| `lhdcv5BT_free_handle` | ✅ | ✅ |
| `lhdcv5BT_get_handle` | ✅ | ✅ |
| `lhdcv5BT_get_bitrate` | ✅ | ✅ |
| `lhdcv5BT_set_bitrate` | ✅ | ✅ |
| `lhdcv5BT_set_max_bitrate` | ✅ | ✅ |
| `lhdcv5BT_set_min_bitrate` | ✅ | ✅ |
| `lhdcv5BT_adjust_bitrate` | ✅ | ✅ |
| `lhdcv5BT_init_encoder` | ✅（末参 `is_lossless_enable`） | ✅（末参 **`[[maybe_unused]] reserved`**） |
| `lhdcv5BT_get_block_Size` | ✅ | ✅ |
| `lhdcv5BT_encode` | ✅ | ✅ |
| **`lhdcv5BT_set_ext_func_state`** | ✅ | ❌ **缺失** |
| **`lhdcv5BT_get_user_exApiver`** | ✅ | ❌ **缺失** |
| **`lhdcv5BT_get_user_exconfig`** | ✅ | ❌ **缺失** |
| **`lhdcv5BT_set_user_exconfig`** | ✅ | ❌ **缺失** |
| **`lhdcv5BT_set_user_exdata`** | ✅ | ❌ **缺失** |

> ⚠️ **这是致命差异**：Android 栈 dlsym 的正是这 15 个名字（§7 已验证）。缺 5 个 → **编码器库加载会失败**。

### 4.3 功能覆盖对比：Rust 版**砍掉了 V5 的高端特性**

对 `lhdcv5/` 全目录（`src/` + `include/`）做关键词扫描：

```
=== lossless 关键词搜索 ===            ← 零命中
=== JAS / META / AR / gyro 关键词搜索 ===   ← 零命中
```

具体：

| 特性 | Savitech 版 | Rust 版 | 证据 |
|---|---|---|---|
| **Lossless（无损）** | ✅ `set/get_lossless_enabled/status`, VBR | ❌ **完全无** | 0 处 `lossless`；`init_encoder` 末参被标 `[[maybe_unused]]` |
| **JAS** | ✅ `EXT_FUNC_JAS` | ❌ | 0 处 |
| **META** | ✅ `ST_LHDC_SET_META` | ❌ | 0 处 |
| **AR（3D 音效）** | ✅ `ST_LHDC_AR` + 陀螺仪 | ❌ | 0 处 |
| **LARC** | ✅ `EXT_FUNC_LARC` | ❌ | 0 处 |
| **VBR** | ✅ `set_vbr_up/dn_th/intv`, `vbr_process` | ❌ | 0 处 |
| **MTU 运行中调整** | ✅ `get_current_mtu`/`set_target_mtu` | ❌（只做初始化入参） | 头文件无 |
| 位深 | S16 / S24 / **S32** | **S16 / S24**（`bits_per_sample != S16 && != S24 → 报错`） | `lhdcv5BT_enc.c:634` |
| 采样率 | 44.1 / 48 / 96 / **192 kHz** | 44.1 / 48 / 96 / 192 kHz ✅ | `lhdcv5BT_enc.c:628` |
| 帧长 | 5 / 7.5 / 10 ms / 1s | 只传 `LHDC_FRAME_5MS` | `ffi.rs` 硬编码 |
| 码率索引 | LOW0..AUTO（含 ABR） | LOW0..AUTO（含 ABR 表） ✅ | `lhdc_abr.rs` |
| 多声道 | 头文件有 Ch1..Ch6（AR 用） | **硬编码 stereo=2** | `lhdc_api_internal.rs:117/299/605` `let ch_num = 2;`（`enc::context::Context::new` 虽接受 1..=8，但 FFI 路径不可达） |

**码率表**（Rust 版，15 档，`lhdc_api.rs:110`）：

```rust
g_bitrate_table_44k / _48k / _96k / _192k   (仅 index 3 不同：240 vs 256)
= [64, 160, 192, 256, 320, 400, 500, 900, 1000, 1100, 1200, 1300, 1400, 99999, 1536000]
   LOW0 LOW1 LOW2 LOW3 LOW4 LOW  MID  HIGH HIGH1 HIGH2 HIGH3 HIGH4 HIGH5 AUTO  UNLIMIT
```

→ index 13 (`AUTO`) = **99999 kbps 哨兵值**，14 (`UNLIMIT`) = 1536000。与 `lhdcv5_api.h` 的 `LHDCV5_QUALITY_T` 逐项对应。

**帧头层面**：Rust 版 `Header.info` 是 16 bit 位域，含 6 个子字段：

```rust
static HEADER_INFO_MAX:     [u16; 6] = [0x3ff, 0xc00, 0x1000, 0x2000, 0x4000, 0x8000];
static HEADER_INFO_OFFSETS: [i32; 6] = [0,     10,    12,     13,     14,     15    ];
//                           ENC_SIZE(10b) VERSION(2b) JAS(1b) AR(1b) LARC(1b) META(1b)
```

`set_info()` 能写 JAS/AR/LARC/META 位，但**全代码中没有任何地方调用它们**（`set_version` 只写 VERSION_INDEX，且 `lhdcv5_util_get_handle(version=1)` 之外无人调用）→ **Rust 版永远输出 JAS=0 / AR=0 / LARC=0 / META=0**。

### 4.4 构建可行性评估

#### `Cargo.toml`（全文）

```toml
[package]
name = "lhdcv5"
version = "0.1.0"
rust-version = "1.82"
edition = "2021"

[dependencies]
env_logger = "0.10.2"
libc = "0.2"
log = "0.4.27"
thiserror = "2.0.11"
tracing = "0.1.41"
tracing-subscriber = { version = "0.3.19", features = ["fmt"] }
zerocopy = { version = "0.8.14", features = ["derive"] }

[lib]
crate-type = ["rlib", "cdylib"]

[[bin]]
name = "simulator"

[profile.dev]
overflow-checks = false
opt-level = 0

[profile.release]
overflow-checks = false
opt-level = 0

[build]
rustflags = ["-C", "target-feature=-fma"]
```

#### `generate.bash`（全文）

```bash
#!/bin/bash
set -e
parallel cargo run --release --bin simulator -- {1} {2} :::: <(ls samples/*.wav savi_test_sample/*.wav) ::: 64000 128000 192000 256000 320000 400000 500000 900000 1000000 0
```

#### 逐项可行性判定

| 项 | 判定 | 证据 |
|---|---|---|
| **`cargo build`（host，跑 simulator）** | ⚠️ 理论可行，**未实测**（本机无 rust 工具链：`which cargo` → not found） | `[[bin]] simulator` + `env_logger` 走 host 分支 |
| **`cargo build --target aarch64-linux-android`** | ❌ **必然失败** | `src/lib.rs:37` 用 `android_logger::init_once(...)`，但 `Cargo.toml` **未声明 `android_logger` 依赖**（0 处匹配）。AOSP Soong 里由 `libandroid_logger` 提供，纯 cargo 构建缺少该 crate |
| **`generate.bash`** | ❌ **不可直接运行** | 依赖 `samples/*.wav` 与 `savi_test_sample/*.wav`，**两个目录都不存在**；`parallel` 也需另装 |
| **`[build] rustflags`** | ❌ **无效** | `[build]` 不是合法的 `Cargo.toml` 表（cargo 会警告 unused key）；正确位置是 `.cargo/config.toml`，仓库中**不存在 `.cargo/`**。→ 文档中"`-fma` 规避"在纯 cargo 构建下**不会生效** |
| **release profile** | ⚠️ 可疑 | `[profile.release] opt-level = 0` → **release 构建不优化**。LHDC V5 是实时编码（48 kHz/24 bit 双声道），opt-level 0 在手机上**几乎不可能满足实时**。（AOSP 走 Soong 不受此影响，但这说明该 Cargo.toml 主要用于 simulator 调试） |
| **`tracing` / `tracing-subscriber`** | ⚠️ 死依赖 | `Cargo.toml` 声明，`src/` 中 **0 处引用** |
| **`android_logger`** | ⚠️ 幽灵依赖 | `src/` 中 **1 处引用**（lib.rs），`Cargo.toml` **0 处声明** |
| **产物形态** | ❌ 不能直接替换 | `crate-type = ["rlib","cdylib"]` → cdylib 产出 `liblhdcv5.so`，但**导出的是 `lhdcv5_enc_ffi_*` 而非 `lhdcv5_util_*`**。设备上现成的 `liblhdcv5BT_enc.so` 导入的是 `lhdcv5_util_*` → **直接换 .so 会 dlsym/link 失败** |
| **版本要求** | ℹ️ | `rust-version = "1.82"`，edition 2021 |
| **`libs/arm64-v8a/`** | ❌ 不存在 | Rust 版 `Android.bp` 不引用 `libs/`（因为它是源码构建），与 Savitech 版不同 |

#### 要做出"能用的替换"，必须做的改造（结论性清单）

1. **重建胶水层**：用 Rust 版的 `src/lhdcv5BT_enc.c`（只提供 10 个函数），**补上缺失的 5 个**（`set_ext_func_state` + 4 个 ex-config），否则 Android 栈 dlsym 失败。
   - 或者反向：保留设备现有 `liblhdcv5BT_enc.so`，**在 Rust 侧补齐 28 个 `lhdcv5_util_*` 符号名**（把 `lhdcv5_enc_ffi_*` 改名/加 wrapper），让现有胶水无缝对接。**这条路的改动面更小**。
2. **修 `Cargo.toml`**：加 `android_logger` 依赖（或改 `lib.rs` 的 cfg 分支），把 `[build] rustflags` 挪到 `.cargo/config.toml`。
3. **把产物从静态库改成共享库**（设备是 `dlopen("liblhdcv5BT_enc.so")` + dlsym 模式，见 §7）。
4. **接受功能降级**：lossless / JAS / META / AR / LARC / VBR / S32 位深全部没有 → 即便跑通，也**不是完整的 LHDC V5**（Redmi Buds 5 Pro 的无损模式会失效）。
5. **性能验证**：release opt-level 0 → 必须改 `opt-level = 3` 并实测 48 kHz 实时编码余量。

> ⚠️ **未验证**：Rust 版编码器的输出码流能否被**真实耳机**（Redmi Buds 5 Pro）正确解码。README 只声称与 `WillyBilly06` 的**开源解码器**做 roundtrip 表现良好（"参数反馈到解码器表现优秀"），**不是**真机验证。`lhdc_enc_header.rs` 的位域与 Savitech 版 `lhdc_v5_enc_header.c` 同名，可信度较高，但需真机验证。

---

## 5. (d) `liblhdcv5.so` 版本比对：**不同版本**

### 5.1 哈希与版本串

| 文件 | 大小 | SHA256 | 版本串 |
|---|---|---|---|
| **设备** `/apex/com.android.btservices/lib64/liblhdcv5.so`（= `artifacts/libs/liblhdcv5.so`） | 3652400 | `2adef692d4b5a0d2a4ae47e0d8d799d39e98cc21e9d9e1822dc99e553254c10d` | **`LHDC_V5-5.0.5_8c9d77`** |
| 仓库 `AOSP/liblhdc-hyperos2_0_211_0/system/lib64/liblhdcv5.so` | 3542504 | `0fd2f572cc730c3e5d14ad2c73b9c0883dff4ca155c3dda1da386f7efc9e8856` | **`LHDC_V5-5.0.4_220426_114542`** |
| 仓库 `AOSP/other_so_files/enc/liblhdcv5.so` | 3542504 | `0fd2f572...`（同上，**字节相同**） | `LHDC_V5-5.0.4_220426_114542` |
| 仓库 `.../LHDC-magisk-11_arm64/system/lib64/liblhdcv5.so` | 3542504 | `0fd2f572...`（**字节相同**） | `LHDC_V5-5.0.4_220426_114542` |

**结论**：
1. 设备上的是 **5.0.5**，仓库里的三份（含 `liblhdc-hyperos2_0_211_0`）都是 **5.0.4**，且三份互为同一文件。→ **不同版本**。
2. `AOSP/liblhdc-hyperos2_0_211_0/` 目录名指向 HyperOS 2.0.211.0，但内容与 2021 年的日文 Magisk 模块完全相同 → **该目录的"来源标注"不可靠**（要么是 Magisk 模块作者从某台 HyperOS 机 dump 后打包、本仓库再复用；要么标注有误）。设备本体（OS2.0.12.0.ULOCNXM）的是 5.0.5，说明"HyperOS 2.0.211.0"与"OS2.0.12.0.ULOCNXM"不是同一固件版本。

### 5.2 符号表差异（说明 5.0.5 是功能超集）

| | 设备 5.0.5 | 仓库 5.0.4 |
|---|---|---|
| 导出 `lhdcv5_util_*` | **36** | 22 |
| 导出 `lhdcv5_*` 总数 | 54 | 34 |
| 额外拥有的 util 符号 | `get_current_mtu`, `set_target_mtu`, `get_lossless_enabled/status`, `set_lossless_enabled/status`, `reset_up/down_bitrate_vbr`, `reset_lossless_stat`, `set_vbr_up/dn_th/intv`, `vbr_process`, `get_bitrate_t`, `set_bitrate_t` | — |
| 未定义（依赖）符号 | `__android_log_print`, `__memcpy_chk`, `__stack_chk_fail`, `asinf`, `cos`, `cosf`, `expf`, `fmodf`, `memcpy`, `memset`, `printf`, `putchar`, `puts`, `sin`, `sincos`, `sinf` | 同 |

**5.0.5 相对 5.0.4 新增了：MTU 控制、Lossless 控制、VBR 全套、lossless 统计** —— 正是 V5 相对 V4 的核心增值功能。
`AOSP/liblhdcv5/include/lhdcv5_api.h`（34 个声明，含 VBR/lossless/MTU）**对应 5.0.6 头文件**，其声明的 34 个符号**在设备 5.0.5 上全部存在**（差集为空）→ **用 5.0.6 的胶水源码链接设备 5.0.5 库，符号层面可行**。

### 5.3 `liblhdc.so`（V3）也版本不同

| 文件 | 大小 | SHA256 |
|---|---|---|
| 设备 `/apex/.../liblhdc.so`（= `artifacts/libs/liblhdc.so`） | 3904016 | `87978989c2ac1e703ed4503c53525136a4137189a6bc7bc4edbf71643fa45d54` |
| 仓库 hyperos2_0_211_0 / magisk `liblhdc.so` | 4001592 | `3cdc73f296a56864e245dfca8385d2d4f9a21793d05336c754779802b984573a` |

→ 同样不同版本（设备那份**更小**，但 V3 编码器版本串未逐字比对，**未验证**）。

### 5.4 胶水层 `liblhdcv5BT_enc.so`

| 文件 | 大小 | SHA256 |
|---|---|---|
| 设备 `/apex/.../liblhdcv5BT_enc.so`（本次拉取分析） | 31448 | `4dc94f4213472c93b3e06c26eb05e6020ef625d1ae8b9f2fdf3eade1b7cd1718` |
| 仓库 magisk `.../system/lib64/liblhdcv5BT_enc.so` | 23248 | `7d1a6dd806f20f37e04f2cecebd1448f30d3b6c1997df99536b004f6993b2190` |

→ 不同（设备版更大，含 VBR/lossless 逻辑，与 §3.3 的 28 个导入吻合）。

---

## 6. (e) 是否包含蓝牙协议栈侧代码？

### 6.1 结论：**完全不含 Android 侧协议栈 / HAL / AIDL / HIDL 代码**

对全仓库做（排除 README）：

```bash
grep -rn -i -E "Lhdcv5Configuration|AIDL|HIDL|a2dp_encoding|IBluetoothAudio|vendor\.mediatek|Lhdcv5Capabilities|ndk" \
     --include=*.c --include=*.h --include=*.cpp --include=*.rs --include=*.bp --include=*.md .
```

**唯一命中**是 4 个 `Android.bp` 里被注释掉的 `// vndk:` 行（Savitech 原始模板里的注释）。→ **零命中 HAL/AIDL/HIDL 代码**。

### 6.2 ESP-IDF 目录确认：ESP32 Bluedroid 的 **Sink/解码器**，不是 Android 的

`ESP-IDF/bluedroid/stack/a2dp/a2dp_vendor_lhdcv5.c` 头部：

```c
/**
 * SPDX-FileCopyrightText: 2025 The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 * a2dp_vendor.c <-> a2dp_vendor_lhdcv5.c <-> a2dp_vendor_lhdcv5_decoder.c <-> lhdcv5BT_dec.h
 */
#include "a2d_int.h"
#include "common/bt_defs.h"
#include "common/bt_target.h"
#include "stack/a2d_api.h"
#include "stack/a2d_sbc.h"
#include "stack/a2dp_vendor_lhdcv5.h"
#include "stack/a2dp_vendor_lhdcv5_decoder.h"
#include "bt_av.h"
#if (defined(LHDCV5_DEC_INCLUDED) && LHDCV5_DEC_INCLUDED == TRUE)
```

**ESP-IDF 专有标识**：`a2d_int.h`、`bt_av.h`、`common/bt_defs.h`、`tA2D_STATUS`、`UINT8`、`LHDCV5_DEC_INCLUDED`、`LOG_ERROR`/`LOG_INFO`、`A2DP_INVALID_PARAMS`。这些在 Android `system/bt` 里**都不存在**（Android 用 `BtStatus`、`RawAddress`、`LOG_ERROR` 宏形式也不同）。

且它注册的是 **decoder interface**：

```c
static const tA2DP_DECODER_INTERFACE a2dp_decoder_interface_lhdcV5 = { ... };
const tA2DP_DECODER_INTERFACE* A2DP_GetVendorDecoderInterfaceLhdcV5(const uint8_t* p_codec_info) { ... }
```

→ **ESP32 是 A2DP Sink（耳机侧），手机是 Source（编码侧）**。README 亦明写："ESP32作为A2DP Sink连接手机且使用LHDCV5协商后，手机播放音乐时Sink端听到的是固定的标准音"。

### 6.3 ESP 目录对 Android 侧的参考价值：**中等，但方向是"能力声明"而非"通路"**

| 有价值的 | 说明 |
|---|---|
| `a2dp_vendor_lhdcv5_constants.h`（11222 B） | **LHDC V5 的 A2DP Codec Info（CIE）13 字节布局完整定义** —— 与 Android 栈 `A2DP_BuildInfoLhdcV5` / `A2DP_ParseInfoLhdcV5` 同源同格式 |
| `a2dp_vendor_lhdcv5.h`（15048 B） | `tA2DP_LHDCV5_CIE` 结构体（vendorId, codecId, sampleRate, bitsPerSample, channelMode, version, frameLenType, maxTargetBitrate, minTargetBitrate, hasFeatureAR/JAS/META/LL/LLESS48K/LLESS24Bit/LLESS96K[/LLESSRaw]） |
| `a2dp_vendor_lhdcv5.c` | `A2DP_BuildInfoLhdcV5` 逐字节实现（可当 13 字节布局的可执行规格） |
| 与 `libbluetooth_jni.so` 内嵌字符串的对应 | 栈里有 `%s: %s: %s isCap{%d} SR{%02X} BPS{%02X} Ver{%02X} FL{%02X} MBR{%02X} mBR{%02X} Feature{AR(%d) JAS(%d) META(%d) LL(%d) LLESS(%d) LLESS24(%d) LLESSRaw(%...)`，与 ESP 结构体字段一一对应 → **证明两侧同源** |

CIE 布局（P6/P7/P8/P9/P10 位域）关键值：

```
P6[5:0] SampleRate: 44100=0x20 48000=0x10 96000=0x04 192000=0x01
P7[2:0] BitDepth  : 16=0x04 24=0x02 32=0x01
P7[5:4] MaxBitRate: 900K=0x30 500K=0x20 400K=0x10 1000K=0x00(无上限)
P7[7:6] MinBitRate: 400K=0xC0 256K=0x80 160K=0x40 64K=0x00(无下限)
P8[3:0] Version   : VER_1=0x01
P8[5:4] FrameLen  : 5MS=0x10
P9[0]=3DAR P9[1]=JAS P9[2]=Meta P9[4]=LLESS96K P9[5]=LLESS24Bit P9[6]=LowLatency P9[7]=LLESS48K
P10[7]=LLESSRaw48K
VendorId=0x0000053A  CodecId=0x4C35  CODEC_LEN=13 → CIE_LEN=11
```

**无价值的**：`lhdcv5_util_dec.c`（README 明说是正弦波占位："仅具备模拟解码的能力…用 LHDCV5解码算法替换其中的正弦波（模拟解码）部分"）、`a2dp_vendor_lhdcv5_decoder.c`（解码通路）。

> 重要：**CIE 布局只决定"能不能协商成 V5"，不决定"配置能不能送到音频 HAL"**。后者是 Android 独有的 HIDL/AIDL 问题，ESP-IDF 完全没有这个概念（ESP32 没有 Android 音频 HAL）。

---

## 7. 补充独立验证：Android 栈到底向编码器库要什么

（本节是对参考仓库之外设备二进制的交叉验证，用于确定"替换编码器"的准确接口契约。）

对 `libbluetooth_jni_orig.so`（16729080 B, SHA256 `bedfcaa0...`）扫串，得到 **15 个 dlsym 名字 + 库名**：

```
0x002a191b  liblhdcv5BT_enc.so
0x001f5ba5  lhdcv5BT_free_handle
0x0020ee47  lhdcv5BT_adjust_bitrate
0x0021554f  lhdcv5BT_init_encoder
0x00221cd4  lhdcv5BT_get_bitrate
0x00234707  lhdcv5BT_set_min_bitrate
0x00234720  lhdcv5BT_set_ext_func_state
0x0023473c  lhdcv5BT_get_block_Size
0x0024dfd9  lhdcv5BT_get_handle
0x002685d7  lhdcv5BT_get_user_exApiver
0x0027b7a6  lhdcv5BT_encode
0x0027b7b6  lhdcv5BT_set_user_exconfig
0x0028861e  lhdcv5BT_set_user_exdata
0x002a192e  lhdcv5BT_set_max_bitrate
0x002adeb0  lhdcv5BT_get_user_exconfig
0x002b3ec9  lhdcv5BT_set_bitrate
```

→ 与 `AOSP/liblhdcv5/inc/lhdcv5BT.h` 的 15 个声明**逐一对应，无多无少**。

栈还大量使用扩展功能（说明 lossless/AR/JAS 是**实际会走**的路径）：

```
%s: %s: [LHDC V5] Has feature LOSSLESS (variable bitrate mode)
%s: %s: [LHDC V5] Has feature JAS / META / LOSSLESS RAW / AR_ON is set
%s: %s: LHDCv5 Lossless feature bit has reconfig, Need updated
%s: %s: updated LHDCv5 codec Lossless feature bit
%s: %s: [lib_ret] lhdc_set_ext_func JAS(0x%X) %d
%s: %s: [lib_ret] lhdc_set_ext_func AR(0x%X) %d
%s: %s: (lossless-24bit): use 24 bit mode / use 16 bit mode / use default 16 bit mode
%s: %s: set 48KHz sample rate for lossless
%s: %s: peer supports lossless , hdt is enabled on local
```

→ **Rust 版没有 `set_ext_func_state`，这些路径全部无法工作。**

### HAL 层独立验证（证明仓库帮不上忙）

```
$ adb shell su -c 'ls -la /vendor/lib64/hw/ | grep -i bluetooth'
android.hardware.bluetooth.audio@2.0-impl.so     88448
android.hardware.bluetooth.audio@2.1-impl.so    140800
vendor.mediatek.hardware.bluetooth.audio@2.1-impl.so   96824
vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so  173360
  ← 全是 HIDL 实现；没有任何 AIDL (V1-ndk / V2-ndk) 实现

$ adb shell su -c 'grep -A6 -i bluetooth /vendor/etc/vintf/manifest.xml'
android.hardware.bluetooth.audio @2.1 ::IBluetoothAudioProvidersFactory/default   (hidl)
vendor.mediatek.hardware.bluetooth.audio @2.2 ::IBluetoothAudioProvidersFactory/default  (hidl)
  ← vintf 只声明 HIDL，没有 format="aidl" 条目
```

对三份 HAL 库扫 `hdc` 字符串：

| 库 | `Lhdcv5*` | `lhdcConfig` |
|---|---|---|
| `hl_vendor.mediatek.hardware.bluetooth.audio@2.2.so`（HIDL 接口） | **0** | 0 |
| `hl_vendor.mediatek.hardware.bluetooth.audio@2.1-impl.so`（HIDL 实现） | **0** | ✅ `.lhdcConfig` |
| `/vendor/lib64/hw/vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so`（**设备真实实现**） | **0** | ✅ `.lhdcConfig = ` |
| `hl_vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`（**AIDL 接口，在 APEX 里**） | ✅ `Lhdcv5Configuration` + `Lhdcv5Capabilities` + `Lhdcv2Configuration` | — |

→ **AIDL 接口定义存在（在 APEX 中随协议栈分发），但设备厂商的 HAL 实现是 HIDL 且只认 `lhdcConfig`。这是 V5 通路的唯一硬阻断，参考仓库对此零帮助。**

---

## 8. (f) 结论：帮助边界

```
┌──────────────────────────────────────────────────────────────────────┐
│  LHDC V5 通路需要 4 层                                            │
├──────────────────────────────────────────────────────────────────────┤
│  L4  音频 HAL 传输   Lhdcv5Configuration (AIDL)  ── ✗ 设备缺厂商实现  │ ← 仓库 0 帮助
│  L3  蓝牙协议栈      a2dp_vendor_lhdcv5.cc        ── ✓ 设备已有(内嵌) │ ← 仓库 0 帮助（但设备已具备）
│  L2  编码器胶水      liblhdcv5BT_enc.so           ── ✓ 设备已有       │ ← 仓库 ★完整源码
│  L1  编码器算法      liblhdcv5.so                 ── ✓ 设备已有(5.0.5) │ ← 仓库 ★Rust 开源替代
└──────────────────────────────────────────────────────────────────────┘
```

### 8.1 仓库**解决**了的

1. **L1 编码器算法的可读实现**：Google Rust 版是**第一份功能完整的开源 LHDC V5 编码器**（README 语："据观测，这是开源的第一份内容功能完整的LHDC V5编码器"）。可用于：读代码理解 V5 码流、host 侧离线编码生成测试码流、真机验证编码器输出。
2. **L2 胶水层的完整源码**：`AOSP/liblhdcv5/src/lhdcv5BT_enc.c`（2387 行）与设备实际运行的胶水**同源同 API**（§3.3 交叉验证），可作为重建/替换胶水的起点。
3. **V5 配置面的权威定义**：`lhdcv5_api.h`（16 enum + 34 函数）+ `lhdcv5BT_ext_func.h`（META/AR 结构体）—— 理解"V5 到底有哪些可配置项"的最直接资料（已摘录到 `notes/`）。
4. **A2DP 能力声明（CIE）的完整字节布局**：`a2dp_vendor_lhdcv5_constants.h` —— 协商层可用。
5. **V5 解码原理的详细逆向文档**：README §3（帧头/解扰/SNS/FAC-Rice/反量化/IMDCT），可用于码流自检。

### 8.2 仓库**没有解决**的（= 本项目的卡点）

1. **HAL 层零覆盖**。仓库是"编解码器库 + 平台胶水"的集合，**不含任何 Android 音频 HAL / AIDL / HIDL 代码**。设备缺的是厂商 HAL 对 `Lhdcv5Configuration` 的实现（§7 已验证：设备厂商 HAL 只有 `lhdcConfig`）。**这不是一个可以通过换库解决的问题**——除非重写厂商 HAL（无源码）或把链路切到 AIDL 实现（设备无该实现）。
2. **Rust 版不能直接替换**：符号名不同（`lhdcv5_enc_ffi_*` ≠ `lhdcv5_util_*`）、缺 5 个 BT 侧函数、无 lossless/JAS/META/AR/LARC/VBR/S32、`Cargo.toml` 无法为 Android target 构建（缺 `android_logger`）。要可用必须做 §4.4 列出的 5 项改造。
3. **Rust 版无真机验证**：只有与开源解码器的 roundtrip，未在真耳机上验证。
4. **`LHDC-V5-Encoder`（C 版）与 `LHDC-V5-Decoder` 两个 submodule 未初始化**，本地为空目录。
5. **`liblhdc-hyperos2_0_211_0` 的 .so 是 5.0.4，比设备旧**，且与 Magisk 模块同源 —— 不能当作"设备固件基线"使用。

### 8.3 对"V5 通路"任务的净增量

| 若目标是… | 本仓库的贡献 |
|---|---|
| **A. 让配置送到 HAL（不伪装）** | **≈ 0**。需要的是 HAL 层（AIDL 实现或 HIDL 桥接），仓库完全没有。**当前的 P0/P1/P2 伪装方案仍然是唯一可行路线**，除非能在 APEX 内让协议栈走 AIDL 分支。 |
| **B. 换掉编码器为开源实现（去闭源依赖）** | **有实质帮助**，但工程量不小：改 Rust 构建（android_logger / 共享库 / opt-level）+ 补齐 15 个 BT 侧符号（或反向补齐 28 个 `lhdcv5_util_*` wrapper）+ 真机码流验证 + 接受 lossless 等特性缺失。 |
| **C. 理解 V5 配置面 / 码流格式** | **帮助很大**。`lhdcv5_api.h` + `lhdcv5BT_ext_func.h` + Rust `enc/process.rs` + CIE constants 是四份互补的规格。 |

**一句话边界**：**仓库打开了"编码器盒子"，但没碰"通路盒子"。** 本项目的阻断点（HAL 接口代次）恰好落在仓库覆盖范围之外。

---

## 9. 未验证 / 未知项

| 项 | 状态 |
|---|---|
| Rust 编码器在 aarch64 Android 上的实际编译 | **未验证**（本机无 rust 工具链） |
| Rust 编码器输出能否被 Redmi Buds 5 Pro 解码 | **未验证** |
| Rust 编码器在 48 kHz 实时编码的 CPU 占用 | **未验证**（release opt-level=0，需改） |
| 设备 `liblhdc.so`(V3) 的具体版本号 | **未验证**（仅哈希比对，未提取版本串） |
| `liblhdc-hyperos2_0_211_0` 目录的真实来源 | **未知**（哈希与 Magisk 模块相同，与目录名矛盾） |
| 缺失 5 个 dlsym 名字时栈的具体失败行为 | **未验证**（推测：`A2DP_VendorCodecLoadExternalLib` 失败 → codec 不可用） |
| `libbluetooth_jni.so` 中 `LHDC_V5-5.0.5` 是否被 V5 路径以外引用 | **未知** |

---

## 10. 产出物

| 文件 | 内容 |
|---|---|
| `d:/Cache/Hyperos/lhdcv5-tr/reference/notes/R5-AOSP-libhdcv5-headers-full.txt` | `lhdcv5_api.h` / `lhdcv5BT.h` / `lhdcv5BT_ext_func.h` **全文** + 大小/SHA256 |
| `d:/Cache/Hyperos/lhdcv5-tr/reference/notes/R5-Rust-lhdcv5-headers-full.txt` | Rust 版 `lhdcv5_api.h` / `lhdcv5BT.h` **全文** |
| `d:/Cache/Hyperos/lhdcv5-tr/reference/notes/R5-lhdcv5_api-结构体枚举清单.md` | 16 个 enum + 全部 struct 的**结构化速查表** + 34 个函数按功能分组 |
| `d:/Cache/Hyperos/lhdcv5-tr/reference/notes/R5-AOSP-glue-symbols.txt` | 胶水层调用的 28 个闭源符号 vs 头文件声明的 34 个，含差集 |
| 本文件 | R5 报告 |

## 11. 附：关键哈希速查

```
# 设备侧（实测，只读）
2adef692d4b5a0d2a4ae47e0d8d799d39e98cc21e9d9e1822dc99e553254c10d  /apex/com.android.btservices/lib64/liblhdcv5.so      (3652400)
4dc94f4213472c93b3e06c26eb05e6020ef625d1ae8b9f2fdf3eade1b7cd1718  /apex/com.android.btservices/lib64/liblhdcv5BT_enc.so (31448)
87978989c2ac1e703ed4503c53525136a4137189a6bc7bc4edbf71643fa45d54  /apex/com.android.btservices/lib64/liblhdc.so         (3904016)
d0e61d039a4d456111ed3596e62e499847e010429e76615821233cf2917bca2f  /apex/com.android.btservices/lib64/liblhdcBT_enc.so   (19064)
bedfcaa09b5246f4ddc610217a2a000425d21d581e59015fa6143639c9038347  libbluetooth_jni.so                                  (16729080)

# 仓库侧
0fd2f572cc730c3e5d14ad2c73b9c0883dff4ca155c3dda1da386f7efc9e8856  AOSP/liblhdc-hyperos2_0_211_0/system/lib64/liblhdcv5.so  (3542504, 5.0.4)
0fd2f572cc730c3e5d14ad2c73b9c0883dff4ca155c3dda1da386f7efc9e8856  AOSP/other_so_files/enc/liblhdcv5.so                     (3542504, 5.0.4)
3cdc73f296a56864e245dfca8385d2d4f9a21793d05336c754779802b984573a  AOSP/liblhdc-hyperos2_0_211_0/system/lib64/liblhdc.so    (4001592)
7d1a6dd806f20f37e04f2cecebd1448f30d3b6c1997df99536b004f6993b2190  .../LHDC-magisk-11_arm64/system/lib64/liblhdcv5BT_enc.so (23248)
```
