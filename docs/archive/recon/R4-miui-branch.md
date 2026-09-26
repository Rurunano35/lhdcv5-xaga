# R4 — 小米 MIUI 分支特性调查（LHDC V5 门控到底在门控什么）

> 调查对象：`d:/Cache/Hyperos/xaga-lhdcv5/artifacts/libs/libbluetooth_jni_orig.so`
> （SHA256 `bedfcaa09b5246f4ddc610217a2a000425d21d581e59015fa6143639c9038347`，16729080 B，与设备 `/apex/com.android.btservices/lib64/libbluetooth_jni.so` 同文件）
> 附加对象：`Bluetooth.apk` / `framework.jar` / `miui-framework.jar` / `miui-services.jar`、
> 设备侧 `/apex/.../vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`（本次拉取，只读）、`/vendor/etc/vintf/manifest.xml`（只读）
> 调查日期：2026-09-25　调查者：R4 子代理
> 分析脚本：`d:/Cache/Hyperos/lhdcv5-tr/analysis/scripts/r4_*.py`；原始输出：`d:/Cache/Hyperos/lhdcv5-tr/analysis/raw/04_*.txt`

---

## 0. 摘要（六个问题的直接回答）

| # | 问题 | 结论 | 置信度 |
|---|---|---|---|
| a | `MiuiBluetooth/system/stack/a2dp/a2dp_vendor_lhdcv5.cc` 路径是否存在/能否找到仓库 | **路径存在**，但完整路径是 `vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/stack/a2dp/a2dp_vendor_lhdcv5.cc`（MTK proprietary 树，非 AOSP）。**未在任何公开仓库找到该源码**（检索工具受限，见 §2.3） | 路径=已验证；公开性=未找到（不等于不存在） |
| b | createCodec 白名单是否就是那 5 个 codename、有无遗漏 | **完全正确，恰好 5 个**：`corot` `duchamp` `zircon` `rothko` `malachite`。无第 6 个；5 个名字都以立即数（movz/movk）拼出，**在 `.rodata`/`.dynstr` 中零命中** | 已验证 |
| c | 白名单门控什么？是"机型带 AIDL HAL"吗？ | 白名单**只门控 LHDC V5 codec 对象的创建**（`createCodec(12)` 返回 nullptr → V5 不进 codec 列表）。它是"本机带 MTK AIDL 蓝牙音频 HAL"的**静态代理**：HAL 代次判定在 `HalVersionManager` 里靠 `AServiceManager_checkService` 运行时探测，**代码上与 codename 零关联** | 已验证（代码路径）／推断（工程意图） |
| d | 小米在 framework/services/APK 里是否也有 V5 门控 | **没有 V5 codec 门控**。Bluetooth.apk 里另有一份 codename 名单 `corot duchamp rothko degas malachite`，但用于 **Latency(LL) 模式**，且与 native 名单**不同**（`degas` ≠ `zircon`） | 已验证 |
| e | MTK AIDL `vendor.mediatek.hardware.bluetooth.audio` 的定义 | 接口库在设备上（`-V1-ndk.so`），`Lhdcv5Configuration` 存在。字段布局、union tag、CodecType 取值本次从二进制反解（§6）。**公开 .aidl 未找到**；与 AOSP `android.hardware.bluetooth.audio` 是**并行两套独立接口**，不是替代 | 已验证（二进制）／公开性=未找到 |
| f | 给 xaga 装上/伪造 AIDL 实现后，白名单还会拦住 V5 吗 | **会拦住**。`createCodec` 的判定是纯属性读取，发生在任何 HAL 交互之前；HAL 代次变化不会改变 `ro.product.name`，因此 V5 仍被丢弃。要跑通 V5 必须**同时**绕过白名单 | 已验证（调用链 + 代码结构） |

**本次调查最重要的新发现**（超出既有报告）：

1. 白名单**只**出现在 `A2dpCodecConfig::createCodec` 一个函数里，全二进制仅此一处（§3.4）。
2. `A2dpCodecConfigLhdcV5Source` 的**静态能力表**在加载时由 `_GLOBAL__sub_I_a2dp_vendor_lhdcv5.cc` 按 `ro.product.device` 初始化：`corot`→0x15、`rothko`→0x35、**其它一律 0x15（= corot 的取值）**。即 xaga 拿到的是"和 corot 一样"的能力值 —— 这里**不是**阻断点（§4.4）。
3. HIDL 与 MTK AIDL 两张分发表的**对照**：HIDL `table[12]` = 错误分支；MTK AIDL `table[12]` = `A2dpLhdcv5ToHalConfig`（同一个函数同时处理 10/12，映射到 AIDL 枚举 9/11）。这直接证明"白名单 ⇔ 该机型走 AIDL 通路"（§4.5）。
4. xaga 运行时**从未**进入 AIDL 通路（日志中只有 `a2dp_encoding_hidl.cc`，`a2dp_encoding_aidl.cc` 零出现）（§4.6）。

---

## 1. 方法与可复现环境

```bash
export PATH="/d/Tools/Anaconda3/envs/py3123:/d/Tools/Anaconda3/envs/py3123/Scripts:$PATH"
export PYTHONPATH="d:/Cache/Hyperos/pylibs"   # capstone 5.0.7 / pyelftools 0.33
export MSYS_NO_PATHCONV=1
```

| 脚本 | 作用 |
|---|---|
| `scripts/r4_disasm.py <va> <len>` | 任意地址反汇编（`libbluetooth_jni.so` 的 `sh_addr == sh_offset`，VA 即文件偏移） |
| `scripts/r4_plt.py <addr>...` | PLT 桩 → dynsym 名（解析 `.rela.plt` + 桩内 `adrp/ldr` 反查 GOT 槽） |
| `scripts/r4_sym2.py <substr>` | dynsym 符号查询（18254 条；**注意** `.gnu_debugdata` 迷你符号表缺少 0x763xxx 段符号，早期脚本 `analysis/bluetooth-stack/syms.py` 用它，会漏掉 createCodec） |
| `scripts/r4_refs.py` | 全 `.text` 扫描 `adrp+add` 字符串引用（90513 条），输出 `raw/04_refs.txt` |
| `scripts/r4_props2.py` | 全 `.text` 扫描 `osi_property_get`/`__system_property_get` 调用点及属性名（225 条），输出 `raw/04_props_callsites.txt` |
| `scripts/r4_imm.py` | 全 `.text` 扫描 movz/movk 立即数，重建 codename 常量链，输出 `raw/04_imm_chains.txt` |
| `scripts/r4_callers2.py` | 通过 PLT 桩反查调用者（库内调用一律走 PLT） |
| `scripts/r4_branch.py` | 反查 `b`/`bl` 目标 |
| `scripts/r4_dex.py` | 自写 dex 解析（string/method/class + `const-string` 扫描），扫 jar/apk |
| `scripts/r4_aidl*.py` | 解析 `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`（该文件 `.data` 段 `va != off`，需段映射） |

**符号来源说明**：`libbluetooth_jni.so` 的 `.gnu_debugdata`（xz，位于文件偏移 `0xfa7ecc`，长度 `0x4be6c`，解压后 2213032 B = `analysis/bluetooth-stack/debugdata.elf`）**缺少 0x763xxx 段的符号**，因此 createCodec 的符号名来自 `.dynsym`（18254 条，含大量 local 符号）：

```
$ python r4_sym2.py createCodec
0x763280    824 _ZN15A2dpCodecConfig11createCodecE23btav_a2dp_codec_index_t26btav_a2dp_codec_priority_t
```

---

## 2. (a) MIUI/MiuiBluetooth 源码线索

### 2.1 二进制内嵌 `__FILE__` 路径（**已验证事实**）

`libbluetooth_jni.so` 里内嵌了完整的源码路径字符串（`__android_log_print` / `LOG()` 的 `__FILE__`）。本次全量提取到 **352 条**含 `MiuiBluetooth` 的路径（`raw/04_refs.txt` 派生）。与 LHDC 直接相关的 9 条：

| 地址 | 路径 |
|---|---|
| `0x2b3d51` | `vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/stack/a2dp/a2dp_vendor_lhdcv5.cc` |
| `0x25ad8c` | `.../MiuiBluetooth/system/stack/a2dp/a2dp_vendor_lhdcv3.cc` |
| `0x2684b7` | `.../MiuiBluetooth/system/stack/a2dp/a2dp_vendor_lhdcv2.cc` |
| `0x2a14fc` | `.../MiuiBluetooth/system/stack/a2dp/a2dp_codec_config.cc` |
| `0x25be4e` | `.../MiuiBluetooth/system/mediatek/audio_hal_interface/hal_version_manager.cc` |
| `0x228b7e` | `.../MiuiBluetooth/system/mediatek/audio_hal_interface/hidl/a2dp_encoding_hidl.cc` |
| `0x289110` | `.../MiuiBluetooth/system/mediatek/audio_hal_interface/aidl/a2dp_encoding_aidl.cc` |
| `0x28f43a` | `.../MiuiBluetooth/system/audio_hal_interface/hidl/a2dp_encoding_hidl.cc` |
| `0x25bedd` | `.../MiuiBluetooth/system/audio_hal_interface/aidl/a2dp_encoding_aidl.cc` |

**结论（a-1）**：报告提到的 `MiuiBluetooth/system/stack/a2dp/a2dp_vendor_lhdcv5.cc` **确实存在**，其完整前缀是 `vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/` —— 这是 **MediaTek proprietary 的 vendor 树**（路径里就有 `proprietary`），不是 AOSP，也不是 `packages/modules/Bluetooth`。

**交叉验证**：`a2dp_vendor_lhdcv5.cc` 这个字符串被以下函数引用（`r4_strref.py 0x2b3d51`），全部属于 LHDC V5 实现：
```
0x796ac0  A2DP_VendorGetBitRateLhdcV5+0x90
0x79b3e0  A2dpCodecConfigLhdcV5Base::setCodecConfig+0x2100
0x79b418  A2dpCodecConfigLhdcV5Base::setCodecConfig+0x2138
0x79b748  A2dpCodecConfigLhdcV5Base::setPeerCodecCapabilities+0x2b8
```

`a2dp_codec_config.cc` 被 `A2dpCodecs::setCodecOtaConfig+0x420 (0x7686c0)` 引用；createCodec 与它在同一地址邻域（0x763280–0x769xxx），故 **推断** createCodec 亦在 `a2dp_codec_config.cc`（推断，未直接证据 —— createCodec 自身的日志不打印 `__FILE__`）。

### 2.2 二进制里能看到的"源码结构图"（部分）

`MiuiBluetooth/system/` 下可见目录：`stack/{a2dp,avdt,btm,gatt,l2cap,pan,rfcomm,smp,srvc}`、`bta/{ag,av,le_audio,gatt,jv,vc,hf_client}`、`btif/src`、`audio_hal_interface/{hidl,aidl}`、`mediatek/{audio_hal_interface,hci,config,packet}`、`main/shim`、`osi/src`、`gd/rust/common/src/init_flags.rs`、`packet/`。
→ 即 **MIUI 把 AOSP 的 `system/` 与 MTK 自己的 `mediatek/` 合并成一个模块**，`audio_hal_interface` 同时存在 AOSP 版与 `mediatek/` 版两套（共 4 个 HAL 后端实现）。

### 2.3 公开仓库检索（**未找到**，含工具限制说明）

检索手段与结果：

| 手段 | 命令 | 结果 |
|---|---|---|
| WebSearch 工具 | 多次查询 `"a2dp_vendor_lhdcv5"` / `MiuiBluetooth github` | **工具在本环境不可用**（返回空壳，未产出结果） |
| GitHub REST API | `curl api.github.com/search/repositories?q=MiuiBluetooth` | 首次 JSON 解析失败，随后 `API rate limit exceeded`（未认证） |
| grep.app | `curl grep.app/api/search?q=a2dp_vendor_lhdcv5` | HTTP 429 / Vercel Security Checkpoint 拦截 |
| Bing / DuckDuckGo / Mojeek | `curl` | 被重定向到 cn.bing.com 且查询被丢弃；DDG/Mojeek 直接不可达 |
| 百度 | `curl www.baidu.com/s?wd=MiuiBluetooth github 小米 源码` | 无相关结果（仅有泛泛的 AIDL 教程页） |
| 本地参考仓库 | `d:/Cache/Hyperos/lhdcv5-tr/reference/liblhdc-collections/` | 含 AOSP 上游的 **`Bluetooth-refs_heads_android17-release-system-audio-codecs-lhdcv5.tar.gz`**（AOSP `system/audio/codecs/lhdcv5` 的**编码器库**源码：`lhdcv5BT_enc.c`、`lhdcv5_api.h` 等），**不是** MIUI 的 `a2dp_vendor_lhdcv5.cc` stack 实现 |

**结论（a-2）**：**未能找到公开的 MiuiBluetooth 源码仓库**。但可以给出明确的检索目标路径：`vendor/mediatek/proprietary/packages/modules/MiuiBluetooth/system/stack/a2dp/a2dp_vendor_lhdcv5.cc`。考虑到 `proprietary` 字样与 MTK 授权惯例，该树**大概率不公开**（此为推断，非已验证事实）。后续若要找，建议方向：MTK 平台机型（天玑 8000/9000 系）的 vendor 树 dump / GPL 发布包 / `vendor/mediatek/proprietary` 泄漏镜像。

---

## 3. (b) 独立验证 createCodec 白名单

### 3.1 函数全貌

`A2dpCodecConfig::createCodec(btav_a2dp_codec_index_t, btav_a2dp_codec_priority_t)` @ `0x763280`，size 824（`.dynsym`）。

```asm
0x763280  str  x30,[x18],#8            ; 栈保护
0x763284  sub  sp,sp,#0xa0
...
0x7632e4  cmp  w21,#0x10               ; w21 = codec index
0x7632e8  b.hi #0x763588               ; >16 → 返回 nullptr
0x7632ec  mov  w8,w21
0x7632f0  adrp x9,#0x2be000
0x7632f4  add  x9,x9,#0xfe4            ; 跳转表 @0x2befe4
0x7632f8  adr  x10,#0x763308
0x7632fc  ldrb w11,[x9,x8]
0x763300  add  x10,x10,w11,lsl#2
0x763304  br   x10
```

跳转表 `0x2befe4`（17 项，`r4_util.py` 读出）→ 每项指向"`operator new(0x1e8)` + 构造函数"块：

| idx | 目标 | 构造函数（PLT 解析） | 含义 |
|---|---|---|---|
| 0 | 0x763308 | `A2dpCodecConfigSbcSource` | SBC |
| 1 | 0x7633b0 | `A2dpCodecConfigAacSource` | AAC |
| 2 | 0x7633c8 | `A2dpCodecConfigAptx` | aptX |
| 3 | 0x763368 | `A2dpCodecConfigAptxHd` | aptX HD |
| 4 | 0x763338 | `A2dpCodecConfigLdacSource` | LDAC |
| 5,7,8,11 | 0x763588 | — | 返回 nullptr |
| 6 | 0x763380 | `A2dpCodecConfigOpusSource` | Opus |
| 9 | 0x7633e0 | `A2dpCodecConfigLhdcV2` | LHDC V2 |
| 10 | 0x7633f8 | `A2dpCodecConfigLhdcV3` | LHDC V3 |
| **12** | **0x763428** | **`A2dpCodecConfigLhdcV5Source`** | **LHDC V5 ← 白名单所在** |
| 13..16 | 0x763410/0x763320/0x763398/0x763350 | SbcSink / AacSink / LdacSink / OpusSink | sink 变体 |

**白名单检查只存在于 idx=12 这一个分支块（0x763428–0x76355c）内**，其余 12 个"创建成功"的分支块（0x763308…0x76341c）**没有任何属性读取**（逐块反汇编确认）。

### 3.2 idx=12 分支逐条解码（**已验证事实**）

```asm
0x763428  movi v0.2d,#0
0x76342c  adrp x0,#0x260000
0x763430  add  x0,x0,#0xc62          ; x0 = 0x260c62 = "ro.product.name"
0x763434  adrp x2,#0x22b000
0x763438  add  x2,x2,#0xc67          ; x2 = 0x22bc67 = "" （默认值）
0x76343c  mov  x1,sp                 ; x1 = 栈上 92 字节缓冲区（已清零）
0x763450  bl   #0xf45740             ; → _Z16osi_property_getPKcPcS0_   (PLT 解析)
```
> 注意：这里调用的是 **`osi_property_get`**（不是报告 §3.4 写的 `__system_property_get`）—— 名称由 PLT 桩反查 `.rela.plt` 得到（`r4_plt.py 0xf45740`）。

随后是**纯立即数**比对（无字符串常量）：

| 步骤 | 指令 | 立即数展开 | 匹配 |
|---|---|---|---|
| 1 | `0x763458 mov w10,#0x6f63` + `0x763460 movk w10,#0x6f72,lsl#16`；`0x76345c ldrh w9,[sp,#4]`；`0x763468 mov w8,#0x74`；`0x76346c ccmp w9,w8,#0,eq`；`0x763470 b.eq 0x763528` | w10=0x6f726f63 → 字节 `63 6f 72 6f` = **"coro"**；w9=sp+4 低 2 字节 vs 0x74 = **'t'**+NUL | **corot** |
| 2 | `0x763474 mov x9,#0x7564` + `movk #0x6863,lsl#16` + `movk #0x6d61,lsl#32` + `movk #0x70,lsl#48`；`0x763488 cmp x8,x9`；`b.eq` | x9 = `64 75 63 68 61 6d 70 00` = **"duchamp"+NUL**（8 字节全比） | **duchamp** |
| 3 | `0x763494 mov w10,#0x697a` + `movk #0x6372,lsl#16`；`0x763498 ldur w9,[sp,#3]`；`0x7634a4 mov w8,#0x6f63` + `movk #0x6e,lsl#16`；`ccmp` | w10=`7a 69 72 63`=**"zirc"**；w9=buf[3..6] vs `63 6f 6e 00`=**"con"+NUL** | **zircon** |
| 4 | `0x7634b8 mov w10,#0x6f72` + `movk #0x6874,lsl#16`；`0x7634bc ldur w9,[sp,#3]`；`0x7634c8 mov w8,#0x6b68`+`movk #0x6f,lsl#16` | w10=`72 6f 74 68`=**"roth"**；w9 vs `68 6b 6f 00`=**"hko"+NUL** | **rothko** |
| 5 | `0x7634d8 mov x10,#0x616d`+`movk #0x616c,lsl#16`+`movk #0x6863,lsl#32`+`movk #0x7469,lsl#48`；`0x7634e4 ldrh w9,[sp,#8]`；`0x7634f4 mov w8,#0x65` | x10=`6d 61 6c 61 63 68 69 74`=**"malachit"**；w9=buf[8..9] vs 0x65=**'e'**+NUL | **malachite** |
| 落空 | `0x763500-0x763524` | `adrp x2,#0x2b3000;add x2,x2,#0xa2b` = `0x2b3a2b` = `"%s: %s: LHDCV5 not matches"`；`x3=x4=0x29b279`="createCodec"；`x1=0x25abd8`="a2dp_codec"；`w0=6`(ERROR) | → `0x763584` 返回 nullptr |
| 命中 | `0x763528-0x76355c` | `x2=0x227e5a` = `"%s: %s: LHDCV5 matches "`；`w0=4`(INFO)；然后 `operator new(0x1e8)` + `A2dpCodecConfigLhdcV5Source` 构造 | 返回对象 |

**分支原始字节**（用于身份校验，`r4_util.rd`）：

```
0x763470: c0 05 00 54   b.eq → 0x763528   (corot)
0x76348c: e0 04 00 54   b.eq → 0x763528   (duchamp)
0x7634b0: c0 03 00 54   b.eq → 0x763528   (zircon)
0x7634d4: a0 02 00 54   b.eq → 0x763528   (rothko)
0x7634fc: 60 01 00 54   b.eq → 0x763528   (malachite)
```

**常量原始字节**（movz/movk 编码，供独立复核）：

```
0x763458: 6a ec 8d 52   0x763460: 4a ee ad 72   ; "coro"
0x763474: 89 ac 8e d2   0x76347c: 69 0c ad f2   0x763480: 29 ac cd f2   0x763484: 09 0e e0 f2   ; "duchamp"
0x763494: 4a 2f 8d 52   0x76349c: 4a 6e ac 72   0x7634a4: 68 ec 8d 52   0x7634a8: c8 0d a0 72   ; "zirc"/"con"
0x7634b8: 4a ee 8d 52   0x7634c0: 8a 0e ad 72   0x7634c8: 08 6d 8d 52   0x7634cc: e8 0d a0 72   ; "roth"/"hko"
0x7634d8: aa 2d 8c d2   0x7634e0: 8a 2d ac f2   0x7634e8: 6a 0c cd f2   0x7634ec: 2a 8d ee f2   0x7634f4: a8 0c 80 52 ; "malachit"/'e'
```

### 3.3 无第 6 个（**已验证事实**）

- 第 5 个 `b.eq`（`0x7634fc`）之后直接是落空日志块（`0x763500`），中间没有任何其它属性读取或比对。
- 全量 `movz/movk` 常量链扫描（`r4_imm.py`，`raw/04_imm_chains.txt`）：`corot/duchamp/zircon/rothko/malachite` 的**五者同时出现**只发生在 `createCodec`；其它函数只出现其中一部分（详见 §4.3 表）。

### 3.4 codename 不是字符串常量（**已验证事实**）

对 `.rodata`（0x1ec380+0x138b66）与 `.dynstr`（0x91634+0x117bd9）做 ASCII 全量搜索：

```
corot / duchamp / zircon / rothko / malachite : .rodata 0 hit, .dynstr 0 hit
LHDCV5 : .rodata 4 hits (0x227e62, 0x2ada29, 0x2b3a33, 0x303104)
```
→ 5 个 codename **完全以指令立即数形式存在**，这也是 `strings | grep` 找不到它们的原因（报告 §3.4 的方法学教训成立）。

---

## 4. (c) 白名单到底在门控什么

### 4.1 门控的作用域：只影响 V5 codec 的创建

`A2dpCodecConfig::createCodec` 的**唯一调用者**是 `A2dpCodecs::init()`（`r4_callers2.py`）：

```
=== _ZN15A2dpCodecConfig11createCodecE23... ===
  0x7664c8  in _ZN10A2dpCodecs4initEv+0x248
```

调用点上下文（`A2dpCodecs::init` @ `0x766280`，size 2108）：

```asm
0x766414  add  w22,w22,#1              ; 循环变量 = codec index
0x766418  cmp  w22,#0x11               ; 到 17 结束 → 遍历 idx 0..16（含 12）
0x76641c  b.eq #0x7666a0
...
0x7664c0  mov  w0,w22
0x7664c4  mov  w1,w23
0x7664c8  bl   #0xf4b0b0               ; → A2dpCodecConfig::createCodec
0x7664cc  cbz  x0,#0x766414            ; ★ 返回 nullptr → 直接跳过，不插入列表
0x7664d0  mov  x28,x0
...
0x766520  ldr  w8,[x28,#0x50]          ; 取 priority
0x766524  cmn  w8,#1
0x766528  b.eq #0x7665a4               ; priority == -1 → 同样跳过
0x76652c ...                           ; 否则插入 std::map<index, A2dpCodecConfig*>
```

→ **白名单的唯一后果**：`codec_index = 12`（LHDC V5）的配置对象不被创建 → 不进入 `mCodecsLocalCapabilities` → 不参与能力协商。除此之外**没有别的副作用**（不写属性、不改变 HAL 状态、不影响其它 codec）。

### 4.2 `ro.product.name` 在全库只有 2 个读取点（**已验证事实**）

`r4_refs.py` 全 `.text` 扫描（90513 条 adrp+add 字符串引用）：

```
'ro.product.name' @0x260c62  sites:
   _ZN12BtifAvSource4InitEP23btav_source_callbacks_tiRKNSt3__16vectorI24btav_a2dp_codec_config_tNS2_9allocatorIS4_EEEES9_+0xcc@0x6ec02c
   _ZN15A2dpCodecConfig11createCodecE23btav_a2dp_codec_index_t26btav_a2dp_codec_priority_t+0x1ac@0x76342c
'ro.product.device' @0x26c72c  sites:
   _Z18bta_dm_set_sar_dsij+0xa4@0x5b4754
   _Z18handle_rc_featuresP19btif_rc_device_cb_t+0x1ac@0x72fb8c
   _ZN9bluetooth5avrcp23IsAbsoluteVolumeEnabledEPK10RawAddress+0x2c@0x74213c
   _Z21SupportDiffSampleRatev+0x18@0x790b38
   ?@0x795d10        （= _GLOBAL__sub_I_a2dp_vendor_lhdcv3.cc）
   _Z23SupportDiffV5SampleRatev+0x18@0x795dd8
   （另有 _GLOBAL__sub_I_a2dp_vendor_lhdcv5.cc@0x79c1dc，见 §4.4）
```

### 4.3 全库其它 codename 门控（**已验证事实**，含与本问题无关者）

`r4_imm.py` 重建 movz/movk 常量链，命中 codename 的函数：

| 函数 | 读取属性 | codename 集合 | 作用（推断） |
|---|---|---|---|
| `A2dpCodecConfig::createCodec+0x1d8..+0x274` | `ro.product.name` | **corot, duchamp, zircon, rothko, malachite**（恰好 5） | **LHDC V5 准入** ← 本问题 |
| `BtifAvSource::Init+0xe0..+0x53c` | `ro.product.name` | 长名单：`yunluo, daumier, rubens, **xaga**, matisse, ruby, ruby_in, ruby_eea, ruby_global, ruby_ru, ruby_tr, ruby_id, ruby_pro, pyro_in, pyro_ru, pyro_tr, rubyplus, corot, plato_gl, plato_eea, plato_ru, plato_tr, plato_id, duchamp, aristotle_global, aristotle_eea, aristotle_ru, aristotle_tr, aristotle_id, rothko, …` | **LHDC codec（V2/V3）使能**；命中则 `a2dp_lhdc_codec_enabled=1`，日志 `btif_av: Init: Init: User: ro.product.name = <name>`（**xaga 在名单内**） |
| `bta_dm_set_sar_dsij+0x140..+0x238` | `ro.product.device` + `ro.boot.hwc` | `xaga, GL/G4, plato…, aristotle…, XG04, zircon, duchamp, rothko` | SAR / DSI 功率表（与 LHDC 无关） |
| `_GLOBAL__sub_I_a2dp_vendor_lhdcv3.cc`（@0x795ce0） | `ro.product.device` | `corot` | V3 静态能力表初始化（§4.4） |
| `_GLOBAL__sub_I_a2dp_vendor_lhdcv5.cc`（@0x79c1b0） | `ro.product.device` | `corot, rothko` | V5 静态能力表初始化（§4.4） |
| `SupportDiffSampleRate()` @0x790b20（164 B） | `ro.product.device` | `corot` | 返回 5（corot）/ 15（其它）—— **死代码**（无调用者、无 adrp+add 引用，仅因导出符号而保留） |
| `SupportDiffV5SampleRate()` @0x795dc0（200 B） | `ro.product.device` | `corot, rothko` | 返回 0x15（corot 与默认）/ 0x35（rothko）—— **死代码**（同上） |

> 死代码判定依据：`r4_callers2.py`（无 PLT 桩、无调用者）+ `r4_adrpadd.py`（无 adrp+add 取址）+ 全文件 8 字节指针搜索（唯一命中落在 `.dynstr` 内的巧合字节）。其**内联副本**才是实际生效的（见 §4.4）。

### 4.4 V5 的第二个设备门控：静态能力表（**已验证事实**，非阻断点）

`_GLOBAL__sub_I_a2dp_vendor_lhdcv5.cc`（0x79c1b0，模块加载时执行）读 `ro.product.device` 并写静态结构 `0xfdd238`：

```asm
0x79c1dc  add  x0,x0,#0x72c        ; "ro.product.device"
0x79c210  bl   osi_property_get
0x79c224  cmp  w8,w10              ; w10 = "coro"
0x79c228  mov  w8,#0x74            ; 't'
0x79c22c  ccmp w9,w8,#0,eq         ; → "corot"?
0x79c230  mov  w8,#0x15            ; ★ 默认值 0x15 = 21
0x79c234  b.eq #0x79c268
0x79c238  ... "roth" + "hko"       ; → "rothko"?
0x79c260  mov  w9,#0x35            ; 0x35 = 53
0x79c264  csel w8,w9,w8,ne         ; rothko → 0x35，其它 → 0x15
0x79c268  ...
0x79c278  add  x9,x9,#0x23e        ; 0xfdd23e = 0xfdd238+6
0x79c280  strb w8,[x9]             ; 静态结构 +6 = 0x15 或 0x35
0x79c284  stur d0,[x9,#1]          ; +7..+14 ← .rodata 0x2b9e00 = 06 01 01 10 00 40 00 00
0x79c288  stur w10,[x9,#9]         ; +15..+18 = 0x01010100
0x79c28c  strb wzr,[x9,#0xd]       ; +19 = 0
```

消费者：`A2dpCodecConfigLhdcV5Source` 构造函数（0x799130）从 `0xfdd23e` 取 3 字节做位解包，写入 codec 对象的 `+0xd0/+0xd4/+0xd8`：

```asm
0x7991c0  mov  w12,#0x2b           ; 采样率掩码常量 0x2b
0x7991c4  ldrb w10,[x9]            ; = 0x15 或 0x35
0x7991d4  rbit w10,w10
0x7991e0  and  w10,w12,w10,lsr#26  ; → 0x15 ⇒ 0x2b & rev6(0x15)=42 ⇒ 0x2a ; 0x35 ⇒ 0x2b & 43 ⇒ 0x2b
0x7991f4  stp  w10,w11,[x19,#0xd0]
0x7991f8  str  w12,[x19,#0xd8]
```

**关键结论**：`xaga` 不在 `{corot, rothko}` 内 → 取**默认值 0x15**，即**与 corot 完全相同**的能力值（两者位解包后同为 `0x2a`；rothko 为 `0x2b`，多出 1 个采样率位 —— 若该字段是采样率掩码，则对应 44100Hz，此为**推断**）。**这个门控对 xaga 不构成阻断**。

同理 `a2dp_vendor_lhdcv3.cc` 的全局构造器（0x795ce0）对 `ro.product.device` 的 `corot` 判定把静态结构 `0xfdd220` 的 +6 字节设为 5（corot）/ 0xf（其它）—— xaga 走默认分支（与既有报告"xaga 的 LHDC V3 可用"一致）。

### 4.5 HAL 代次的判定者：HalVersionManager（与 codename 无关）

**（1）判定逻辑**（`vendor::mediatek::bluetooth::audio::HalVersionManager` @0x861370，1284 B）：

```asm
0x861414  strh wzr,[x19,#0x28]        ; hal_version=0, le_audio_hal_version=0
0x861424  bl   #0xf4f5b0              ; AServiceManager_checkService( <静态 std::string @0xff42a8> )
0x861428  cbz  x0,#0x861534           ; 未找到 → 转 HIDL 探测
0x86142c  mov  w8,#3
0x861430  strb w8,[x19,#0x28]         ; ★ hal_version = 3  ← MTK AIDL 存在
...
0x861534  ...  AServiceManager_checkService( <静态 std::string @0xff42c0> )   ; AOSP AIDL
0x861550  cbz  x0,#0x861434
0x861554  mov  w8,#0x404
0x861558  strh w8,[x19,#0x28]         ; ★ hal_version = 4（含 le_audio=4）← AOSP AIDL 存在
...
0x8614c4..0x861628                     ; HIDL 探测：defaultServiceManager()->listByInterface(...)
                                       ; → hal_version = 1 (@2.2) 或 2 (@2.1)
```
> 设备日志证实这两个 `checkService` 的目标就是：
> `HalVersionManager: aidl vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default`
> `HalVersionManager: hidl vendor.mediatek.hardware.bluetooth.audio@2.2::IBluetoothAudioProvidersFactory`
> 且 `hal_version_manager.cc` 的 `__FILE__` 就在 0x25be4e（已验证）。

**（2）代次 → 后端**（`GetHalTransport()` @0x860de0 的映射常量 `0x0000000402030300` 逐字节取值）：

| hal_version | GetHalTransport 返回 | `vendor::mediatek::bluetooth::audio::a2dp::init`（@0x824ed0）分支 | 实际后端 |
|---|---|---|---|
| 1 / 2 | 3 | `b 0xf4e6c0` = `vendor::mediatek::bluetooth::audio::hidl::a2dp::init` | **MTK HIDL** |
| **3（MTK AIDL）** | 2 | `b 0xf4e0a0` = `vendor::mediatek::bluetooth::audio::aidl::a2dp::init` | **MTK AIDL** |
| 4（AOSP AIDL） | 4 | `b 0xf4ec10` = `bluetooth::audio::a2dp::init` | AOSP |
| 0 / ≥5 | 0 | 同上（else）→ MTK AIDL | — |

**（3）两张分发表的对照 —— 直接证明"白名单 ⇔ AIDL 通路"（**本报告最关键的一张表**）**

| codec_type | HIDL 表 @0x2c5620（base 0x825f34，文件 `mediatek/.../hidl/a2dp_encoding_hidl.cc`） | MTK AIDL 表 @0x2c577d（base 0x83798c，文件 `mediatek/.../aidl/a2dp_encoding_aidl.cc`） |
|---|---|---|
| 0 | `A2dpSbcToHalConfig` | `A2dpSbcToHalConfig` |
| 1 | `A2dpAacToHalConfig` | `A2dpAacToHalConfig` |
| 2/3 | `A2dpAptxToHalConfig` | `A2dpAptxToHalConfig` |
| 4 | `A2dpLdacToHalConfig` | `A2dpLdacToHalConfig` |
| 9 | `A2dpLhdcV2ToHalConfig` | `A2dpLhdcV2ToHalConfig` |
| 10 (V3) | `A2dpLhdcV3ToHalConfig` | `A2dpLhdcv5ToHalConfig`（0x837a84 → 0xf4e470） |
| 11 | 错误分支 0x82609c | 错误分支 |
| **12 (V5)** | **错误分支 0x82609c** ← 阻断点 | **`A2dpLhdcv5ToHalConfig`（与 idx 10 同一目标）** ✅ |

- HIDL 错误分支内的 `mov w2,#0x167` = **359**，与设备日志 `a2dp_encoding_hidl.cc(359) Unknown codec_type=12` 精确吻合（既有报告的 P1 结论独立复现）。
- MTK AIDL 的 `A2dpLhdcv5ToHalConfig`（0x83fd80）**同时接受 10 与 12**，并把它们映射到 AIDL 枚举 9（V3）/11（V5）：
  ```asm
  0x83fdcc  ldr  w8,[sp,#0x30]
  0x83fdd0  cmp  w8,#0xc ; V5
  0x83fdd4  b.eq ...
  0x83fdd8  cmp  w8,#0xa ; V3
  0x83fddc  b.ne → return false
  0x83fe08  b.eq 0x83fe24  ; V3
  0x83fe14  mov  w8,#0xb   ; ★ V5 → AIDL CodecType 11
  0x83fe24  mov  w8,#9     ; ★ V3 → AIDL CodecType 9
  ```

**（4）运行时证据（xaga 实际走哪条）**

```
$ grep -o -E "a2dp_encoding_(hidl|aidl)\.cc\([0-9]+\)" artifacts/logs/*.log | sort -u | head
a2dp_encoding_hidl.cc(112)] StartRequestlock pending_suspend_lock_
a2dp_encoding_hidl.cc(383)] a2dp_get_selected_hal_codec_config: CodecConfiguration={.codecType = LHDC, ...
... （共 30+ 种行号，全部为 hidl 文件）
$ grep -o -E "a2dp_encoding_aidl\.cc\([0-9]+\)" artifacts/logs/*.log
（空）
```
→ xaga 运行时 `hal_version ∈ {1,2}`（MTK HIDL），**从未**进入 MTK AIDL 通路。

**（5）设备 vintf 声明（**已验证事实**）**

```
$ adb shell grep -A6 -i "bluetooth.audio" /vendor/etc/vintf/manifest.xml
  <name>android.hardware.bluetooth.audio</name>
  <transport>hwbinder</transport>          ← HIDL
  <version>2.1</version>
  <interface><name>IBluetoothAudioProvidersFactory</name><instance>default</instance></interface>
  <name>vendor.mediatek.hardware.bluetooth.audio</name>
  <transport>hwbinder</transport>          ← HIDL
  <version>2.2</version>
  <interface><name>IBluetoothAudioProvidersFactory</name><instance>default</instance></interface>
```
→ 只有 HIDL 声明；AIDL 形式的 `<fqname>` / `<hal format="aidl">` **不存在**。

### 4.6 五个 codename 对应的机型（**中等置信**，来源为搜索引擎摘要，非一手资料）

检索手段：`curl https://www.baidu.com/s?wd=<codename> 小米 代号 型号`（WebSearch 工具在本环境不可用，见 §2.3）。命中摘要：

| codename | 机型（摘要原文） | 平台 |
|---|---|---|
| `corot` | 红米 **K60 至尊版**（Redmi K60 Ultra，天玑 9200+）；刷机包 `fw_corot_miui_COROT_OS1.0.12.0.UMLCNXM` | MTK 天玑 9200+ |
| `duchamp` | **红米 K70E / POCO X6 Pro 5G**（"下载红米 K70E / POCO X6 Pro 5G (duchamp) 稳定版刷机包"） | MTK 天玑 8300-Ultra |
| `zircon` | **红米 Note 13 Pro+**（"下载红米 Note 13 Pro+ (zircon) 稳定版刷机包"、"Redmi Note 13 Pro+ 5G ROM (zircon)"） | MTK 天玑 7200-Ultra |
| `rothko` | **红米 K70 至尊版 / 小米 14T Pro**（"小米14T Pro…是更名版的 Redmi K70 Ultra"、"红米 Redmi K70 Ultra 代号 Rothko"） | MTK 天玑 9300+ |
| `malachite` | **红米 Note 14 5G**（FCC ID `24090RA29G (Xiaomi Malachite)`；"小米 Redmi Note 14 5G 手机踪迹曝光"） | MTK（具体型号未验证） |
| （Java 侧第 5 个）`degas` | **小米 14T**（"小米 14T 系列机型现身澎湃 OS 代码"、"degas 刷机包"） | MTK 天玑 8300-Ultra |

→ **5 个 codename 全是 MTK 天玑平台机型**（D7200/D8300/D9200/D9300 一代），且都是 2023-09 之后发布的机型。与"这些机型搭载 AIDL 代次蓝牙音频 HAL"的假设**方向一致**。

> ⚠️ 本表为搜索引擎摘要，**未做一手验证**（未查机型固件的 `/vendor/etc/vintf/manifest.xml`）。若要坐实"白名单 ⇔ AIDL HAL"，需对任一机型做同样的 manifest 检查。**这仍是本报告最重要的未验证环节。**

### 4.7 (c) 小结

- **白名单门控的是"LHDC V5 codec 对象是否被创建"**（已验证）。
- 它是"**本机蓝牙音频 HAL 是 MTK AIDL 代次**"的**静态代理**：因为只有 AIDL 后端有 `codec_type=12` 的分发（§4.5 表），而 HIDL 后端没有。
- 但**代码上两者毫无耦合**：HAL 代次由 `HalVersionManager` 在运行时用 `AServiceManager_checkService` 探测决定（不读任何设备属性），白名单则是一个硬编码的 5 元素属性比对。因此更准确的描述是：
  > 小米在协议栈里**假定**只有这 5 个机型带 AIDL HAL，于是用"机型名"代替"能力探测"来做准入。
- 佐证：同一份二进制里**没有**任何地方把 codename 与 hal_version 关联；`HalVersionManager` 所在区间（0x860d90–0x861b00）**没有任何属性读取**（`raw/04_props_callsites.txt` 中该区间为空）。

---

## 5. (d) Java 层的 LHDC 门控

工具：自写 dex 解析（`scripts/r4_dex.py`，修正了 `method_idx_diff` 增量语义后可用）。输出：`raw/04_dex_hits.txt`、`raw/04_dex_hits_all.txt`。

### 5.1 Bluetooth.apk（`com.android.bluetooth`，classes.dex 7.1 MB）

**发现 1 —— 另一份 codename 名单，且与 native 不同（**已验证事实**）**

```
CLASS Lcom/android/bluetooth/a2dp/MiuiBluetoothLatencyMode;
  METHOD ...<init>                          +90  const-string 'corot duchamp rothko degas malachite'
  METHOD ...isActiveDeviceLatencySwitchOpened +411 const-string 'corot duchamp rothko degas malachite'
```
该方法尾部的字节码（`r4_dexctx.py` 导出）：
```
+403  const-string 'ro.product.device'
+405  const-string ''
+407  invoke SystemProperties.get
+411  const-string 'corot duchamp rothko degas malachite'
+413  invoke String.indexOf            ← 注意：用 indexOf（子串匹配），不是 equals
+424/+426/+434/+436 setSpecificCodecStatus("latency_val", ...)
```
→ **Java 名单 = {corot, duchamp, rothko, degas, malachite}**，native 名单 = {corot, duchamp, **zircon**, rothko, malachite}。差异在 `degas`（小米 14T）vs `zircon`（Note 13 Pro+）。
→ 用途是 **Latency（低延迟）模式的可用性/开关**，与 V5 codec 准入是**两套独立名单**。xaga 不在其中，故 LL 模式对 xaga 不可用（与既有报告无关，但值得记录）。

**发现 2 —— 对端耳机白名单属性（与既有报告一致）**

```
CLASS Lcom/android/bluetooth/a2dp/A2dpService;
  METHOD handleLHDCdefaultCloseBond        +32  'persist.bluetooth.a2dp.lhdc.whitelist'
                                           +34  'persist.vendor.bt.a2dp.lhdc.whitelist'
  METHOD handleLHDCdefaultCloseConnected   +127 'persist.bluetooth.a2dp.lhdc.whitelist'
                                           +133 'persist.vendor.bt.a2dp.lhdc.whitelist'
CLASS Lcom/android/bluetooth/a2dp/A2dpCodecConfig;
  METHOD enableOptionalCodecs              +12  'persist.bluetooth.a2dp.lhdc.whitelist'
```
→ 这些是**按对端设备 MAC** 的白名单（既有报告 §8.A 的 `miui_bluetooth_lhdc_whitelist_cache`），不是机型门控。

**发现 3 —— 没有 Java 层 V5 codec 门控**

扫描目标字符串（`LHDCV5_CODEC`、`A2DP_SOURCE_CODEC_LHDCV5`、`A2DP_SOURCE_CODEC_LHDCV5_VALUE`、`SOURCE_CODEC_TYPE_LHDCV5`、`a2dp_source_codec_priority_lhdcv5`、`LHDC_V5`）在 Bluetooth.apk 中的 `const-string` 引用，仅命中：
```
CLASS Lcom/android/bluetooth/BluetoothMetricsProto$A2dpSourceCodec;  METHOD <clinit>  'A2DP_SOURCE_CODEC_LHDCV5'
```
→ 只是**上报指标的枚举名**。V5 的准入完全在 native 层（`createCodec`）。Java 层即使拿到"本机能力列表"也只是转发 native 的结果。

### 5.2 framework.jar / miui-framework.jar / miui-services.jar

codename 大量出现（`corot/duchamp/rothko/zircon/degas/malachite`），但均与蓝牙无关（`Lmiui/os/DeviceFeature.<clinit>`、`Landroid/perf/PerfMTKStubImpl`、`GreezeManagerService`、`MtkGnssPowerSaveImpl`、`TelephonyManager` 等），例如 `DeviceFeature` 是一张巨大的机型能力表（`star/spes/fleur/miel/veux/viva/yunluo/socrates/mondrian/corot/aristotle/duchamp/manet/vermeer/goku/rothko/degas`）。
`miui-framework.jar` 中 `LHDCV1..LHDCV5` 字符串存在，但**没有任何 `const-string` 引用**（属于字段名/注解常量）。`fw-bt.jar` 里有 `LHDC V5`、`A2DP_LHDCV5_FEATURE_MAGIC_NUM` 等（A2DP 扩展特性 magic，非准入）。

**结论（d）**：**Java 层没有 LHDC V5 的机型门控**；唯一与机型相关的蓝牙 Java 名单是 `MiuiBluetoothLatencyMode` 的 LL 模式名单（5 个，含 `degas`）。

---

## 6. (e) MTK AIDL `vendor.mediatek.hardware.bluetooth.audio`

### 6.1 设备上的存在性（**已验证事实**）

```
$ adb shell ls -la /apex/com.android.btservices/lib64/ | grep -iE "mediatek|bluetooth.audio"
android.hardware.bluetooth.audio-V3-ndk.so            183792   ← AOSP AIDL 接口
android.hardware.bluetooth.audio@2.0.so               218928   ← AOSP HIDL
android.hardware.bluetooth.audio@2.1.so               169976   ← AOSP HIDL
vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so    188040   ← ★ MTK AIDL 接口（存在）
vendor.mediatek.hardware.bluetooth.audio@2.1.so       231592   ← MTK HIDL
vendor.mediatek.hardware.bluetooth.audio@2.2.so       174400   ← MTK HIDL

$ adb shell ls /vendor/lib64/hw/ | grep -i bluetooth
android.hardware.bluetooth.audio@2.0-impl.so          ← AOSP HIDL 实现
android.hardware.bluetooth.audio@2.1-impl.so          ← AOSP HIDL 实现
vendor.mediatek.hardware.bluetooth.audio@2.1-impl.so  ← MTK HIDL 实现
vendor.mediatek.hardware.bluetooth.audio@2.2-impl.so  ← MTK HIDL 实现
（★ 无 AIDL 实现 / 无 -service 可执行）
```
→ **接口在、实现不在**（既有报告结论成立）。AIDL 接口库已拉取到 `artifacts/libs/hl_vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so`（188040 B，本次只读拉取）。

### 6.2 `Lhdcv5Configuration` 字段布局（**已验证事实**，由 `writeToParcel` 反解）

`_ZNK4aidl6vendor8mediatek8hardware9bluetooth5audio19Lhdcv5Configuration13writeToParcelEP7AParcel` @ `0x28080`（320 B）按**声明顺序**逐字段写 parcel：

| 偏移 | 类型 | 写方法 | 字节码地址 |
|---|---|---|---|
| +0x00 | `int32` | `AParcel_writeInt32` | 0x280b4 |
| +0x04 | `byte` | `AParcel_writeByte` | 0x280c4 |
| +0x05 | `byte` | `AParcel_writeByte` | 0x280d4 |
| +0x06 | `byte` | `AParcel_writeByte` | 0x280e4 |
| +0x08 | `int32` | `AParcel_writeInt32` | 0x280f4 |
| +0x0c | `int32` | `AParcel_writeInt32` | 0x28104 |
| +0x10 | `int32` | `AParcel_writeInt32` | 0x28114 |
| +0x14 | `byte` | `AParcel_writeByte` | 0x28124 |
| +0x15 | `byte` | `AParcel_writeByte` | 0x28134 |
| +0x16 | `byte` | `AParcel_writeByte` | 0x28144 |
| +0x17 | `byte` | `AParcel_writeByte` | 0x28154 |
| +0x18/+0x20 | `byte[]`（`std::vector<uint8_t>`：begin/end 指针） | `AParcel_writeByteArray` | 0x28164–0x28174 |

即 **11 个标量 + 1 个 byte 数组**（结构体 0x28 = 40 字节）。字段**语义名无法从二进制恢复**（AIDL 生成的 C++ 不内嵌字段名，`.dynsym` 与 `.gnu_debugdata` 均无成员名）；可推断其对应 LHDC V5 的 `{版本/采样率掩码, 位深, 声道模式, 码率, JAS/AR/LL/META 等特性位, 帧长, 扩展数据}`，但**字段名属未知**。

### 6.3 `CodecConfiguration.CodecSpecific` union（**已验证事实**）

`CodecConfiguration::CodecSpecific::writeToParcel` @ `0x1c840`：先写 union tag（`[this+0x40]`），再按 tag 跳转（跳转表 `0xed50` = `00 09 12 1b 24 2d 36 3f 48`，9 项）：

| tag | 类型 |
|---|---|
| 0 | `SbcConfiguration` |
| 1 | `AacConfiguration` |
| 2 | `LdacConfiguration` |
| 3 | `AptxConfiguration` |
| 4 | `AptxAdaptiveConfiguration` |
| 5 | `Lc3Configuration` |
| 6 | `CodecConfiguration.VendorConfiguration` |
| **7** | **`Lhdcv5Configuration`** ★ |
| 8 | `Lhdcv2Configuration` |
| >8 | `__assert2`（0x1c9d8） |

`CodecConfiguration::writeToParcel` @ `0x1bf50`：`codecType(+0x00) → encodedAudioBitrate(+0x04) → peerMtu(+0x08) → isScmstEnabled(+0x0c, Bool) → config(+0x10, CodecSpecific)`。
→ 与 AOSP `android.hardware.bluetooth.audio.CodecConfiguration`（§6.5）**同形但不同包**。

### 6.4 MTK AIDL 的 `CodecType` 取值（**已验证事实，部分**）

由 `A2dpLhdcv5ToHalConfig` 得到 **LHDC_V3 → 9、LHDC_V5 → 11**（§4.5）。其余取值未逐项反解（`Lhdcv5Configuration` 之外的类型与本任务无关）。

### 6.5 与 AOSP `android.hardware.bluetooth.audio` 的关系：**并行，不是替代**（**已验证事实**）

| 维度 | AOSP | MTK |
|---|---|---|
| 包名 | `android.hardware.bluetooth.audio` | `vendor.mediatek.hardware.bluetooth.audio` |
| 接口库 | `android.hardware.bluetooth.audio-V3-ndk.so` | `vendor.mediatek.hardware.bluetooth.audio-V1-ndk.so` |
| 服务名 | `android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` | `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default` |
| LHDC 支持 | **无**（只有 SBC/AAC/aptX/aptX-HD/LDAC/LC3/OPUS/VENDOR；`CodecConfiguration.aidl` 的 union 无 LHDC） | **有**：`Lhdcv5Configuration`（tag 7）、`Lhdcv2Configuration`（tag 8）、`Lhdcv5Capabilities`、`Lhdcv2Configuration` 等 |
| 代码里如何被选 | `HalVersionManager` 探测到 AOSP AIDL → `bluetooth::audio::a2dp::init`（AOSP 实现，`libbluetooth_jni.so` 内 0x8620e0 区） | 探测到 MTK AIDL → `vendor::mediatek::bluetooth::audio::aidl::a2dp::init`（0x8372e0 区） |
| 本地参考 | `reference/aosp-src/android14-release/hardware_interfaces/bluetooth/audio/aidl/...`（AOSP `CodecType`：UNKNOWN0 SBC1 AAC2 APTX3 APTX_HD4 LDAC5 LC3**6** VENDOR7 APTX_ADAPTIVE8 OPUS9 APTX_ADAPTIVE_LE10 APTX_ADAPTIVE_LEX11） | 无公开源码 |

`libbluetooth_jni.so` 内**同时实现四套后端**（各自独立的 `setup_codec`/`A2dpXxxToHalConfig`）：
`bluetooth::audio::hidl`（0x87ee24 区）、`bluetooth::audio::aidl`（0x8627bc 区）、`vendor::mediatek::bluetooth::audio::hidl`（0x825xxx 区）、`vendor::mediatek::bluetooth::audio::aidl`（0x837xxx 区）。
**AIDL 版 V5 代码不是死代码**：它挂在 MTK AIDL 的 `setup_codec` 分发表上（idx 10/12 → `A2dpLhdcv5ToHalConfig`），只要走 AIDL 通路就会被调用（与既有报告 §7.4 "`A2dpLhdcv5ToHalConfig`（AIDL）0x83FD80（死代码）"的措辞**需要更正**：该函数在 AIDL 通路里是**活代码**，只是因为 xaga 不走 AIDL 而不会被触发）。

### 6.6 公开 .aidl 定义（**未找到**）

检索：百度、Bing、GitHub API、grep.app 均未找到 `vendor.mediatek.hardware.bluetooth.audio` 的 `.aidl` 文件（WebSearch 工具不可用，见 §2.3）。本地 `reference/` 与 AOSP 源码中亦无（MTK 私有）。**结论：该 AIDL 定义未公开**（"未找到"≠"不存在"）。

---

## 7. (f) 装上/伪造 AIDL 实现后，白名单还会拦住 V5 吗？

### 7.1 结论：**会**

**证据链（全部已验证）**：

1. `createCodec` 的 V5 准入判定 = `osi_property_get("ro.product.name")` + 5 个立即数比对（§3.2）。**没有任何 HAL 调用、没有 hal_version 参与**。
2. `createCodec` 的唯一调用者是 `A2dpCodecs::init()`（§4.1），而 `A2dpCodecs::init()` 由 `btif_a2dp_source_startup` 触发，**早于**任何 HAL 会话建立。
3. 返回 nullptr → `cbz x0` 跳过 → V5 不进 codec map / 不进 `mCodecsLocalCapabilities`（§4.1）。因此即使 AIDL 通路就绪，协议栈**根本不会去协商 V5**。
4. HAL 代次判定（`HalVersionManager`）**不读任何属性**（§4.7 佐证），因此"装 AIDL 实现"只会改变 `hal_version`，**不会**改变 `ro.product.name` → 白名单判定结果不变。

**换句话说**：白名单不是"因为 AIDL 缺失才拒绝"，而是"独立于 AIDL 存在与否的准入清单"。二者只是**被设计成一致**。

### 7.2 反向检查：有没有别的路径能让 V5 进来？（**已验证：没有**）

- 全库 `ro.product.name` 只有 2 个读取点（§4.2），另一个是 `BtifAvSource::Init`（LHDC V2/V3 使能，xaga 命中）。
- `A2dpCodecConfigLhdcV5Source::init()` @0x799270：`if(!<vtable+0x48 虚调用>) return false; if(!A2DP_VendorLoadEncoderLhdcV5() /*0xf4c3a0*/){ LOG(ERROR,"a2dp_vendor_lhdcv5: init: cannot load the encoder"); return false;} return true;` —— **无设备/属性判定**（只有虚函数与编码器加载）。
- `A2DP_VendorInitCodecConfigLhdcV5` @0x798da0 只是把静态能力表（`0xfdd238`）套进 `AvdtpSepConfig`，**无门控**。
- 5 个 codename 的立即数在全库只出现于 §4.3 表所列函数；其中只有 `createCodec` 是准入性质。

### 7.3 推论："不伪装"跑通 V5 的前置条件（**推断**）

要让 xaga 端到端跑通 LHDC V5 且**不改写 codec_type**（即不伪装成 V3），至少需要：

1. **绕过/满足 `createCodec` 白名单**（改属性、GOT 重定向，或改指令 —— 即现有 P0）。
2. **让 `hal_version == 3`**：设备上必须出现 AIDL 服务
   `vendor.mediatek.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default`，且：
   - 需要 AIDL **实现**（设备上没有；需从其它 MTK 机型移植 `-V1-ndk` 的 impl / service，或自己写一个代理实现）；
   - 需要在 `/vendor/etc/vintf/manifest.xml`（或 `/vendor/etc/vintf/manifest/*.xml`）加 AIDL 声明，否则 `checkService` 找不到；
   - 需要 SELinux 允许 `bluetooth` 域 `find`/`call` 该 service（新 service 需要 `vendor_hal_bluetooth_audio_service` 之类标签与规则）；
   - 需要与 `audio.bluetooth.default.so` / `libbluetooth_audio_session_mediatek.so` / audio HAL 侧的会话建立配合（AIDL 版 `BluetoothAudioPort` 走 `IBluetoothAudioProvider` 接口，HAL 侧必须有对应实现）。
3. 由于 (1) 与 (2) 互相独立，**只做 (2) 不会解锁 V5**；(1) 是必要条件。

> 与现有 V5 伪装 V3 实现的关系：现有方案的 P1（HIDL 跳转表）+ P2（改写 codec_type）**替代了 (2)**，代价是 V5 参数被降级为 V3 结构（HIDL 的 `lhdcConfig` 上限 88200Hz，实际靠"采样率原样透传"骗过 96kHz）。若要"不伪装"，必须做 (2) 而非 P1/P2。

---

## 8. 结论分级表（已验证 / 推断 / 未知）

### 已验证事实
- createCodec 白名单 = `{corot, duchamp, zircon, rothko, malachite}`，恰好 5 个，纯立即数编码；分支字节 `c0050054/e0040054/c0030054/a0020054/60010054`。
- 白名单只在 idx=12（`A2dpCodecConfigLhdcV5Source`）分支内；全库仅此一处。
- `createCodec` 唯一调用者 `A2dpCodecs::init+0x248`；nullptr 即跳过。
- `ro.product.name` 全库 2 个读取点；`ro.product.device` 7 个读取点（含 2 个 LHDC 静态能力表构造器）。
- HIDL `table[12]` = 错误分支（line 359）；MTK AIDL `table[12]` = `A2dpLhdcv5ToHalConfig`。
- `HalVersionManager` 用 `AServiceManager_checkService` 探测，不读属性；`hal_version` 3=MTK AIDL / 4=AOSP AIDL / 1,2=MTK HIDL；映射到 3 个后端分支。
- xaga 运行时只用 `a2dp_encoding_hidl.cc`；vintf manifest 只有 HIDL 声明。
- 设备上 AIDL 接口库存在、AIDL 实现不存在。
- MTK AIDL `Lhdcv5Configuration`（11 标量 + byte[]）、`CodecSpecific` tag 7 = Lhdcv5Configuration、`CodecType` V3=9/V5=11。
- Java 侧 `MiuiBluetoothLatencyMode` 名单 `{corot,duchamp,rothko,degas,malachite}`（用 `String.indexOf` 匹配 `ro.product.device`）；Java 层无 V5 准入。
- `_GLOBAL__sub_I_a2dp_vendor_lhdcv5.cc` 的默认能力值 = corot 的值（0x15），xaga 不被此门控阻断。

### 推断
- createCodec 所在源文件 = `a2dp_codec_config.cc`（依据：同 TU 的 `A2dpCodecs::setCodecOtaConfig` 引用该 `__FILE__`，且函数地址相邻）。
- 白名单的工程意图 = "本机带 MTK AIDL 蓝牙音频 HAL"（代码无耦合，仅设计意图一致）。
- `SupportDiffSampleRate`/`SupportDiffV5SampleRate` 为死代码，其内联副本用于静态能力表初始化。
- 5 个 codename 对应的机型/平台（§4.6，来自搜索摘要）。

### 未知 / 未验证
- `Lhdcv5Configuration` 的**字段名**（二进制不可恢复；公开 .aidl 未找到）。
- MTK AIDL `CodecType` 的完整枚举（仅知 V3=9、V5=11）。
- 白名单机型固件的 vintf manifest 是否确实声明 AIDL（**未做一手验证**）。
- 是否能在 xaga 上让 `hal_version` 变成 3（需 AIDL 实现 + manifest + SELinux，未做实验；本任务为只读）。
- MiuiBluetooth 源码是否存在于任何非公开渠道。

---

## 9. 复现命令清单

```bash
export PATH="/d/Tools/Anaconda3/envs/py3123:/d/Tools/Anaconda3/envs/py3123/Scripts:$PATH"
export PYTHONPATH="d:/Cache/Hyperos/pylibs"; export MSYS_NO_PATHCONV=1
cd d:/Cache/Hyperos/lhdcv5-tr/analysis/scripts

# (b) 白名单
python r4_disasm.py 763280 824                 # createCodec 全反汇编
python -c "import r4_util as U; [print(hex(a), U.rd(a,4).hex(' ')) for a in (0x763470,0x76348c,0x7634b0,0x7634d4,0x7634fc)]"
python -c "import r4_util as U; print(U.rd(0x2befe4,17).hex(' '))"     # createCodec 跳转表
python r4_sym2.py createCodec                  # 符号与大小

# (c) 门控范围
python r4_callers2.py _ZN15A2dpCodecConfig11createCodecE23btav_a2dp_codec_index_t26btav_a2dp_codec_priority_t
python r4_props2.py                            # → raw/04_props_callsites.txt
python r4_refs.py                              # → raw/04_refs.txt
python r4_imm.py                               # → raw/04_imm_chains.txt
python r4_disasm.py 861370 0x504               # HalVersionManager ctor
python r4_disasm.py 824ed0 0x80                # a2dp::init 后端分发
python -c "import r4_util as U; print(U.rd(0x2c5620,15).hex(' '), U.rd(0x2c577d,16).hex(' '))"  # 两张分发表

# (d) Java
python r4_dex.py                               # → raw/04_dex_hits.txt

# (e) AIDL
python r4_aidl2.py 0x28080 320                 # Lhdcv5Configuration::writeToParcel
python r4_aidl2.py 0x1c840 440                 # CodecSpecific union
python -c "import r4_aidl2 as A; print(A.rd(0xed50,9).hex(' '))"

# 设备侧（只读）
adb shell ls -la /apex/com.android.btservices/lib64/ | grep -iE 'mediatek|bluetooth.audio'
adb shell ls -la /vendor/lib64/hw/ | grep -i bluetooth
adb shell grep -A6 -i 'bluetooth.audio' /vendor/etc/vintf/manifest.xml
grep -o -E 'a2dp_encoding_(hidl|aidl)\.cc\([0-9]+\)' artifacts/logs/*.log | sort -u | head
```

---

## 10. 对既有报告结论的修正建议

| 既有报告 | 修正 |
|---|---|
| §3.4 写 `bl __system_property_get` | 实际是 **`osi_property_get`**（PLT 桩 0xf45740 → `_Z16osi_property_getPKcPcS0_`） |
| §7.4 `A2dpLhdcv5ToHalConfig`（AIDL）0x83FD80 = **死代码** | **不准确**：它是 MTK AIDL `setup_codec` 分发表 idx 10/12 的目标，在 AIDL 通路上是活代码；只因 xaga 不走 AIDL 而永不触发 |
| §5 "白名单是适配清单" | 方向正确，但需补充：**代码上白名单与 HAL 代次探测完全解耦**（HalVersionManager 不读属性），白名单是"静态代理"；且 V5 侧还有一个**不阻断 xaga** 的第二门控（`ro.product.device` → 静态能力表，默认值 = corot 的值） |
| §3.4 未提及 | 补充：`SupportDiffSampleRate`/`SupportDiffV5SampleRate` 两个设备门控函数存在但为死代码 |
| — | 补充：Java 侧 `MiuiBluetoothLatencyMode` 另有名单 `{corot,duchamp,rothko,degas,malachite}`（含 `degas` 而非 `zircon`），门控 LL 模式 |
