# A2DP FMQ 缓冲：原理、逆向与改造方案

> 设备：Redmi Note 11T Pro（xaga / MT6895 / Android 14 / HyperOS `OS2.0.12.0.ULOCNXM`）
> 前提：已装入 `module/lhdcv5-real`（AIDL 真·LHDC V5 通路，A2DP 硬件 offload 已关闭）
> 日期：2026-09-26
> 状态：**方案 D′ 已实施、已部署到设备，设备侧验证通过（2026-09-26）**
> 复核：2026-09-26 经逐字节对抗复核（28 个子代理 / 473 万 token），勘误与推荐实现路径见 **§10**；
> 本文档中带 ⚠️ **复核修订** 的行已就地更正，其余不精确项集中列在 §10.2。
> 实施：`payload/android.hardware.bluetooth.audio-impl.so` 在 `0x1f198` 写入方案 D′
> （`0x52878009` → `0x531F7A89`），md5 `d044d1b9…` → **`10a7203b5332c86d15f09ecd921da430`**，
> 相对 git HEAD 原件**恰好 4 个字节**不同（`0x1f198..0x1f19c`，无其它改动）；
> 已推送 + 重启，设备侧两份副本同为此 md5，且从运行进程内存里读出的 `0x1f198` 亦为 `531f7a89`。
> 运行时实测（同一开机周期，三个档位全中）：48 kHz → `7680`（低档不变）、96 kHz → `23040`、
> 192 kHz → **`46080`**；三者共同唯一确定是 D′（48k 排除方案 D，96k 排除方案 B）。
> 设备验证细节与**未覆盖的部分**见 §10.6。

---

## 0. 一句话结论

A2DP 软件编码通路上，PCM 数据经一条**硬编码为 7680 或 15360 字节**的 FMQ（Fast Message Queue）环形缓冲，从音频 HAL 流向蓝牙协议栈。
该尺寸由 MTK 的 `A2dpSoftwareAudioProvider::UpdateFMQSize` 依 PCM 配置**二选一**决定，**与采样率无关地封顶在 15360 字节**，导致 192 kHz 时环容量（13.3 ms）**小于一个 HAL tick（20 ms）**。
**但实测证据表明 FMQ 尺寸并不是 96 kHz/192 kHz 卡顿的瓶颈** —— 它是"余量偏紧"的鲁棒性问题，不是已观测故障的成因。改造它的价值在于消除 192 kHz 的尺寸错配，而非治卡顿。

> ⚠️ **复核修订（结论方向不变，力度改变）**：复核后这条结论**加强**了 —— 192 kHz 会话的 19 次 `A2DP_AUDIO_CHOPPY` **全部**落在读端饥饿突发**之外**（其中 9 次在连续 4 分钟无短读的区间），且每次 CHOPPY 都自带射频丢包计数（最高 retx 29136 / 丢包 19956）；而 48 kHz（无尺寸违规）的 HAL 停摆事件反而更多。见 §10.3。
> 同时，§5.2① 原来用来支撑"写端零故障"的日志证据**不成立**（该消息是 DEBUG 级、按构造打不出来），该条已就地降级。

---

## 1. 数据通路全景：FMQ 在哪里

```
   App / AudioTrack
        │  (binder)
        ▼
   ┌──────────────────────────────────────────────────────────┐
   │ audioserver 进程（单一 PID；域 u:r:mtk_hal_audio / audioserver）│
   │                                                          │
   │  AudioFlinger  ──►  audio.bluetooth.default.so           │
   │                       out_write()  @0x1cc10              │
   │                            │ 每次写入 = 恰好一个 tick      │
   │                            ▼                             │
   │                      端口 vtable+0x80 = WriteData         │
   │                            │                             │
   │                      libbluetooth_audio_session_aidl_mtk.so
   │                       OutWritePcmData() @0x2d180          │
   │                            │ 分块 memcpy + 有界自旋        │
   │  ★ provider: android.hardware.bluetooth.audio-impl.so     │
   │     A2dpSoftwareAudioProvider::UpdateFMQSize @0x1f040     │
   │       └─ 创建/重建 FMQ（this+0xc0）                        │
   │                            │                             │
   │  ══════════════════  FMQ（共享内存环）  ══════════════════ │
   └────────────────────────────┼─────────────────────────────┘
                                │ 跨进程（binder 传 MQDescriptor）
                                ▼
   ┌──────────────────────────────────────────────────────────┐
   │ com.android.bluetooth 进程（域 u:r:bluetooth）             │
   │   libbluetooth_jni.so                                    │
   │     ReadAudioData() @0x850b20                             │
   │        │ 每次读 5 ms（非整 tick）；空则 1ms×10 轮询         │
   │        ▼                                                 │
   │     LHDC V5 编码 → L2CAP → HCI → 耳机                     │
   └──────────────────────────────────────────────────────────┘
```

**要点**：FMQ 是 **HAL（写）→ 协议栈（读）** 的单向 PCM 管道。provider、HAL、session 库**同进程**；只有协议栈在另一个进程。

> ⚠️ **复核修订（进程归属）**：上面框图把 AudioFlinger 与 BT 音频 HAL 画在同一个 `audioserver` 里，**实测不是**。同一抓包内 `BTAudioHalStream` 与 `MtkBTAudioProviderA2dpSW` 共享一个 pid（live.log 均为 1037、live2.log 均为 1040），而 `AudioFlinger_Threads` 是另一个 pid（1134 / 1179）；`u:r:mtk_hal_audio` 在抓包里 0 命中、`u:r:audioserver` 有 16 命中。也就是说 BT 音频 HAL 模块 + provider + session 库跑在**音频 HAL 进程**里，AudioFlinger 经 HAL 接口跨进程把 PCM 交给它。
> 后果：FMQ 只跨"音频 HAL 进程 → 协议栈"一条边界 —— "同进程 AIDL 交接"成立于 provider 与 `audio.bluetooth.default.so` 之间，但**不**成立于它们与 AudioFlinger 之间。§9 里那条"provider 与 HAL 同进程"的更正本身是对的，错的是把该进程等同于 audioserver。

---

## 2. FMQ 尺寸的决策原理

### 2.1 逆向对象

| 项 | 值 |
|---|---|
| 文件 | `module/lhdcv5-real/payload/android.hardware.bluetooth.audio-impl.so` |
| 大小 / MD5 | 163992 字节 / `d044d1b9faf3f3a855703102fe6f247f` |
| 节区 | `.text` @ VA `0x10000`，且**文件偏移 == VA**；`.rodata` @ `0x98e0` |
| 函数 | `_ZN4aidl7android8hardware9bluetooth5audio25A2dpSoftwareAudioProvider13UpdateFMQSizeERKNS3_16PcmConfigurationE` @ **`0x1f040`**，size 1116 |
| 唯一调用点 | `A2dpSoftwareAudioProvider::startSession` 内的 `0x1f57c`（函数入口 `0x1f4a0`，`st_size=696`；全库仅此一处 `bl 0x24e10`，其 PLT→GOT `0x268c8` 经 `.rela.plt` 确认指向 `UpdateFMQSize`；调用前有 `IsSoftwarePcmConfigurationValid` 门控） |

设备上该文件的实际副本在 `/data/vendor/lhdcv5/android.hardware.bluetooth.audio-impl.so`（由模块 `post-fs-data.sh` 第 1 步从 `payload/` 复制而来），**MD5 与 payload 逐字节一致** → 下述偏移可直接用于设备。

> ⚠️ **复核修订**：上面这句是循环论证 —— 设备上那份就是模块自己 `cp` 过去的，比对它永远相等（§8 里"OTA 后重新核对 MD5"因此毫无检出能力）。真正需要核实的是**被顶替的厂商原件**与 `payload/` 的 `.text` 是否一致，做法见 §10.4 第 2 条。

### 2.2 输入：`PcmConfiguration` 结构

由同文件的 `PcmConfiguration::toString` @`0x18390` 与 `UpdateFMQSize` **双重印证**：

| 偏移 | 类型 | 字段 |
|---|---|---|
| `+0x00` | int32 | `sampleRateHz` |
| `+0x04` | uint8 | `channelMode`（`ldrb` 零扩展；判定用 `sxtb`+`cmp .../gt`，见 0x1f080/0x1f088/0x1f094） |
| `+0x05` | int8 | `bitsPerSample`（`ldrsb`，确为有符号） |
| `+0x08` | int32 | `dataIntervalUs` |

`sizeof = 12`（由 4 字段偏移 + 4 字节对齐推出，**非实测**；本 `.so` 内没有 12 字节 stride/分配的直接证据）。

### 2.3 关键指令序列

> ⚠️ **复核修订**：下面这份清单**已按地址升序重排并补全**。原版把 `mov w11, #1` 错标到 `0x1f088`（该地址实为 `cmp w13, #1`）、漏了 8 条指令（`0x1f080/0x1f09c/0x1f0a8/0x1f0ac/0x1f0b0/0x1f0b4/0x1f18c` 及 `0x1f068`），且地址顺序被打乱。逐指令复现请以本清单为准。

```asm
0x1f068  mov   w8,  #0x4dd3
0x1f06c  ldrb  w9,  [x1, #4]        ; channelMode（零扩展）
0x1f070  movk  w8,  #0x1062, lsl #16 ; w8 = 0x10624DD3（= 274877907 ≈ 2^38/1000）
0x1f074  ldrsw x12, [x1, #8]        ; dataIntervalUs（32 位有符号）
0x1f078  ldr   w10, [x1]            ; sampleRateHz
0x1f07c  ldrsb w11, [x1, #5]        ; bitsPerSample（有符号）
0x1f080  sxtb  w13, w9              ; channelMode 转有符号再比
0x1f084  smull x12, w12, w8         ; ┐
0x1f088  cmp   w13, #1              ; │
0x1f08c  mul   w10, w10, w11        ; │ rate × bits
0x1f090  mov   w11, #1              ; │
0x1f094  cinc  w11, w11, gt         ; │ channels = (channelMode > 1) ? 2 : 1
0x1f098  cmp   w9,  #0              ; │
0x1f09c  lsr   x9,  x12, #0x3f      ; │
0x1f0a0  asr   x12, x12, #0x26      ; │ x12 = dataIntervalUs / 1000（向零取整）
0x1f0a4  csel  w11, wzr, w11, eq    ; │ channelMode == 0 时 channels = 0
0x1f0a8  add   w9,  w12, w9         ; ┘ w9 = interval/1000（截断向零）
0x1f0ac  add   w12, w10, #7         ; ┐
0x1f0b0  cmp   w10, #0              ; │ 向零取整的 ÷8
0x1f0b4  csel  w10, w12, w10, lt    ; ┘
0x1f0b8  mul   w9,  w9,  w11        ; × channels
0x1f0bc  asr   w10, w10, #3         ; (rate × bits) / 8 = 每声道每秒字节数（**不是**"每帧字节数"）
0x1f0c0  mul   w9,  w9,  w10        ; ★ w9 = bytes_per_tick × 1000（此处尚未除 1000）
0x1f0c4  add   w10, w9,  #0x3e7     ; ┐ 无符号比较：
0x1f0c8  cmp   w10, #0x7ce          ; │ (w9+999) > 1998 ⟺ w9 > 999 ⟺ bpt ≥ 1
0x1f0cc  b.hi  #0x1f180             ; ┘ 否则落 0x1f0d0：打 ERROR "Unexpected PCM Configuration=" 并 return false
0x1f180  smull x8,  w9,  w8         ; ┐
0x1f18c  lsr   x9,  x8,  #0x3f      ; │ 再向零取整除 1000
0x1f190  asr   x8,  x8,  #0x26      ; │
0x1f194  add   w20, w8,  w9         ; ┘ ★ w20 = bytes_per_tick（日志原样打印此值）

0x1f184  mov   w10, #0x1e00         ; ★ 7680    [原始字 0x5283C00A] 既是阈值又是低档值
0x1f198  mov   w9,  #0x3c00         ; ★ 15360   [原始字 0x52878009]
0x1f19c  cmp   w20, w10             ;           [原始字 0x6B0A029F]
0x1f1a4  csel  w19, w9, w10, hi     ; ★ FMQ 尺寸 [原始字 0x1A8A8133]
```

`w19` 随后作为 `AidlMessageQueue` 构造函数的 size 参数（`0x1f298 mov x1, x19`；`0x1f2ac bl 0x24dc0`，PLT→GOT `0x268a0` 经 `.rela.plt` 确认为 `AidlMessageQueue<signed char, SynchronizedReadWrite>::AidlMessageQueue(size_t, bool, unique_fd, size_t)`），并被打进日志 `size of audio buffer N byte(s)`（`0x1f46c mov w1, w19`）。

> ⚠️ **复核修订**：原文写"日志里的那个数字就是 FMQ 的真实字节容量"，严格说**打印的是 `w19`（期望尺寸）而不是队列实测的 `extent`**。只有当 `0x1f264` 的比较恰好为真（走复用分支、且计数器漂移项为 0）时二者才一致 —— 所以这条日志是**自证**，不能用来独立确认客户端真拿到了该容量（要独立确认见 §10.5 的 oracle）。

### 2.4 公式

```
真实指令序列（两次向零截断；w9 在 0x1f0c0 处是 bpt×1000）：
bpt = trunc( trunc(dataIntervalUs / 1000) × channels × trunc(sampleRateHz × bitsPerSample / 8) / 1000 )

等价闭式（**仅当 dataIntervalUs 是 1000 的整数倍时成立** —— 四组实测 20000/23000 都满足）：
bytes_per_tick = dataIntervalUs × channels × (sampleRateHz × bitsPerSample / 8) / 10⁶
               = (dataIntervalUs / 10⁶) × sampleRateHz × frameSize        （frameSize = channels × bits/8）

FMQ 尺寸 = (bytes_per_tick > 7680) ? 15360 : 7680
```

> ⚠️ **常见误写**：`rate × 0.02 × ch × bpf` 会把声道算两遍（`bpf` 已含声道）。正确写法里 `frameSize` 是每帧总字节数（24bit 立体声 = 6）。
>
> ⚠️ **复核修订（退化输入）**：上面的模型**没有覆盖 `bpt < 1`** 的情形。真实行为是 `0x1f0cc` 的 `b.hi` 不成立 → 落 `0x1f0d0`，打 `ERROR`（`- Unexpected PCM Configuration=`）并 `return false`，**不建也不更新 FMQ**。设计补丁时别把 `0x1f0c4` 当成可用的钳位点：它是**早退**，且是**无符号**比较（负的 `dataIntervalUs` 反而被放行），详见 §10.4 第 1 条。

### 2.5 四组实测逐位验证

| 配置 | `dataIntervalUs` | `bytes_per_tick` | FMQ 尺寸 | 日志原文 |
|---|---|---|---|---|
| 48000 / 24bit / 立体声 | 20000 | 5760 | **7680** | `bytes_per_tick = 5760 - size of audio buffer 7680 byte(s)` |
| 96000 / 24bit / 立体声 | 20000 | 11520 | **15360** | `bytes_per_tick = 11520 - size of audio buffer 15360 byte(s)` |
| 192000 / 24bit / 立体声 | 20000 | 23040 | **15360** | `bytes_per_tick = 23040 - size of audio buffer 15360 byte(s)` |
| 44100 / 16bit / 立体声（AAC） | 23000 | 4057 | **7680** | `bytes_per_tick = 4057 - size of audio buffer 7680 byte(s)` |

第四行曾长期无法解释（4057 不是 20 ms 的整数倍）。它来自 **AAC**：MTK `a2dp_aac` 按 1024 样本帧 → `1024/44100 ≈ 23.22 ms`，向上层上报 `dataIntervalUs = 23000`。验证：`floor(23000/1000) × 2 × (44100×16/8) / 1000 = 23 × 2 × 88200 / 1000 = 4057`。✅

> 原始行：`live.log:116060` `a2dp_aac_feeding_reset: a2dp_aac_feeding_reset: PCM bytes 4057 per tick 23 ms`；`live.log:116059` `AAC frame_length = 1024`；`live.log:116065` `a2dp_get_selected_hal_pcm_config: PcmConfiguration=PcmConfiguration{sampleRateHz: 44100 … dataIntervalUs: 23000}`。
> ⚠️ 附录 B 旧引的 `live.log:116081` 有误（那一行是 `SetLowLatencyModeAllowed: BluetoothAudioHal is not ready` 的 W 行）。
>
> ⚠️ **复核修订**：这四组也是全数据集中**仅有的四种**组合 —— 全部 12 行 `UpdateFMQSize` 去重后只有 5760/11520/23040/4057 四种 `bytes_per_tick`，没有第五种。

### 2.6 `7680` 的来历

`7680` 不是 MTK 拍的，是 **AOSP 上游常量**（`reference/aosp-src/r7/hwif/aidldefault/A2dpSoftwareAudioProvider.cpp:31-41`）：

```cpp
static constexpr uint32_t kPcmFrameSize  = 4;    // 16 bit / 立体声
static constexpr uint32_t kPcmFrameCount = 96;   // 16/24/32 的最小公倍数
static constexpr uint32_t kRtpFrameCount = 10;
static constexpr uint32_t kBufferSize    = 4 * 96 * 10;  // 3840  —— 按 SBC 一个 tick 约 7 帧估的
static constexpr uint32_t kBufferCount   = 2;            // double buffer
static constexpr uint32_t kDataMqSize    = 3840 * 2;     // 7680
```

MTK 保留了 AOSP 的 `7680` 作低档，另加了一档 `15360`（即 4×3840）。**两档都没有跟着采样率/位宽走**，这就是错配的根源。

> ⚠️ **复核修订**：上面代码块**不是 `:31-41` 的逐字原文** —— 漏了第 35 行 `static constexpr uint32_t kRtpFrameSize = kPcmFrameSize * kPcmFrameCount;`，`kBufferSize` 与 `kDataMqSize` 的右式被内联成字面量，注释位置也被挪动（源码注释挂在 `kRtpFrameCount` 上而非 `kBufferSize`）。数值结论不变。
> 另外 `15360 = 4×3840` 属**推断**（二进制里只有 `mov w9, #0x3c00` 这一个事实）；`reference/` 全树 grep `UpdateFMQSize` 与 `15360` 均 **0 命中** —— 这反而正面证明：`UpdateFMQSize` 与 `15360` 这一档**整个是 MTK 新增的**，上游只有构造函数里一次性 `new DataMQ(7680)`。

### 2.7 常量出现的位置（共 4 处，同一 .so 内）

| 偏移 | 原始字 | 指令 | 用途 |
|---|---|---|---|
| `0x1ee44` | `0x5283C001` | `mov w1, #0x1e00` | 构造函数里**初始队列**的尺寸（`A2dpSoftwareAudioProvider()` @`0x1ede0`） |
| `0x1ef84` | `0x5283C001` | `mov w1, #0x1e00` | 构造函数里 `size of audio buffer` 日志的参数 |
| `0x1f184` | `0x5283C00A` | `mov w10, #0x1e00` | `UpdateFMQSize`：**阈值 + 低档值**（双重用途） |
| `0x1f198` | `0x52878009` | `mov w9, #0x3c00` | `UpdateFMQSize`：**高档值** |

> `0x1f184` 的 `w10` **身兼两职**（既是 `cmp` 的阈值，又是 `csel` 的低档输出），单独改它会同时抬高分档阈值 —— 这是设计补丁时最容易踩的坑。✅ 复核确认（`0x1f19c` 与 `0x1f1a4` 同用 `w10`）。
>
> ⚠️ **复核修订（扫描口径）**：对全 `.text` 的 MOVZ/MOVN 立即数扫描确认 —— `imm16=0x1e00` 恰 3 处（`0x1ee44`/`0x1ef84` Rd=w1、`0x1f184` Rd=w10）、`imm16=0x3c00` 恰 1 处（`0x1f198`），**总共就是这 4 处、没有第五处隐藏依赖**；`0x1f198` 与 `0x1f184` 在 `0x1f1a4` 之后即死亡（`0x1f1ac`/`0x1f1c4` 的 `ldr` 覆盖），故"改 `csel`"与"改 `mov`"在寄存器副作用上等价。
> 但这 4 处只覆盖 **A2DP 软件链路**：同一个 `.so` 里另有 3 处 FMQ 创建点 —— 构造函数 `0x1ee58`（7680）、`HearingAidAudioProvider` `0x21c18`、`LeAudioSoftwareAudioProvider::startSession` `0x23b88`（后者用浮点自算尺寸，并打同样的 `- size of audio buffer N byte(s)` 文案（前置一空格），另有 `Unexpected audio buffer size:` 判定）。所以 `size of audio buffer N` 这条日志是 provider 家族共用的，单看它不能唯一归因到 `A2dpSoftwareAudioProvider`（HearingAid 会打 3584）。

---

## 3. 与 HAL tick 的不变式

HAL 侧（`audio.bluetooth.default.so`）：

```
out_get_buffer_size() @0x19b40 = 每样本字节数 × 声道数 × [out+0x178]
[out+0x178] = utils::FrameCount(GetPreferredDataIntervalUs(), sample_rate)   ; FrameCount @0x22e40 = rate × interval_us / 10⁶
                                          写入点 0x1934c
```

即 **HAL 每次 `out_write` 的长度 ≈ 一个 tick**（`out_get_buffer_size` 实测 5760 / 11520 / 23040）。

> ⚠️ **复核修订（三处，均不改变 192 kHz 的结论）**：
>
> 1. **"恰好"是过度概括**。HAL 的 `out_write @0x1cc10` 只把**调用方**给的字节数原样转发给端口 `vtable+0x80`（`0x1cc40 mov x22,x2` → `0x1ccfc ldr x8,[x8,#0x80]; blr x8`），它自己不算长度；而 AF 的写块大小取自 `out_get_buffer_size` **并按 16 帧对齐**：`live3.log` 有 AF 原文 `HAL output buffer size is 1014 frames but AudioMixer requires multiples of 16 frames` / `normal sink buffer size 1024 frames` —— 这正是日志里 `out_write bytes=4096` 的来历（1024 帧 × 4 B）。数据集里还有 `bytes=5280/7680/13440` 等非 tick 值（都在会话起停的 `DISABLED`/`STARTING` 态）。
> 2. **AAC 档差 1 字节**：provider 算 `bpt = 4057`，HAL 的 `out_get_buffer_size` 是 `frames(1014) × 4 = 4056` —— 两侧取整位置不同。
> 3. **稳态不可观测**：HAL 只在 `state != STARTED` 时打 `bytes=`（`0x1cc64 cmp w8,#3; b.eq 0x1ccdc`；日志在 `0x1cc74` 的 severity=2 分支），`state == STARTED` 的写不落日志，抓包里也确实一条都没有。所以下表 192 kHz 的 0.67 tick 是**推断**而非观测。

于是"必须满足"的（实为**性能/余量条件**，不是正确性前提 —— 见 §4.1 与 §5.2）是：

```
FMQ 尺寸  ≥  一次 out_write 的长度（一个 tick）
```

| 采样率 | tick（字节） | FMQ | 比值 | 是否满足 |
|---|---|---|---|---|
| 48 kHz / 24bit | 5760 | 7680 | 1.33 tick | ✅ |
| 96 kHz / 24bit | 11520 | 15360 | 1.33 tick | ✅ |
| **192 kHz / 24bit** | **23040** | **15360** | **0.67 tick** | ❌ **违反** |
| 44.1 kHz / 16bit (AAC) | 4057 | 7680 | 1.89 tick | ✅ |

**192 kHz 是唯一违反档位。** MTK 的分档策略实际上把环封顶在"96 kHz 的一个 tick"上。

> ⚠️ **复核修订（"不变式"的定性）**：这条不等式**不是**代码或上游的约束，只是本方案自定的启发式 —— 上游 AOSP 自己在 96 kHz/24bit（tick 11520 > `kDataMqSize` 7680）就"违反"了它，而写端是分块 + 有界自旋（§4.1），环小只造成**有界等待**，不失败。读端同样会出现大于环容量的单次请求（会话起始的 28672 > 任何档的环）。所以应表述为"**放大环可消除排空等待、增加可容忍的生产侧停顿**"，而不是"修复违反不变式"。
> 更要紧的是，真实约束应写成 **FMQ ≥ AF 对齐后的写长度**（见上）：AAC 档 AF 实际提交 4096 B 而 provider 的 tick 只有 4057 B —— 这会在方案 D+F 同打时变成真缺口（§6）。

---

## 4. 写端与读端行为（决定"放大是否有用"）

### 4.1 写端：分块 + 有界自旋，**不因环小而失败**

`BluetoothAudioSession::OutWritePcmData` @`libbluetooth_audio_session_aidl_mtk.so:0x2d180`：

```
每轮：写 min(可用空间, 剩余)
      可用空间 = ring_extent + readCounter − writeCounter
      空间为 0 → unlock；usleep(1000 µs)；预算减 1；重试
预算：1000 次（w24 初值 0x3e8）
耗尽 → 打 ALOGD "Data X/Y overflow N ms"，返回已写字节数
```

**关键**：它**不会**因为 payload 大于队列容量而返回失败 —— 会分多块写、最多自旋约 1 秒。所以"环比一个 tick 小"造成的后果是**每次写多花几毫秒的有界等待**，而非死锁。

> ⚠️ **复核修订两点**：
>
> 1. **"不是丢数据"强于机制**：预算耗尽时返回的是**短写**（`0x2d454 mov x0, x19` = 已写字节数），而 `WriteData`/`out_write` 都**不重试尾段**；另一条分支 `0x2d424`（内部一致性失败）更是直接不写就返回。两条都 0 命中，所以"现象为真"，但机制上存在截断路径 —— 只有当消费者能在此前把数据排空时"不丢数据"才成立。
> 2. **这段机制是上游原生的，不是 MTK 的包装层**：`reference/aosp-src/d2/BluetoothAudioSession.cpp:48/51/402-431` 就是 `kFmqSendTimeoutMs=1000` + `kWritePollMs=1` + `ALOGD("data %zu/%zu overflow %d ms")`。MTK 做的是把预算从上游的 10 ms（`client_interface_aidl.h:187 kDefaultDataWriteTimeoutMs=10`）放宽到 1000 ms —— 这个 100× 的放宽本身就说明亚秒级阻塞在该通路上是被预期、被容忍的常态。

### 4.2 读端：非阻塞 + 10 ms 超时

`libbluetooth_jni.so:BluetoothAudioSinkClientInterface::ReadAudioData` @`0x850b20`：

```
请求长度（len = 调用方参数，w22 = w2）实测至少 5 种：
  1440（48k 的 5ms）、2880（96k 的 5ms）、5760（192k 的 5ms）、
  4096（AAC 一帧 = AF 把 1014 帧上取整到 16 的倍数）、28672（会话刚 START）
另有部分读：14272/28672、2752/28672
FMQ 为空 → sleep_for(1 ms)，最多 10 次（0x850b88 mov w26, #0xa；0x850b7c 的 w28=0xF4240ns）
超时 → 短读，打 WARNING "ReadAudioData: N/M no data 10 ms"
```

> ⚠️ **复核修订**：
>
> 1. 原文"请求长度实测只有 3 种"**只对 live2.log 成立**（该文件恰有 5760/2880/28672 三种）；按 `live*.log` 全量还有 1440、4096，并有部分读。这正是原文"从不要求整 tick"的论据被削弱的原因 —— 但结论方向不变：1440/2880/5760 恰为 48k/96k/192k 的 5 ms。
> 2. 日志文本里的两个数是 **`(len − total_read)/len`**（AOSP `client_interface_aidl.cc:478-484` 打印 `(len - total_read) << "/" << len`），不是"两个请求长度"。相等的那几行恰好表示整块未读到。
> 3. "读端按 5 ms 取"是**调用方**（`btif_a2dp_source` 的读回调）的属性，不是 `ReadAudioData` 自己的 —— 该函数体内没有任何 tick/5 ms 常量，它按调用方给的 `len` 循环、以 `min(可用, 剩余)` 增量消费。而**这些 len 值全部取自"饥饿时才打印"的那条 WARNING**（48k 的 1440 只在 live4.log 出现 5 次，48k 基本不饿）—— 属**幸存者偏差**，真实的分布需要给 `ReadAudioData` 入口加无条件日志才能拿到。

### 4.3 真实可用容量

FMQ 元素类型 `int8_t`（即 `char`），**无 per-message 头开销**：容量 N 字节的 FMQ 就是 N 字节 PCM。
（⚠️ **复核修订**：对齐**不是** `initMemory` 做的 —— 8 字节/页对齐在 `MessageQueueBase` 与 `AidlMQDescriptorShim` 的构造里（impl.so `0x20150`–`0x20198`；ashmem region 长度 = `align_down(0x1010 + align8(size), 4096)`），`initMemory @0x20a30` 只校验 grantor 数 ≥ 3、`quantum == 1` 并映射 grantor。对齐只影响 mmap 长度，描述符里 data grantor 的 `extent` 是你传入的原始值。上限：创建侧卡 `align8(0x10+size) ≤ INT32_MAX`，映射侧拒 `extent > INT_MAX − 4096`，对 46080 这类尺寸毫无约束。）

### 4.4 尺寸如何传给对侧：**经 `MQDescriptor`，与 HAL 解耦**

`startSession` 返回 `MQDescriptor<byte, SynchronizedReadWrite>`，其中：
- ring-buffer 那条 `GrantorDescriptor` 的 **extent** = 队列字节数
- `+0x20` 处的 **quantum** 字段
- fd 是 `mmap` 的载体，**队列容量不从 fd 推导**（严格说 ashmem region 长度会随 size 变，但读端算可用空间只用描述符的 extent）

provider 在 `onSessionReady` @`0x1f760` 用 `dupeDesc()`（@`0x1fa80`）复制 grantor 表 + `dup()` 各 fd 后交给调用方。

**结论**：客户端可用空间**由描述符里的 extent 决定**（严格说 `可用 = extent − (writeCounter − readCounter)`，extent 是容量上界；只有空环时才等于 extent）。所以

- 放大 FMQ **不需要**同步改 `audio.bluetooth.default.so` 或协议栈客户端 —— ✅ 已由两端反汇编**正面证实**：session 库与 `libbluetooth_jni.so` 的全 `.text` 均无 7680/15360/46080 立即数，两者的队列都只从描述符构造（`UpdateDataPath @0x2ad40` 只做 `new(0x30)` + 由描述符构造 MessageQueueBase，自身**不算**可用空间 —— 附录 B 旧引这句有误）；
- `audio.bluetooth.default.so` 侧**没有** FMQ 容量校验能力（其 `.dynsym` 里 `MessageQueueBase`/`MQDescriptor`/`Grantor` 符号数为 0）；但别把这句读成"进程内无校验"—— 同进程的 session 库与 provider **有**（`MessageQueueBase::read @0x2d8d8` 的 `avail > size → return 0` 守卫、`initMemory` 的 quantum/grantor 检查、provider `0x1f264` 的容量比较）；
- 唯一需要保持的是一致性：新 FMQ ≥ **AF 对齐后**的一次 `out_write` 长度（见 §3）；
- ⚠️ 描述符携带的不止尺寸：`offset` 也随尺寸走（`grantors[3]` 的 EVFLAG 在 `alignToWordBoundary(16+size)`、`quantum` 在 `[shim+0x20]`），整个 4-grantor 布局都会被重算。当前两端都从同一次 `dupeDesc` 取，所以安全；但**任何缓存过 offset/指针的一方都会失效**。

---

## 5. 它是卡顿的瓶颈吗？—— 证据与结论

### 5.1 结论

**不是**（置信度：中高 → 复核后 **高**）。FMQ 尺寸偏紧是真实的，但它不产生已观测到的故障。复核新增的关键证据：192 kHz 会话的 19 次 CHOPPY 与读端饥饿突发在时间上**互斥**（见 §10.3）。

### 5.2 反证

**① 写端零故障 —— ⚠️ 复核后降级为"未被观测到"。** 全数据集 grep：

- `FMQ datapath writing ... failed`（ERROR 级）→ **0 命中**（有效）
- 超时分支 `Data X/Y overflow N ms` → **0 命中，但这是构造性假阴性**：该消息的级别是 `severity=1`（DEBUG，`0x2d480 mov w0,#1` / `0x2d4b0 mov w3,#1`；AOSP 上游同样写 `ALOGD`，§4.1 自己也标了 `ALOGD`），而抓包里 tag `BTAudioSessionAidl` 共 895 行**全部是 I 级、0 行 D/V**（同一抓包 D 级共 26.4 万行，不是全局压级别）。也就是说，"能记录环满导致写不满"的那条消息在默认日志级别下**打不出来**。
- 控制器 BQR 的 `buffer_overflow_bytes` → **全为 0，但与本问题无关**：它是**控制器侧**链路质量字段（`quality_report_id 3`，与 `retransmission_count`/`nak_count`/`flow_off_count` 并列打印），不是主机进程内 FMQ 的读写计数器。

因此"除会话已结束的静默分支外，任何写不满都**必然打日志**"**是错的**；"0 命中"只能推出"没有 ≥1 s 的阻塞"。要恢复这条证据，需临时 `setprop log.tag.BTAudioSessionAidl D` 后再抓。

**② 读端饥饿 = 生产侧断供，不是环太小（方向成立，措辞过强）。** 99 条 `ReadAudioData: N/N no data 10 ms`（**仅 live2.log**；`live*.log` 合计 114 条、含 `logcat_full.txt` 则 129 条）分布在 **8 簇**而非下表的 4 簇：

| 时刻 | 事件 |
|---|---|
| 23:15:31.529 | `NMAudioPlayer: AudioTrack(49): Pause(0)` + `Device Pause` |
| 23:21:44–47（最长 2.26 s，46 次） | `onPlaybackStateChanged: state=PLAYING(3)` 换曲 |
| 23:29:44.123 | `CNCMAudioPlayer::FrameFill kAudioPlayerEOS` + `AudioTrack(54): Pause`（歌曲结束） |
| 23:33:23.256 / 23:38:00 | `AudioTrack(55): Pause` / 换曲 |

同一时刻协议栈侧是 `l2c_link_check_send_pkts: No transmit data, skipping`。⚠️ **复核修订**：这一行在 live2 出现 **788781 次**，是空闲高频日志，**无法用来定位突发点** —— 属弱证据，结论应由上表的应用侧事件支撑（环里没数据时，容量再大读端也读到 0）。

另外两簇（原文未列）：**23:05:30 簇**落在 HAL 会话重建窗口（同毫秒有 `restoreTrack_l dead IAudioTrack, creating a new one` 与会话 TearDown/SetUp），**23:39:21 簇（16 条）**距应用 `Pause` 有 3.57 s，实际对应 HAL `Suspend … A2DP_SOFTWARE_ENCODING_DATAPATH`。即约 **1/4 的样本**落在"HAL 主动掏空环"的窗口内，而非应用换曲 —— 这也是"用读端短读计数当 go/no-go 判据"不可用的原因（§7.3）。

**③ 累计影响可忽略（结论成立，数字要重算）。** "97" 可溯源到 live2 的 97 条 `btif_a2dp_source_read_callback: UNDERFLOW: ONLY READ 0 BYTES`（与 99 条客户端 no-data 相邻，故"97–99"实为两个相邻计数器构成的区间）。按"每条 ×10 ms"估只有 ≈1 s，但突发时长应按 **(末条 − 首条) + 10 ms** 计：八簇合计 **≈5.4 s**（约 5 倍）。分母口径也没交代（"35–47 分钟"无法从日志复现）：按 192 kHz 单会话 26.65 min 算是 0.062%。量级仍可忽略，但"**< 0.05%**"不成立。

**④ 主导可听劣化在射频侧。** `QUALITY_REPORT_ID_A2DP_AUDIO_CHOPPY`：192 kHz 段 **0.62 次/分**，96 kHz 段 **0.17 次/分**；单次重传最高 29136、丢包 19956，ABR 因此把码率 400 → 256 kbps。这与 `docs/LHDC-V5-真通路-实现报告.md` §5.4 记录的"192 kHz 配不到足够码率"一致。

**⑤ 192 kHz 会话独有的异常方向相反。** `TX queue buffer size now=28 adding=1 max=28` 共 31 次，全落在 192 kHz 段（96 kHz 段 0 次）—— 这是**下游背压**（编码器产出快于链路发送），说明 FMQ 更可能偏满而非偏空。

### 5.3 但 192 kHz 确有一个真实的尺寸错配

FMQ 15360 B（13.33 ms）< 一个 tick 23040 B（20 ms）。后果是**每次 `out_write` 内出现环满 → 以 1 ms 步进等消费端排空（典型几 ms）**，即写线程抖动与余量变小 —— 而不是故障。

> ⚠️ **复核修订**：这句是**推断而非观测** —— `state == STARTED` 稳态的 `out_write` 字节数在现有日志里结构上不可见（§3），所以"必然出现环满"依赖"稳态每次写满一个 tick"这个未观测的前提。反过来，**环变大 = 可积压容量变大，不等于端到端延迟变大**：读端每 5 ms 轮询且实测经常读到 0（环常空），稳态填充由生产/消费速率比决定，不随容量上升。

**准确表述**：MTK 的规模启发式把环封顶在 96 kHz 的 tick 上；192 kHz 时环只剩 13.3 ms 余量给 20 ms 的 tick。放大环是**合理的余量与抗抖动改进**，不是修复任何已观测到的故障。

### 5.4 附带发现（同样不是 FMQ 的锅）

- 192 kHz 会话 33 次 `out_write: state=DISABLED` + `failed to resume`（与 33 条 `bytes=23040` 同毫秒成对，复核确认）。此时 HAL 会按 `csel x21,x22,xzr,eq` **假装写成功并丢弃 PCM** —— 逐分钟统计确实只集中在 **23:05 / 23:11 / 23:38 三个会话起停点**（复核独立聚类：18 / 22 / 34 条，无第四处 ✓）。
  ⚠️ **复核修订**：但这**不是 192 kHz 独有现象** —— 同类 `DISABLED`/`STARTING` 行在 96 kHz（38 条 11520）、48 kHz（live4 41 条 5760 + **172 条 `state=STARTING`**，并伴随 E 级 `Start: … state=STARTING Hal fails`）上同样存在，密度不低于 192 kHz。所以不能把 HAL 停摆归因于尺寸错配；反过来，"最紧的档位并不是异常最多的档位"正是 §5.1"FMQ 不是瓶颈"的一条旁证。
- ~~**一条未证实的疑点**~~ → **已结案（复核修订）**：原表述称"整个抓包里 `adev_open_output_stream` 从未以 44100 打开"。那个计数 `48000(6) / 96000(10) / 192000(2)` 只在三文件集 {live.log, live2.log, logcat_full.txt} 内是唯一解（4+2、6+4、2），原文**没交代口径**；按 `live*.log` 全量则是 `48000=12 / 96000=6 / 192000=2 / **44100=2**`。`live3.log:107598` 与 `:107681` 明确有
  `adev_open_output_stream: state=STANDBY, sample_rate=44100, channels=0x3, format=1, preferred_data_interval_us=23000, frames=1014`
  —— **AF 确实为 AAC 打开了 44100 的 HAL 流**，原"复用 48 kHz 流"的假设不成立，该疑点（§9 未解决问题 5）**关闭**。
  （附带保留意见：`adev_open_output_stream` 并非每次 open 都打印 —— live.log 里 AF 侧 `HAL output buffer size 960 frames` 有 6 次而 BT HAL 的 open 行只有 4 条，三个 AAC 会话期甚至完全没有 BT HAL 的 open 行。所以"只出现 N 次"是**日志行数**，不等于真实 open 次数。）

---

## 6. 改造方案（字节级）

补丁目标文件统一为：
`module/lhdcv5-real/payload/android.hardware.bluetooth.audio-impl.so`（`.text` 的 VA == 文件偏移）

### 方案 D′：只抬高档、且自适应（**复核新增 · 首选**）

| 偏移 | 原始 | 改为 | 说明 |
|---|---|---|---|
| `0x1f198` | `0x52878009` `mov w9, #0x3c00` | `0x531F7A89` `lsl w9, w20, #1`（等价 `0x0B140289` `add w9, w20, w20`） | 仅当 `bpt > 7680` 时取 2×bpt，否则保持 7680 |

效果：`FMQ = max(7680, 2 × bytes_per_tick)`。它与方案 D 同偏移、同手法（把**高档值**换成 `2×bpt`），但**保留了分辨档的 `cmp`/`csel`**，因此：

| 配置 | bpt | 今天 | 方案 D | **方案 D′** | 方案 B |
|---|---|---|---|---|---|
| 48k/24bit | 5760 | 7680 | 11520 | **7680（逐字节不变）** | 7680 |
| AAC 44.1k/16bit | 4057 | 7680 | 8114 | **7680（逐字节不变）** | 7680 |
| 96k/16bit | 7680 | 7680 | 15360 | **7680（逐字节不变）** | 7680 |
| 96k/24bit | 11520 | 15360 | 23040 | **23040** | 46080 |
| 192k/24bit | 23040 | 15360 | 46080 | **46080** | 46080 |
| 88.2k/24bit | 10584 | 15360 | 21168 | **21168** | 46080 |
| LDAC 96k/32bit | 15360 | 15360 | 30720 | **30720** | 46080 |

- **优先理由**：本项目日常在 48 kHz 听（§10.5），D′ 让 48 kHz 与 AAC **完全不变**（尺寸不变 ⇒ 连"复用构造函数那条队列"的行为都不变，见 §8），只修真正越界的 96k/192k；仍是一个字、仍随采样率/位宽自适应。
- 与方案 D 一样保留 `bpt ≥ 1` 守卫（2×bpt 永不为 0）；但**同样会丢失负 `dataIntervalUs` 的安全钳位**（因为 `w9` 由 `w20` 派生，见 §10.4 第 1 条）。
- `w9` 在 `0x1f1a4` 之后即死亡（`0x1f1ac`/`0x1f1c4` 的 `ldr` 覆盖），故换掉 `0x1f198` 无其它副作用。
- 参考产物：`_scratch/impl_fmq_Dp.so`（md5 `10a7203b5332c86d15f09ecd921da430`）。

### 方案 D：`FMQ = 2 × bytes_per_tick`（全档改大）

| 偏移 | 原始 | 改为 | 说明 |
|---|---|---|---|
| `0x1f1a4` | `0x1A8A8133` `csel w19, w9, w10, hi` | `0x531F7A93` `lsl w19, w20, #1`（等价 `0x0B140293` `add w19, w20, w20`） | 尺寸恒为 2×tick |

效果：48k → 11520、96k → 23040、192k → 46080、AAC 4057 → 8114。**随采样率/位宽自适应**，消除"环 < 1 tick"。

- 优点：单字补丁；`0x1f0c4` 的守卫保证 `bpt ≥ 1`，故 2×bpt 永不为 0；四个档位都得到 `write/FMQ = 0.5`。
- 副作用：`0x1f19c` 的 `cmp` 与两个 `mov` 变成死代码（无害）；**但它是无条件的** —— 四个档位全被改大，其中三个（48k/AAC/96k-16bit）本来合规。
- ⚠️ **复核修订三条**：
  1. **"回到 AOSP `kBufferCount = 2` 的原始语义"是事后合理化** —— 上游只在构造函数里 `new DataMQ(7680)` 一次、从无自适应尺寸（`reference/` 全树 grep `UpdateFMQSize` = 0），只是"×2"这个因子巧合地来自 `kBufferCount`。
  2. **它丢掉了一个意外的安全钳位**：原 `csel` 对异常输入取 15360，改 `lsl` 后负 `dataIntervalUs` 会得到 `0xFFFFFE80 ≈ 4 GB`（`0x1f0c4` 是**无符号**比较，放行负值；上游 `IsSoftwarePcmConfigurationValid` **不校验 `[+8]`**）。可达性未经日志证实，属潜在回归。
  3. 48k/AAC 从"复用它构造函数那条 7680 队列"变成"每次 startSession 重建"，见 §8。

### 方案 B：仅抬高档 15360 → 46080（最小爆炸半径）

| 偏移 | 原始 | 改为 |
|---|---|---|
| `0x1f198` | `0x52878009` `mov w9, #0x3c00` | `0x52968009` `mov w9, #0xb400` (46080) |

效果：48k 与 AAC **逐字节不变**（仍 7680）；96k → 46080（4 tick = 80 ms）；192k → 46080（2 tick）。
- 优点：改动面最小、最易回退。
- 缺点：96 kHz 被一起抬高到 80 ms（相对其 20 ms tick 是过量缓冲）。

### 方案 A：高档 15360 → 30720（最保守）

| 偏移 | 原始 | 改为 |
|---|---|---|
| `0x1f198` | `0x52878009` | `0x528F0009` `mov w9, #0x7800` (30720) |

效果：96k（`bpt=11520` 也走 hi 分支）与 192k **一起**从 15360 变 30720（96k 2.67 tick、192k 1.33 tick）—— 原文"仅 192k 得到改善"**漏了 96k**。
缺点：192k 余量偏薄；而原文担心的"192k/32bit 零余量"对 **LHDC 不成立**（LHDC V5 能力位 `mBitsPerSample:0x3(16|24)`、`mChannelMode:0x2(STEREO)`，不出 32bit —— 32bit 是 LDAC 的能力）。真正有薄余量风险的是 **88.2k/24bit**（bpt=10584，1.45 tick）与 **LDAC 96k/32bit**（bpt=15360，恰好 1.00 tick）。

### 方案 C：两档同抬

| 偏移 | 原始 | 改为 |
|---|---|---|
| `0x1f184` | `0x5283C00A` `mov w10, #0x1e00` | `0x5287800A` `mov w10, #0x3c00` (15360) |
| `0x1f198` | `0x52878009` | `0x52968009` (46080) |

效果：48k → 15360（2.67 tick）、96k → 15360（1.33 tick，不变）、192k → 46080（2 tick）。
- ⚠️ **必须两处同时改**。单独只改 `0x1f184` 会把阈值抬到 15360，而高档仍是 15360 —— **192k 一点没修**。

### 方案 F：HAL 侧放大每次写入量（**复核修订：不是"必要配套"，且不建议与 D/D′ 同打**）

只放大 FMQ **不会**让 AudioFlinger 多写一个字节 —— `out_write` 的长度来自**调用方**，而 AF 的 sink buffer 取自 `out_get_buffer_size`（`live3.log` 有 AF 原文 `HAL output buffer size is 1014 frames but AudioMixer requires multiples of 16 frames` / `normal sink buffer size 1024 frames`，也解释了日志里 `out_write bytes=4096` 的来历）。所以要"让缓冲真正变深"确实要动 HAL 侧：

> ⚠️ **复核修订：原文把 F 称作"放大 FMQ 的**必要配套**"，该判断已被证伪。**
>
> - HAL 的 `out_write @0x1cc10` 只把 AF 传入的字节数**原样转发**给端口 `vtable+0x80`（`0x1cc40 mov x22,x2` → `0x1ccfc ldr x8,[x8,#0x80]; blr x8`），它既不查 FMQ 容量、也不从 `[out+0x178]` 推写入量。所以**单独上 D/D′ 就已消除 192 kHz 的"环 < 一次写"**（D′ 后 192k 为 46080 ≥ 23040，`write/FMQ = 0.5`）。
> - 加 F 反而把比值推回 **1.0（零余量）**，正好吃掉 D/D′ 造出的余量；F 配 A/B/C 还会**重新造出** `write > FMQ` 的错配（A/B 在 48k/AAC、A 在 192k、C 在 96k）。
> - F 的三行**不正交**：`0x19c6C` 与 `0x19c88` 作用于同一个返回值 `x20`；且 `0x19c6C` 是**承重件**而非原文所称"预防性" —— 低延迟位为 1 时 `lsr` 先减半、`lsl` 再翻倍 = 原值，放大为 0（只是实测 `LowLatencySt` 恒为 0，才恰好是空操作）。
> - F 还会把 HAL 环满退避的**最坏时长**从 20 ms 抬到 40 ms（退避 `usleep(bytes×10⁶/frame_size/rate − elapsed)` 与请求字节数成正比，`0x1cd8c`/`0x1cf28`–`0x1cf80`），原文 §8 未计。

| 偏移（`audio.bluetooth.default.so`） | 原始 | 改为 | 说明 |
|---|---|---|---|
| `0x19340` | `0x2A1803E1` `mov w1, w24` | `0x531F7B01` `lsl w1, w24, #1` | 传给 `FrameCount` 的采样率 ×2（会同时抬高上报延迟） |
| `0x19c88` | `0xAA1403E0` `mov x0, x20` | `0xD37FFA80` `lsl x0, x20, #1` | 只放大返回值，不污染延迟上报（**首选**） |
| `0x19c6C` | `0x9AC82694` `lsr x20, x20, x8` | `0xD503201F` `nop` | 去掉低延迟折半（预防性） |

**约束**：新的 `out_get_buffer_size` 必须 ≤ 新的 FMQ，否则退化为分块自旋。

> ⚠️ **复核修订（这条约束正是 D+F 同打的问题所在）**：D/D′ + F 恰好取**等号**（零余量）；而 **AAC 档会真的违反** —— HAL 返回 2 × 4056 = 8112 → AF 上取整到 16 帧的倍数 2032 × 4 = **8128 B**，大于方案 D 的 FMQ 8114（原文按 8112 ≤ 8114 判"满足"，但按 AF 真实提交的长度不满足）。
> 另：`0x19c88` 只改返回寄存器 `x0`、不改 `x20`，而两条日志分支都用 `x20` 打印，所以**打上 F 之后 HAL 自己的 `buffer_size` 日志仍打未翻倍值** —— 用 HAL 日志验证 F 会被误导（`0x19340` 则会让 `x20` 本身翻倍、日志跟着变）。

### 已评估但不推荐

| 方案 | 内容 | 不推荐原因 |
|---|---|---|
| E | 把阈值本身抬成大值（等效固定缓冲） | 牺牲分档节制（48k 到 227 ms）；注意 MOVZ 的 imm16 只有 16 位 |
| G | 协议栈读超时 10 ms → 30 ms | 治标；文件在 system/APEX，模块化覆盖困难 |
| H | HAL legacy 延迟余量 200 ms → 500 ms | 只增大上报延迟，不解决供数 |
| I | HAL 默认 `dataIntervalUs` 10000 → 20000 µs | **对本机 LHDC 完全无效**（端口报的是 20000 µs，走不到默认分支） |

---

## 7. 推荐路线与验证

### 7.1 先厘清目标

- **目标是治卡顿** → **不要**用 FMQ 补丁作主手段。改走 `96 kHz + HIGH_900`、降低链路压力（见实现报告 §5.4）。
  ⚠️ **复核修订**：这条替代路线本身**也不稳** —— `artifacts/live/abr_new.log`（09-26 13:48–13:57）显示 ABR 抬到 900 后 400 ms 内就连续降回 400 → 320。而"FMQ 不是瓶颈"这一侧被加强了（§10.3），所以诚实的结论是：**卡顿的主导项是射频重传，缓冲类改动动不了它**；可用的杠杆是"停在 96 kHz"（0.17 vs 0.62 次/分）、改善射频条件、以及约束 ABR 不要超额承诺。
- **目标是消除 192 kHz 的尺寸错配 / 增加鲁棒性** → 首选**方案 D′**（48k/AAC 逐字节不变），次选方案 B（固定值、保留钳位），再次方案 D（见 §6 与 §10.5）。

### 7.2 部署方式

补丁改的是模块 `payload/` 里的文件。模块的 `post-fs-data.sh` 第 1 步会把 `payload/*.so` 复制到 `/data/vendor/lhdcv5/` 并加载，**因此只需替换 payload 中的对应文件，无需新增任何挂载**。

### 7.3 验证（go / no-go）

```bash
# 1) FMQ 尺寸是否按预期变化
adb shell su -c 'logcat -d -s MtkBTAudioProviderA2dpSW | grep UpdateFMQSize'
#    方案 D′/B：96k 期望 23040 / 46080、192k 期望 46080；48k 与 AAC 期望【不变】（7680）

# 2) 队列构造是否成功（无尺寸拒绝、无非法配置早退）
adb shell su -c 'logcat -d | grep -E "Queue size too large|Unexpected PCM Configuration"'

# 3) 写端 ERROR 级断言（唯一有效的那条）
adb shell su -c 'logcat -d | grep -c "FMQ datapath writing"'

# 4) 写入量未变（应仍是 5760/11520/23040/4056、LowLatencySt=0）
adb shell su -c 'logcat -d | grep out_get_buffer_size'
```

**关键判据**：若第 4 项（读端短读计数，原文的判据）**不下降**，即证实饥饿来自生产侧、与 FMQ 尺寸无关 —— 此时**不应继续加码 FMQ 尺寸**。

> ⚠️ **复核修订（判据要改，否则会误判）**：
>
> - **第 2 项的 `Data X/Y overflow N ms` 不能再用** —— 它是 DEBUG 级，在本机默认日志级别下**天生打不出来**（§5.2①）。要恢复这条观测，先 `adb shell su -c 'setprop log.tag.BTAudioSessionAidl D'` 再抓。
> - **"读端短读计数"不能当 go 判据** —— 它混入了 HAL 在 `state=DISABLED` 下主动丢包的窗口（约 1/4 的样本，§5.2② 复核）；而且它下降与否**并不证明余量变大**。
> - **稳态写长度不可观测**（HAL 只在 `state != STARTED` 打日志）。所以这套命令能证明的是"尺寸生效 + 没变坏"，**不能证明"变好"**。要能证明变好，需要一个独立 oracle：把 `MtkBTAudioSessionAidl` 的自旋点数或 `ReadAudioData` 入口长度改成无条件日志后做同素材 A/B，或直接用 `QUALITY_REPORT_ID_A2DP_AUDIO_CHOPPY` 次/分做受控对照（同曲同位、固定距离）。

---

## 8. 风险与回退

| 风险 | 说明 | 应对 |
|---|---|---|
| 环尺寸与描述符不一致 | 尺寸经 `MQDescriptor` 的 grantor extent 传递；改后两端自动一致，**无需同步改客户端**（已由两端反汇编正面证实，§4.4） | 无需额外操作；`offset` 也随尺寸重算，所以**不能只改一端** —— 若将来只重建 writer 侧而不重新 `dupeDesc`，读端会因 `avail > extent` 守卫而静默恒读 0 |
| `out_get_buffer_size` > 新 FMQ | 会退化为分块自旋（功能正常，仅变慢） | 方案 D′/B 下 48k/AAC 不变；**D/D′ + F 同打时恰好取等号（零余量）**，AAC 档更会因 AF 的 16 帧对齐真的越界（8128 > 8114），见 §6 |
| libfmq 上限 | 创建侧卡 `align8(0x10+size) ≤ INT32_MAX`，映射侧拒 `extent > INT_MAX − 4096` | 30720 / 46080 远低于上限 |
| 构造函数初始队列仍是 7680 | ⚠️ **原文错**：`x19 = 7680` 时 `0x1f264 cmp x8,x19` / `0x1f268 b.ne` **不跳**，走 `0x1f26c` 返回 1（复用），`onSessionReady` 把构造函数那条队列 `dupeDesc` 给客户端 —— 48k/AAC/96k-16bit 用的是**它**，不是被覆盖 | 方案 D′/B 保持 48k/AAC 不变（仍复用）；方案 D/C 会让它成为死代码（每次进程启动白建一条再销毁，无害） |
| 延迟增加 | ⚠️ **复核修订**：环变大 = **可积压容量**变大，**不等于端到端延迟变大** —— 读端每 5 ms 轮询且实测经常读到 0（环常空），稳态填充由生产/消费速率比决定、不随容量上升。原文"48k 在方案 D 下仅 +20 ms"也算错（7680→11520 B @288000 B/s = **+13.33 ms** 容量）。`out_get_latency_ms` 不随容量变化，即**没有任何一侧会报告变化** | 容量变大是"可容忍更长的生产侧停顿"，不是延迟代价 |
| `0x1f184` 双重用途 | 单独改它会同时抬高阈值 | 用方案 D′（不动它），或两处同改（方案 C）；**不要单改 `0x1f184`** |
| 负 `dataIntervalUs`（新增） | `0x1f0c4` 是**无符号**比较，负值被放行；原 `csel` 会把它钳成 15360，而 D/D′ 的 `lsl` 会得到 ≈4 GB 直送 MQ 构造器；上游 `IsSoftwarePcmConfigurationValid` **不校验 `[+8]`** | 纯理论（需上游产生负值）；若要保留该钳位只能用固定档值的方案 A/B/C |
| OTA 后失效 | payload 属模块内容，OTA 不改模块目录，但若固件更新了被顶替的库需重新适配 | ⚠️ 核对**设备上那份没用**（就是模块自己 `cp` 过去的，永远相等）；应比对从 `romwork/xaga_dev` 或 super.img 解出的**厂商原件**（§10.4 第 2 条） |

**回退**：恢复 `payload/` 原始文件并重启（`touch /data/adb/modules/lhdcv5-real/disable && reboot`，或直接换回未修改的 `.so`）。

---

## 9. 方法论备忘（本次调查的纠错记录）

| 事项 | 经过 |
|---|---|
| **`PcmConfiguration` 布局误读** | 早期把 `[x1+8]` 读成 `sampleRateHz × 10⁴`、`[x1+0]` 读成 `bitsPerSample`。该模型在 48k/96k/192k 三档**恰好差 2 倍**，直到 4057 这个无法解释的值出现才暴露。真值是 `+0 sampleRateHz`、`+8 dataIntervalUs`（由 `PcmConfiguration::toString` @`0x18390` 的四次字段读取直接证明）。**教训：拟合上 3 个点不等于模型正确；要找一个模型必须解释、而旧模型解释不了的点。** |
| **两份线程报告直接冲突** | 报告 1 依据 AOSP `libfmq` 语义断言"payload 超过队列容量则写入返回 false，192k 写不进去"；报告 2 反汇编 `OutWritePcmData` 后发现是**分块 memcpy + 1ms×1000 自旋**。复核原始字（`0x2d1d0/0x2d310/0x2d320/0x2d328`）确认**报告 2 正确** —— 报告 1 把上游语义直接套用了。⚠️ **复核修订**：原文把这句写成"漏了 MTK 的分块包装层"，实则分块 + `usleep(1ms)`（`kFmqSendTimeoutMs=1000`、`kWritePollMs=1`）**是上游 AOSP 原生的**（`reference/aosp-src/d2/BluetoothAudioSession.cpp:48/51/402-431`，上游同样写 `ALOGD("data %zu/%zu overflow %d ms")`）—— MTK 只是把预算从上游的 10 ms 放宽到 1000 ms。**教训：同一问题的两份结论冲突时，去读原始字节，不要按"谁更符合上游"投票。** |
| **"尺寸经 fd 传递"表述不准确** | fd 不携带尺寸；尺寸在 `MQDescriptor` 的 grantor extent 里。结论（无需同步改客户端）不变，但机制描述需精确。（复核补充：ashmem region 长度确实随 size 变，只是容量取自 extent。） |
| **进程归属** | provider 与 `audio.bluetooth.default.so` 同进程，**不是** `com.android.bluetooth` —— 这一半对。⚠️ **复核修订**：但该进程**也不是** audioserver —— 实测 `BTAudioHalStream`/`MtkBTAudioProviderA2dpSW` 同 pid（1037/1040）而 `AudioFlinger_Threads` 是另一个 pid（1134/1179）。所以 FMQ 是"音频 HAL 进程内 AIDL 交接 + 跨进程到协议栈"，AudioFlinger 在第三个进程里，见 §1。 |
| **一条被驳倒的因果断言** | "192k 下 FMQ < tick 会导致写入阻塞或数据丢失" —— 数值前提成立，**因果断言被驳倒**（分块写入；且唯一能记录"写不满"的日志是 DEBUG 级，属构造性不可见）。已按"余量偏紧的鲁棒性问题"重新表述。 |
| **"证据不存在"≠"现象不存在"（复核新增）** | 原 §5.2① 用三条 grep 0 命中推出"写端零故障"，其中两条无效（DEBUG 级日志按构造打不出来、BQR 字段属控制器侧）。**教训：用"grep 不到"作证据之前，先确认那条日志在当前日志级别下打得出来。** |
| **"未解"未必真难（复核新增）** | §9 未解问题 6 把 `0x1f1c4`~`0x1f260` 当作难点，实际只需认出"`(end−begin)/8 × 0xAAAA…AB` = ÷24 元素计数"与"四个 `ldapr` 读同一对计数器、代数相消"，即可解析为 `x8 = grantors[2].extent`。**教训：把"没读懂的算术"和"读不懂的语义"分开记。** |

### 未解决的问题（2026-09-26 复核后的状态）

1. **放大后能否改善听感** —— **仍未解决**，且复核后更明确：192 kHz 的 19 次 CHOPPY 全部自带射频丢包计数、且落在读端饥饿突发之外，故"听感变好"很可能无感。需录音/主观 A/B 或 CHOPPY 次/分的受控对比。
2. **`out_write` 稳态下是否真的每次写 23040** —— **已定性为"结构上不可观测"**：HAL 只在 `state != STARTED` 时打 `bytes=`（`0x1cc64 cmp w8,#3; b.eq 0x1ccdc`；日志在 `0x1cc74` 的 severity=2 分支），抓包里确无一条 STARTED 态写入行。原表述"只在 STANDBY 一行观测到"也不准（live2 有 2 条 STANDBY + 33 条 DISABLED）。要证实需临时插桩或开 VERBOSE。
3. **`TX queue buffer size now=28 max=28` 的语义** —— 未解决（未核对源码）；已确认 31 次全落在 192 kHz 段、96 kHz 段 0 次。
4. **28672 字节的读请求** —— 未解决；已确认 `28672 = 0x7000` 来自 `libbluetooth_jni.so` 的固定缓冲（`0x6e7370`/`0x6e738c`），且它大于 192k 的 tick(23040) 也大于环(15360)，故必然短读。
5. **AAC 会话期间 HAL 输出流的真实采样率** —— ✅ **已结案**：`live3.log:107598`/`:107681` 有 `adev_open_output_stream: sample_rate=44100, format=1, preferred_data_interval_us=23000, frames=1014`，AF 确实以 44100 打开了 HAL 流；原"复用 48 kHz 流"的假设不成立。
6. **`0x1f1c4`~`0x1f260` 那段"当前 FMQ 容量"的算术** —— ✅ **已解码**：`x8 = grantors[2].extent + (c2−c4) + (c3−c1)`，四个 `ldapr` 是同一对计数器（`[MQ+0x10]`/`[MQ+0x18]`）被读两遍、代数相消，净结果就是"**当前环容量**"；`0x1f264 cmp x8,x19` / `0x1f268 b.ne` 即"容量与期望尺寸不等则重建队列"。原文的 `GateDescriptor` 应为 `GrantorDescriptor`（24 字节元素：`int32 fd@0`、`int64 offset@8`、`int64 extent@16`）。**副作用**：这条路径还解释了 §8 的"构造函数队列是复用而非被覆盖"。**残留漏洞**：日志打印的是 `w19`（期望值）而不是实测 extent，所以"看日志确认容量"属自证。
7. **（新增）`a2dp_vendor_lhdcv5_send_frames` 里的另一处 15360** —— `libbluetooth_jni.so` `0x7a5a10`（`mov w2, #0x3c00` 后 `bl` memset）与 `0x7a5d14`（`mov w4, #0x3c00`），用途未解。若它与"单次喂入/读取的字节上限"耦合，则放大 FMQ 后可能形成新的尺寸错配。**这是本改造唯一未排除的耦合风险。**

---

## 10. 逐字节复核记录与推荐实现路径（2026-09-26）

### 10.1 方法与规模

28 个子代理、473 万 token、113 分钟：7 片独立重导（core / sites / patches / logs / consumer / rw / hal）→ 每片立即接一个**对抗性复核者** → 6 条承重结论各由 2 个不同视角（反汇编语义 / 实测日志）的**独立反驳者**攻击 → 综合 + 完整性批判。原始产物见 `_scratch/wf_*.txt`、`_scratch/journal`（工作流 transcript）。

判定标准：每条结论必须给出原始证据（VA + 原始字 / 反汇编行 / 文件行号）；文档的每条偏移与十六进制字都拿去二进制里亲自核对；拿不到证据写 unverified，不推断。

### 10.2 复核通过的部分（可放心照抄）

| 项 | 证据强度 |
|---|---|
| 文件身份、`.text` VA == 文件偏移、`UpdateFMQSize @0x1f040` size 1116 | binary-verified |
| `PcmConfiguration` 四字段偏移（`toString @0x18390` 四次字段读 + `UpdateFMQSize` 双重印证） | binary-verified |
| 四组实测 `5760/11520/23040/4057`，且全库仅此四种组合 | log-verified |
| §2.7 四常量站点与"全库仅 4 处 7680/15360"（MOVZ 全 `.text` 扫描） | binary-verified |
| `w19` = FMQ 字节容量（`0x1f298 mov x1,x19` → PLT→GOT `0x268a0` = `AidlMessageQueue<int8_t,…>` 构造） | binary-verified |
| **附录 A 全部 8 个目标字 + 6 个原始字**（自算编码 + capstone 反汇编双向对撞） | binary-verified |
| §4.1 写端 1000×1ms 分块自旋、§4.2 读端 10×1ms、§4.4 `dupeDesc` 传描述符 | binary-verified |
| §3 HAL 两条公式（`out_get_buffer_size` / `FrameCount`），被 `adev_open_output_stream frames=960/1920/3840/1014` 印证 | binary-verified + log-verified |
| **"0x19c88 只放大返回值、不污染延迟上报"**（延迟链 `0x1c990 → 0x22140` 直接读 `[out+0x178]`/`[out+0x160]`，从不调 `0x19b40`） | binary-verified |
| §7.2 部署方式（`post-fs-data.sh` 第 32 行 `cp payload/*.so → /data/vendor/lhdcv5/`） | source-verified |

### 10.3 结论"FMQ 不是卡顿瓶颈"被**加强**的新证据

- 192 kHz 会话（23:11:30–23:38:09）内 19 次 `A2DP_AUDIO_CHOPPY` **全部**落在读端饥饿突发**之外**；其中 9 次落在一段连续 4 分钟、完全没有短读的区间里。
- 每次 CHOPPY 都自带射频计数（如 23:34:01 `retx=29136 notreached=19956 nack=8813`），报告间隔约 19 s —— 即"卡顿"是**射频丢包报告本身**。
- **反方向的旁证**：48 kHz（无尺寸违规）的 HAL 停摆事件比 192 kHz **更多**（live4 41 分钟内 129 条 `DISABLED failed to resume` + 172 条 `STARTING`）。最紧的档位并不是异常最多的档位。
- 但要注意措辞边界：只能说"**未被观测到**"。读端唯一的探针分辨率是 10 ms，<10 ms 的干涸会被静默恢复、不留痕；写端唯一能记录"写不满"的日志是 DEBUG 级。所以这是"探针看不见"，不是"证明无害"。

### 10.4 复核新发现的风险（本文档原未覆盖）

1. **方案 D/D′ 丢掉了一个意外的安全钳位。** `0x1f0c4` 是**无符号**比较，负的 `dataIntervalUs` 会被放行 → `w20` 为负 → 原 `csel` 安全退化成 15360，而 `lsl` 得到 `0xFFFFFE80 ≈ 4 GB` 直送 MQ 构造器；上游 `BluetoothAudioCodecs::IsSoftwarePcmConfigurationValid`（`libbluetooth_audio_session_aidl_mtk.so:0x21690`）只校验 `[+0]/[+4]/[+5]`，**从不读 `[+8]`**。可达性未经日志证实（需上游产生负值），属潜在回归。要保留钳位只能用方案 A/B/C。
2. **补丁基线未证实。** `payload/` 那份 `.so` 自身已被改过（`DT_NEEDED` 含绝对路径 `/data/vendor/lhdcv5/shimsym.so`、SONAME 被改写为 `…-mediatek.so`），且它与设备副本"一致"是循环论证（§2.1）。要做的是从 `romwork/xaga_dev` 或 super.img 解出**厂商原件**，比 `.text` 与四个站点原始字。**在核实前，"7680/15360 是 MTK 原值"这一点只有二进制事实、没有来源佐证** —— 若固件曾替换过被顶替的库，则所有偏移的适用性都需重判。
3. **同一 `.so` 另有 3 处 FMQ 创建点**（构造函数 `0x1ee58`、HearingAid `0x21c18`、LeAudio `0x23b88`，后者用浮点自算尺寸），本补丁只作用于 A2DP 软件链路那一个；关 offload 后 AAC/SBC/aptX/LDAC 都走被改函数，所以**影响面是"全 codec 的软件通路"，评估不能只看 LHDC**。
4. **`libbluetooth_jni.so` 的 LHDC V5 `send_frames` 里另有 15360**（`0x7a5a10`/`0x7a5d14`，用途未解）—— 若与"单次喂入上限"耦合，放大 FMQ 后会形成新的错配。这是唯一未排除的耦合。
5. **D/D′ + F 会自相抵消**（`write/FMQ` 回到 1.0），AAC 档更因 AF 的 16 帧对齐真的越界（8128 > 8114），见 §6。
6. **验证盲区**：`0x19c88` 打上后 HAL 自己的 `buffer_size` 日志仍打旧值；`out_write` 稳态长度不可观测；§7.3 原来的三条命令**只能证明"没变坏"**。
7. **失败路径静默**：`UpdateFMQSize` 返回 0 时 `startSession` 仍继续（`0x1f750 b 0x1f598`），客户端拿到上一次甚至构造函数的容量，且日志里不再出现新尺寸 —— 排障时容易误判"补丁没生效"。判据：`grep -E "Queue size too large|Unexpected PCM Configuration"` 应为空。

### 10.5 推荐实现路径

先厘清目标 —— 两个目标不该用同一手段。

**目标 A：治卡顿 → 不要动 FMQ。** 复核把 §5.1 从"中高置信"抬到"高"（§10.3）。可用的杠杆按效率排序：

1. **停在 96 kHz**（0.17 vs 0.62 次/分，约 3.6× 更好）—— 这是唯一有数据支撑的杠杆；
2. 改善射频条件（距离/遮挡/2.4 GHz 拥塞）；
3. 约束 ABR 不要超额承诺。⚠️ 注意"96 kHz + 高音质档"这条**本身不稳**：`abr_new.log` 显示 ABR 抬到 900 kbps 后 400 ms 内就降回 400→320。

目标 B：消除 192 kHz 的尺寸错配 / 增加余量 → 打 **方案 D′** 这一个字，不碰 HAL。

为什么是 D′ 而不是原文档推荐的 D：

| 对比项 | D′ | D | B |
|---|---|---|---|
| 48k / AAC | **逐字节不变** | 7680→11520 / 4057→8114 | 不变 |
| 96k/24 · 192k/24 | 23040 · 46080 | 同 | 46080 · 46080 |
| 自适应（88.2k/LDAC 32bit 等） | ✅ | ✅ | ❌（一律 46080） |
| 保留异常输入钳位 | ❌ | ❌ | ✅ |
| 对当前工作配置（48 kHz）的扰动 | **零** | 有（尺寸变 + 每次重建队列） | 零 |

理由：本项目日常在 48 kHz 听（现有链路工作正常），D′ 让 48 kHz 与 AAC **完全不变**，只修真正越界的 96k/192k；它仍是单字、仍自适应；它不动 `0x1f184`，所以不存在"双重用途踩坑"。代价是理论上的负 `dataIntervalUs` 钳位丢失（§10.4 第 1 条）—— 若要连这点也保住，用 **方案 B**（固定 46080、保留钳位），代价是 LDAC 等高档位一律 46080（容量超出但不是延迟）。

部署步骤（`tools/fmq_patch.py` 会先校验 `0x1f198` 的原始字，不符即拒绝）。**状态：第 1 步已完成（见文首"实施"行），第 2 步待设备上线**：

```bash
# 0) 先核实基线（强烈建议，见 §10.4 第 2 条）
md5sum module/lhdcv5-real/payload/android.hardware.bluetooth.audio-impl.so   # 期望 d044d1b9faf3f3a855703102fe6f247f

# 1) 打补丁（会先校验 0x1f198 的原始字，不符即拒绝）
python tools/fmq_patch.py --check
python tools/fmq_patch.py --apply Dp        # 期望输出新 md5 = 10a7203b5332c86d15f09ecd921da430

# 2) 部署
adb push module/lhdcv5-real /data/adb/modules/
adb reboot
```

**验证（用 §7.3 修订后的四条判据）**：核心是"尺寸生效 + 没变坏"。特别要盯的两点：48 kHz/AAC 的 `UpdateFMQSize` 应**仍是 7680**（若变成 11520/8114 说明打到方案 D 了）；`Queue size too large` / `Unexpected PCM Configuration` 应为空。

**回退**：`python tools/fmq_patch.py --revert Dp` 或 `touch /data/adb/modules/lhdcv5-real/disable && reboot`。

**一句话**：**目标 B 值得做，成本是 4 个字节；但别指望在任何日志或上报值里看到收益 —— 它的收益是"可容忍更长的生产侧停顿"。目标 A 不要用这个手段。**

### 10.6 实施与设备验证（方案 D′，2026-09-26）

**改动**：`module/lhdcv5-real/payload/android.hardware.bluetooth.audio-impl.so`

| 项 | 值 |
|---|---|
| 站点 | `0x1f198`（VA == 文件偏移） |
| 改动 | `0x52878009` `mov w9,#0x3c00` → `0x531F7A89` `lsl w9,w20,#1` |
| md5 | `d044d1b9faf3f3a855703102fe6f247f` → **`10a7203b5332c86d15f09ecd921da430`** |
| 完整性 | 与 git HEAD 原件逐字节比对：**只有 4 个字节不同**（`0x1f198..0x1f19c`，`09 80 87 52` → `89 7a 1f 53`），其余全长 163992 字节一字未动 |
| 工具 | `python tools/fmq_patch.py --apply Dp`（先校验原字再写入，读回一致；产物与参考件 `_scratch/impl_fmq_Dp.so` `cmp` 无差异） |

**部署**：推送到 `/data/adb/modules/lhdcv5-real/payload/` → `adb reboot`；开机后 `post-fs-data.sh` 将其复制到 `/data/vendor/lhdcv5/`，两份 md5 均为 `10a7203b…`。

**设备验证**（2026-09-26 19:38 起，同一开机周期内 LHDC V5 的 48 / 96 / 192 kHz 三档会话）

1. **运行中的字节（最强证据）** —— 从 HAL/provider 进程（pid 1041）内存里读出 `.text`：

   | VA | 原始字 | 指令 |
   |---|---|---|
   | `0x1f194` | `0b090114` | `add w20, w8, w9`（= `bytes_per_tick`） |
   | `0x1f198` | **`531f7a89`** | **`lsl w9, w20, #1`（D′ 在位）** |
   | `0x1f19c` | `6b0a029f` | `cmp w20, w10`（阈值 7680 保留） |
   | `0x1f1a4` | `1a8a8133` | `csel w19, w9, w10, hi`（判档保留） |

   即"跑着的"就是 D′，不只是磁盘上那份。（读数手法见 §5.5.6：`dd bs=16 skip=<addr>/16` 读 `/proc/<pid>/mem`。）

2. **三个档位的运行时观测（同一开机周期内全部命中）** —— 这是判别方案身份的关键：四个候选在 48k 上把 D（11520）与 D′/B（7680）分开，在 96k 上把 D′（23040）与 B（46080）分开，所以三个档位各观测一次即可唯一定位。

   | 会话档位 | `bytes_per_tick` | 实测 FMQ | D′ 期望 | 该观测排除掉的方案 |
   |---|---|---|---|---|
   | 48 kHz / 24 bit | 5760 | **7680** | 7680 | 方案 D（会给 11520） |
   | 96 kHz / 24 bit | 11520 | **23040** | 23040 | 方案 B（会给 46080） |
   | 192 kHz / 24 bit | 23040 | **46080** | 46080 | 未打补丁（会给 15360） |

   三个会话的 `PcmConfiguration` 都是 `{channelMode: STEREO, bitsPerSample: 24, dataIntervalUs: 20000}`，只有 `sampleRateHz` 分别是 `48000 / 96000 / 192000`。原始日志行：

   ```text
   19:38:17.666  MtkBTAudioProviderA2dpSW: UpdateFMQSize bytes_per_tick = 5760  - size of audio buffer 7680  byte(s)
   20:02:28.120  MtkBTAudioProviderA2dpSW: UpdateFMQSize bytes_per_tick = 11520 - size of audio buffer 23040 byte(s)
   20:00:02.310  MtkBTAudioProviderA2dpSW: UpdateFMQSize bytes_per_tick = 23040 - size of audio buffer 46080 byte(s)
   ```

   证据留存：`artifacts/live/fmq_dp_verify.log`（含拉取时刻仍能同时读到的 96k 与 48k 两条）。
   192 kHz 那一档正是原先的错配现场（环 15360 < 一个 tick 23040，只有 0.67 tick），现在为 46080 = 2 tick。

   至此**同一开机周期内两个分支都被执行过**：19:38:17 的 48 kHz 会话 → `7680`（低档保持不变），20:00:02 的 192 kHz 会话 → `46080`（高档自适应）。

3. **无副作用**：`Queue size too large` / `Unexpected PCM Configuration` 无输出；`FMQ datapath writing` 计数 0；`com.android.bluetooth` pid 全程 2725 未重启；crash 缓冲无 BT 崩溃；LHDC V5 在 48 / 96 / 192 kHz 三档下均正常工作。

未覆盖的部分（诚实边界）：

- **未做听感 / CHOPPY 对比**（§9 问题 1）—— 按 §10.3，本补丁本来就不该在这类指标上体现；"余量变大"在任何日志与上报值里都不可见（§7.3 复核修订）。
- 采样率切换本身没有可脚本化的开关：`settings secure/global` 里没有对应键（已实测），偏好由开发者选项经 `BluetoothA2dp.setCodecConfigPreference` 下发，仓库里记录过两次「采样率保持」的失败尝试（`d8f6517`）与最终实现（`b7e535e` 及后续修复）。本轮 48 → 192 → 96 → 48 kHz 的切换均来自设备侧操作，所以三个档位的观测窗口依赖手动切档。

**回退**：`python tools/fmq_patch.py --revert Dp` → 重推该文件 → 重启；或整模块停用 `touch /data/adb/modules/lhdcv5-real/disable && reboot`。

---

## 附录 A：字节级补丁速查

```text
文件: module/lhdcv5-real/payload/android.hardware.bluetooth.audio-impl.so
      (.text VA == 文件偏移; 原件 md5 d044d1b9faf3f3a855703102fe6f247f)

【方案 D′ · 首选（复核新增）】FMQ = max(7680, 2 × bytes_per_tick)；48k/AAC 逐字节不变
  0x1f198  0x52878009  mov  w9, #0x3c00 (15360)
         → 0x531F7A89  lsl  w9, w20, #1        （等价 0x0B140289 add w9, w20, w20）
  改后 md5 = 10a7203b5332c86d15f09ecd921da430

【方案 D】FMQ = 2 × bytes_per_tick（全档改大，含 48k/AAC）
  0x1f1a4  0x1A8A8133  csel w19, w9, w10, hi
         → 0x531F7A93  lsl  w19, w20, #1

【方案 B】仅抬高档（固定值，保留异常输入的钳位）
  0x1f198  0x52878009  mov  w9, #0x3c00 (15360)
         → 0x52968009  mov  w9, #0xb400 (46080)

【方案 A】最保守
  0x1f198  0x52878009  → 0x528F0009   mov w9, #0x7800 (30720)

【方案 C】两档同抬（必须两处）
  0x1f184  0x5283C00A  → 0x5287800A   mov w10, #0x3c00 (15360)
  0x1f198  0x52878009  → 0x52968009   mov w9,  #0xb400 (46080)

文件: module/lhdcv5-real/payload/audio.bluetooth.default.so
      (⚠️ 复核修订：**不是**放大 FMQ 的配套 —— 见 §6 方案 F。仅当你确实想让)
      (   AF 每次写更多字节（更深缓冲）时才动它，且必须与 FMQ 尺寸配对核算。)

【方案 F】放大每次写入量（不建议与 D/D′ 同打）
  0x19c88  0xAA1403E0  mov  x0, x20        → 0xD37FFA80  lsl x0, x20, #1   （不污染延迟上报）
  0x19340  0x2A1803E1  mov  w1, w24        → 0x531F7B01  lsl w1, w24, #1   （会抬高上报延迟）
  0x19c6C  0x9AC82694  lsr  x20, x20, x8   → 0xD503201F  nop               （低延迟折半；实测恒为空操作）
```

`mov wN, #imm16` 的编码：`0x52800000 | (imm16 << 5) | Rd`（`imm16` 为 16 位以内的值）。
`lsl wN, wM, #1` 的编码：`ubfm` 别名，`0x531F7A00 | (M << 5) | N`（32 位）；64 位为 `0xD37FFA00 | ...`。

**打补丁用脚本**：`tools/fmq_patch.py`（校验原字节 → 写入 → 打印新 md5，支持 `--list/--check/--apply/--revert`，可对副本操作而不动 `payload/`）：

```bash
python tools/fmq_patch.py --check                      # 只读：当前是哪个方案
python tools/fmq_patch.py --apply Dp                   # 打方案 D′（首选）
python tools/fmq_patch.py --apply Dp --file <某副本>   # 只改副本
```

参考产物：`_scratch/impl_fmq_Dp.so`（D′，md5 `10a7203b…`）、`_scratch/impl_fmq_D.so`（D，md5 `3162e5ecdf2b4670dcc6479e9d015635`）。

---

## 附录 B：证据索引

| 结论 | 证据 |
|---|---|
| FMQ 尺寸公式与常量 | `android.hardware.bluetooth.audio-impl.so` `0x1f040`–`0x1f1a8` 反汇编；符号表 `st_value=0x1f040, st_size=1116` |
| 四组实测值 | `artifacts/live/live*.log` 的 `UpdateFMQSize bytes_per_tick = N - size of audio buffer M byte(s)` |
| `4057` = AAC | `live.log:116060` `a2dp_aac_feeding_reset: PCM bytes 4057 per tick 23 ms`；`live.log:116059` `AAC frame_length = 1024`；**`live.log:116065`** `PcmConfiguration{... 44100 ... dataIntervalUs: 23000}`（⚠️ 旧引的 116081 是 `SetLowLatencyModeAllowed` W 行） |
| 写端分块 + 自旋 | `libbluetooth_audio_session_aidl_mtk.so:0x2d180` 反汇编（`0x2d1d0 mov w24,#0x3e8` / `0x2d320 mov w0,#0x3e8` / `0x2d328 sub w24,w24,#1`）；**上游同构**：`reference/aosp-src/d2/BluetoothAudioSession.cpp:48/51/402-431` |
| 读端 10 ms 超时 | `libbluetooth_jni.so:0x850b88 mov w26,#0xa`；日志 `ReadAudioData: N/M no data 10 ms`，其中 `N = len − total_read`、`M = len`（AOSP `client_interface_aidl.cc:478-484`） |
| HAL tick 来源 | `audio.bluetooth.default.so:0x19b40` / `0x1934c` / `FrameCount @0x22e40` |
| 读端饥饿对应生产侧停顿 | `live2.log` 的 99 条短读（8 簇）与 `NMAudioPlayer: AudioTrack(N): Pause` / `kAudioPlayerEOS` / HAL `Suspend`；⚠️ 旧引的 `l2c_link_check_send_pkts` 是 78 万行的空闲噪声，不可用作定位 |
| 尺寸经 MQDescriptor 传递 | 两端反汇编：session 库 / `libbluetooth_jni.so` 全 `.text` 无 7680/15360/46080 立即数；`dupeDesc @0x1fa80`；⚠️ 客户端 `UpdateDataPath @0x2ad40` 只构造对象、**不算**可用空间（可用空间算术在 `OutWritePcmData` 与 `client_interface_aidl.cc`） |
| 进程归属 | `BTAudioHalStream` 与 `MtkBTAudioProviderA2dpSW` 同 pid（1037/1040）、`AudioFlinger_Threads` 另一 pid（1134/1179）；`u:r:mtk_hal_audio` 0 命中 |
| AF 的写入量按 16 帧对齐 | `live3.log` `W/AudioFlinger_Threads: HAL output buffer size is 1014 frames but AudioMixer requires multiples of 16 frames` / `normal sink buffer size 1024 frames`（解释 `out_write bytes=4096`） |
| 失败日志按构造不可见 | `0x2d480 mov w0,#1` / `0x2d4b0 mov w3,#1`（`overflow` 为 DEBUG 级）；抓包里 tag `BTAudioSessionAidl` 895 行全 I 级、0 行 D/V |
| RF 为主导劣化 | `QUALITY_REPORT_ID_A2DP_AUDIO_CHOPPY`（192k 0.62 次/分 vs 96k 0.17 次/分），最高重传 29136 |
| AOSP `7680` 出处 | `reference/aosp-src/r7/hwif/aidldefault/A2dpSoftwareAudioProvider.cpp:31-41` |
| 尺寸经 MQDescriptor 传递（AIDL 定义） | `IBluetoothAudioProvider.aidl` 的 `startSession` 返回 `MQDescriptor<byte, SynchronizedReadWrite>`；`dupeDesc @0x1fa80`、`onSessionReady @0x1f760` |
