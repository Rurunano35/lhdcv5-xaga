// LHDC V5 —— 机型白名单准入（P0）与自适应码率上限
//
// 背景
// ----
// Redmi Note 11T Pro (xaga) 的蓝牙协议栈（libbluetooth_jni.so）在
// A2dpCodecConfig::createCodec 里读取 ro.product.name，并与 5 个机型代号
// 组成的白名单比对（corot / duchamp / zircon / rothko / malachite）。
// xaga 不在名单内，于是 LHDC V5 在编解码器**创建阶段**就被丢弃 ——
// 这发生在任何 HAL 交互之前，是 V5 的第一道、也是最先触发的门禁。
//
// 本模块做三组事（都是纯内存补丁）：
//   1. 白名单准入：createCodec 读 ro.product.name 时返回 "corot"；
//   2. ABR 上限：把 LHDC V5 自适应档的上限从 400 kbps 抬到**耳机宣告的最高档位**
//      （本机耳机宣告 7 = 900 kbps），共两处：三张 ABR 阶梯表的顶格数值、
//      以及让顶格生效的全局索引退格。不覆盖耳机的宣告，不做越权。
//      详细链路与证据见下方「LHDC V5 自适应（ABR）码率上限」一节。
//   3. 采样率偏好持久化：用户改过的采样率跨重连保持。详见下方
//      「采样率偏好持久化」一节。
//
// 为什么只做这些
// --------------
// 本项目的目标是让 V5 走**真实**通路。另有两道门禁（P1 跳转表分发、
// P2 codec_type 等值校验）属于"HIDL 边界没有 V5 结构"时期的**伪装**手段，
// 在 AIDL 通路打通后已无必要 —— 由配套的挂载部分提供
// AIDL 传输层，V5 以 codec_type=12 原生送达 HAL。
// 因此**准入这一项**刻意不碰 .text、不碰跳转表、不改写 codec_type。
// （后两项功能确实改了代码：ABR 降档改的是编码器库，采样率持久化改的是协议栈库，
//   各自的原因与跳板宿主选择见对应小节。）
//
// 实现
// ----
// 纯内存补丁：只把 libbluetooth_jni.so 的 GOT 里 osi_property_get 那一格
// 重定向到本模块的函数。GOT 位于数据页，mprotect(RW) 写入后恢复 R，
// 不涉及 PROT_EXEC，因此不会触发 SELinux 的 execmod 限制。
// 磁盘上的 APEX 保持字节级不变，不建立任何挂载，不修改任何系统属性。

// api.hpp 用到 dev_t / ino_t，须先引入系统类型头
#include <android/log.h>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>  // clock_gettime：重放的最小间隔用单调时钟
#include <sys/types.h>
#include <unistd.h>

#include "api.hpp"

#define LOG_TAG "LHDCV5A"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

constexpr const char *kTargetProcess = "com.android.bluetooth";
constexpr const char *kRuntimeLibPath = "/system/lib64/libandroid_runtime.so";
constexpr const char *kNativeLoaderPath = "/apex/com.android.art/lib64/libnativeloader.so";
constexpr const char *kSoname = "libbluetooth_jni.so";

// createCodec 中白名单比对所在处的指令：b.eq，同时用作构建指纹
constexpr uintptr_t kCreateCodecSite = 0x763470;
constexpr uint32_t kCreateCodecExpect = 0x540005c0u;

// osi_property_get 的 GOT 槽（取自 .rela.plt 的 r_offset）
constexpr uintptr_t kGotOsiPropertyGet = 0xf94428;
//
// 注意：这里【不能】去 hook dlopen。bionic 的 dlopen 用 __builtin_return_address(0)
// 反查调用者所在的 linker 命名空间，从本模块里调用原函数会让它到错误的命名空间里
// 查找，liblhdc*.so 直接加载失败并静默返回 NULL —— 实测会让 LHDC 从编码列表里消失。
// 需要"库加载完成后"的时机的话，只能用带显式命名空间参数的 android_dlopen_ext，
// 或者改用属性读取这类与返回地址无关的时点（本模块用的是后者）。

// 白名单命中的任意一个代号即可；用最贴近本机的（同为中端 MTK 平台）
constexpr const char *kSpoofName = "corot";

// ---------------------------------------------------------------------------
// LHDC V5 自适应（ABR）码率上限
//
// 实测链路（每一步都有二进制/日志证据，见 docs 的实现报告 §5.5）：
//
//   1. 上限最终由**耳机宣告**。协议栈在 a2dp_vendor_lhdcv5_encoder_init 里把
//      编解码器配置宣告的档位查一张 .rodata 表（libbluetooth_jni.so 0x2c407c，
//      0..7 恒等）换算成 max_bitrate_inx 交给编码器；核心库
//      lhdcv5_util_set_target_bitrate_inx 再把目标索引 clamp 到 [min, max]。
//      本机耳机在「高音质」档宣告 7 = LHDC_QUALITY_HIGH = 900 kbps，
//      在低音质档只宣告 5 = 400 kbps。**本模块不覆盖这个宣告。**
//   2. AUTO 档的起始码率由核心库写死：请求索引 13 时用 max(min_inx, 5)，即
//      400 kbps，与 ABR 表第 5 格（原来的 400）恰好一致。
//   3. ABR 的全局表索引 gABR_table_index 在 .bss（该库唯一的 4 字节全局，VA 0x8310），
//      初始化即置为表长-1 = 5。上爬取 next = min(index+1, 5)，随后要求 next > index
//      才下发 —— 索引已在 5 时该条件恒假，于是**冷启动永远不会上爬**，
//      只能降档后再爬回来。原设计里「表顶格 = ABR_MAX_STAGE_BITRATE = 400」，
//      所以表现就是封顶 400。
//
// 因此本模块做三件事：
//   a. 把三张表的**顶格**从 400 抬到 900（= 耳机能宣告的最高档位对应的阶梯索引 7）。
//      其余格子原样保留，避免引入该采样率家族阶梯里不存在的值。
//   b. 把「已到顶格」的 ABR 索引退回一格，使顶格的值也能被下发（见 nudge_abr_index）。
//   c. 把降档改成一次只降一格：原实现写死降回 table[0]（最小格），从 900 一次掉到 128
//      且要 5 个周期才爬回来；见下方 kAbrCodeSites / 跳板说明。这是本模块唯一改 .text 的地方，
//      跳板落在该库 .text 末尾的填充 + PLT0 死槽里，**不碰无损模式的实现**。
//
// 于是 ABR 的实际上限 = min(耳机宣告的档位, 900)：耳机宣告 7 时爬到 900 kbps，
// 只宣告 5 时仍是 400 kbps —— 不做任何越权。900 在每个采样率家族的阶梯里都存在
// （索引 7），且恰好落在耳机宣告的 max 之内，因此不依赖 clamp 去回收超额的请求。
//
// 表在 .rodata（第一个 LOAD 段），该库的 VA 与文件偏移完全相等，故直接按偏移定位。
// 写入前先核对原值，与本模块的目标构建不一致就整体放弃。
constexpr const char *kAbrSoname = "liblhdcv5BT_enc.so";

// ABR 全局表索引：该库 .bss 里唯一的 4 字节全局，VA == 文件偏移之外的固定值 0x8310。
// 它是普通可写内存，直接 store 即可 —— 不需要 mprotect，也就没有「改 .text」那些坑。
constexpr uintptr_t kAbrIdxOff = 0x8310;
constexpr uint32_t kAbrSlots = 6;  // 三张表都是 6 项

struct AbrTable {
    uintptr_t off;
    const char *label;
    uint32_t old_val[6];
    uint32_t new_val[6];
};

// 只动第 5 格（顶格）。900 是三张表各自采样率家族阶梯里的合法值（索引 7），
// 一旦 lhdcv5_util_get_bitrate_inx 解析不出就会走 ABR 的错误分支，故不能随便填。
constexpr AbrTable kAbrTables[] = {
    {0x2ac8, "44100", {128, 192, 240, 320, 400, 400}, {128, 192, 240, 320, 400, 900}},
    {0x2ab0, "48000", {128, 192, 256, 320, 400, 400}, {128, 192, 256, 320, 400, 900}},
    {0x2ae0, "96k/192k", {256, 320, 400, 400, 400, 400}, {256, 320, 400, 400, 400, 900}},
};

// ---------------------------------------------------------------------------
// 降档改成「一次只降一格」
//
// 原实现把降档落点写死成 table[0]（表的最小格）：从顶格 900 一次就掉到 128，
// 而且回爬要 5 个决策周期（实测每周期约 60 s）。两处硬编码都在 .text：
//   0x4f34  ldr w24,[x27]        ; 落点 = table[0]，随后由 get_bitrate_inx 换算成目标索引
//   0x50a0  str wzr,[x25,#0x310] ; 回写 gABR_table_index = 0
// 改成 tier-1 需要多几条指令，而该库 .text 没有任何空隙，模块自身又远在 ±128 MB
// 之外（4 字节 b 够不着）。
//
// 跳板宿主取**该库 .text 末尾的 12 字节零填充 + PLT0 槽**，0x6724..0x6750 是
// 44 字节连续可执行空间，且任何代码都不会执行到：
//   - 该库是 -z now 构建（.dynamic 的 DT_FLAGS=DF_BIND_NOW、DT_FLAGS_1=DF_1_NOW，
//     .rela.plt 的 addend 全为 0），没有惰性绑定，GOT 槽永远不会指向 PLT0；
//   - 已扫描全库可执行区间：没有任何 b / bl / b.cond 跳进 0x6724..0x6750；
//   - DT_RELR 只重定位 0x7000..0x7030（.data.rel.ro / .fini_array / .dynamic）。
// 于是跳板**完全避开了无损模式的实现** —— 上一版把跳板写进 0x50a8 起的无损提升
// 分支，会让支持无损的耳机执行到非原逻辑上；现在那段代码一个字节都不用动。
//
// 跳板与站点同在库内，全是短跳，不需要任何绝对地址，所以这里的每个字都是常量
// （编码逐条与二进制真值核对，见报告 §5.5.7）。
//
// 效果：900 → 400 → 320 → 256 → 192 → 128 一格一格降，回爬同理一格一格升。
//
// 跳板 A @0x6724：w24 = table[tier-1]（tier 取 [sp,#0x18]，即当前码率所在档），
//   补上被 b 覆盖的 0x4f38，再到 0x4f3c 的 mov w0,w24。
// 跳板 B @0x673c：把同一个 tier-1 写回 gABR_table_index，再到 0x4c58。
// 两处都用 cinc 把 tier-1 夹到 >= 0：tier==0 时退回 table[0]（与原行为一致），
// 同时避免 [x27, -1, uxtw #2] 这种越界读（会 SEGV）。
constexpr uintptr_t kAbrHost = 0x6724;   // 44 字节宿主的起点
constexpr uint32_t kAbrHostWords = 11;   // 44 / 4

// 宿主区间的原始字节：12 字节对齐填充 + PLT0 解析桩 5 条 + 3 条 nop。用作构建指纹。
constexpr uint32_t kAbrHostOrig[kAbrHostWords] = {
    0x00000000u, 0x00000000u, 0x00000000u,                              // .text 末尾填充
    0xa9bf7bf0u, 0xb0000010u, 0xf9410211u, 0x91080210u, 0xd61f0220u,    // PLT0
    0xd503201fu, 0xd503201fu, 0xd503201fu,                              // PLT0 槽内填充
};

// 跳板 A（0x6724..0x673c）+ 跳板 B（0x673c..0x6750）连成一片写入
constexpr uint32_t kAbrHostNew[kAbrHostWords] = {
    0xb9401be9u,  // ldr  w9, [sp, #0x18]           当前码率在 ABR 表里的档位
    0x51000529u,  // sub  w9, w9, #1                降一格
    0x1a890529u,  // cinc w9, w9, mi                夹到 >= 0（tier==0 时留在 table[0]）
    0xb8695b78u,  // ldr  w24, [x27, w9, uxtw #2]   落点 = table[tier-1]
    0xd10033a1u,  // sub  x1, x29, #0xc             被 b 覆盖掉的 0x4f38
    0x17fffa01u,  // b 0x4f3c                       回到 mov w0,w24 → get_bitrate_inx
    0xb9401be9u,  // ldr  w9, [sp, #0x18]
    0x51000529u,  // sub  w9, w9, #1
    0x1a890529u,  // cinc w9, w9, mi
    0xb9031329u,  // str  w9, [x25, #0x310]         回写 gABR_table_index = tier-1
    0x17fff943u,  // b 0x4c58
};

struct AbrCodeSite {
    uintptr_t off;
    uint32_t expect;
    uint32_t want;
    const char *what;
};

// 两个站点各改一条 4 字节 b；被覆盖的 0x4f38 / 0x50a4 不再被执行，字节原样保留。
constexpr AbrCodeSite kAbrCodeSites[] = {
    {0x4f34, 0xb9400378u, 0x140005fcu, "降档落点 -> 跳板A(table[tier-1])"},
    {0x50a0, 0xb903133fu, 0x140005a7u, "降档回写 -> 跳板B(index-1)"},
};

// ---------------------------------------------------------------------------
// 采样率偏好持久化
//
// 需求：用户在「设置 → 蓝牙 → 耳机 → 采样率」里改到 96 kHz 后，断开重连不会被打回
// 48 kHz，而是保持用户选定的值。要求是**持久化用户设置**，不是锁死采样率，也不许写死值。
//
// 根因（见 docs 的实现报告 §5.6）：AOSP 靠 A2dpService.updateDeveloperPreferences()
// 把用户偏好写进 Settings.Secure 并在重连时重新下发，**本 ROM 没有这个方法** ——
// 用户的选择只活在当前会话的内存里，一断连就归零。
//
// 做法：记住用户那一次调用，重连协商完后原样重放
// ----------------------------------------------
// 用户点选走的是这条路：
//   MIUI 页面 → btif_a2dp_source_encoder_user_config_update_event
//             → bta_av_co_set_codec_user_config(RawAddress const&,
//                                               btav_a2dp_codec_config_t const&, bool*)
// 它是设备上**唯一**被验证过能改到采样率的入口（手动点选确实有效）。所以本模块
// 只围绕这一次调用做两件事：
//   1. 捕获：把该符号的 GOT 槽（0xf942d8）重定向到模块，**只在返回 true 时**记下
//      那次调用用的**完整 56 字节配置**（不是只记采样率 —— 编解码器优先级、
//      位深、声道模式都在里面，重放时要原样送回）。
//   2. 重放：重连时 BtaAvCo::SetCodecOtaConfig（GOT 0xf941f0）协商完成后，
//      用记下的配置再调一次同一个入口 —— 与用户手动点选走的是同一条路。
//
// 为什么不改分派指令（走过的弯路，务必不要再试）
// --------------------------------------------
// 一开始的做法是把 A2dpCodecConfigLhdcV5Base::setCodecConfig 里 0x799668 的
// `ldr w9, [x20, #0x140]`（mCodecUserConfig.sample_rate）换成持久化的值，
// 让它走 .rodata 0x2c3ee0 那张跳转表。**实测无效**，原因：
//   那段 switch 的四个分支后面各有一道能力位校验 `tbz/tbnz w24, #N`，而
//   w24 在这台设备上恒为 0（它来自 `and w24, [sp+0x1c1], [x28+6]`，
//   而 [sp+0x1c1] 在函数序言里被 `stp xzr,xzr,[sp,#0x1b8]` 清零后全函数再无写入），
//   于是四个分支永远全部落到 0x799698 的兜底分支，那张跳转表是死代码。
//   决定采样率的是 0x7996c8 `ldr w8, [x20, #0x178]` 索引的另一张表
//   （.rodata 0x2c3f21），而 +0x178 是对象 +0x170 那个结构的 sample_rate ——
//   **正是 A2dpCodecConfig::setCodecUserConfig 写进去的那份数据**，
//   即「用户手动点选」才会写的东西。
// 所以：唯一可控的输入就是重放用户那次调用本身；改分派索引是白费力气。
//
// 重放时机与防环
// --------------
// 重放会经 BtaAvCo::SetCodecUserConfig 内部的 BTA_AvReconfig 触发一次
// AVDTP RECONFIGURE。RECONFIGURE 是对端只回 RECONFIGURE 响应、不会回 SET_CONFIG，
// 因此不会形成「重放 → 重新协商 → 再重放」的环；即便如此仍加一道最小间隔
// （kSrReplayMinGapMs）兜底，异常情况下也不会反复触发。
//
// 只对同一副耳机的 MAC 重放；换了对端就什么都不做，避免把 A 的设置塞给 B。
//
// 持久化介质：进程内全局（断连重连不重启 bluetooth 进程，已经够用）+ 一个文件
// （让偏好活过重启 / BT 进程重启）。文件写不进去不算失败，只降级成会话内保持。
// ---------------------------------------------------------------------------

// 这两个函数定义在本节之后
bool redirect_got(uintptr_t got_addr, void *replacement, void **out_original, const char *what);
void sr_save_pref();

// 捕获入口（用户偏好）与重放触发点（连接建立）
constexpr uintptr_t kGotUserConfig = 0xf942d8;  // bta_av_co_set_codec_user_config
// 重放必须等到**对端的 SEP 已注册**之后。试过在 SetCodecOtaConfig 之后重放，
// 原生直接报 "cannot find peer SEP to configure for codec type 12"
// （FindPeerSink 里读 peer->num_sinks == 0），因为那时 AVDTP 流还没 OPEN。
// ProcessOpen 是流打开的时刻，且它的参数里直接带 RawAddress。
constexpr uintptr_t kGotOpen = 0xf941f8;        // BtaAvCo::ProcessOpen
// 「当前实际生效的采样率」只能靠读原生自己的状态得到。A2dpCodecs::
// getCodecConfigAndCapabilities 会把当前配置写出到它的第 1 个参数，
// 所以包一层它就有了一个可靠的读数（也用来判断重放到底有没有生效）。
constexpr uintptr_t kGotGetCfg = 0xf95a28;      // A2dpCodecs::getCodecConfigAndCapabilities
// 捕获入口本体（28 字节的参数改写封装）的指纹：认不出构建就不动手
constexpr uint32_t kThunkOrig[7] = {
    0xaa0003e8u,  // mov x8, x0
    0xaa0203e3u,  // mov x3, x2
    0xaa0103e2u,  // mov x2, x1
    0x90004940u,  // adrp x0, #0xfc1000
    0x91330000u,  // add  x0, x0, #0xcc0
    0xaa0803e1u,  // mov  x1, x8
    0x1422aeb2u,  // b    0xf453c0
};

// btav_a2dp_codec_config_t 是 56 字节，字段顺序来自 AOSP，偏移已在设备上核对：
// codec_type(+0x00) codec_priority(+0x04) sample_rate(+0x08) bits_per_sample(+0x0C)
// channel_mode(+0x10) [pad +0x14] codec_specific_1..4(+0x18/+0x20/+0x28/+0x30)
struct SrCodecConfig {
    int32_t codec_type;
    int32_t codec_priority;
    uint32_t sample_rate;
    uint32_t bits_per_sample;
    uint32_t channel_mode;
    uint32_t pad;
    int64_t codec_specific[4];
};
static_assert(sizeof(SrCodecConfig) == 56, "btav_a2dp_codec_config_t 必须是 56 字节");

uintptr_t g_sr_bias = 0;      // libbluetooth_jni.so 的 load bias；0 表示尚未就绪
SrCodecConfig g_sr_cfg{};     // 用户最后一次选中的完整配置
uint8_t g_sr_mac[6] = {0};    // 记录时的对端地址
bool g_sr_have = false;       // g_sr_cfg / g_sr_mac 是否有效

const char *g_sr_pref_path = nullptr;
bool g_sr_pref_probed = false;

int64_t sr_now_ms() {
    struct timespec ts {};
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

// 偏好文件落点。com.android.bluetooth 的域是 u:r:bluetooth:s0，而 /data/misc/bluedroid
// 的 label 是 bluetooth_data_file、属主 bluetooth（bt_config.conf 就是它自己写的），
// 所以首选那里；万一哪天策略变了，退到 /data/local/tmp，再不行就只靠进程内全局。
constexpr const char *kSrPrefCandidates[] = {
    "/data/misc/bluedroid/lhdcv5_sr.conf",
    "/data/local/tmp/lhdcv5_sr.conf",
};

void sr_pick_path() {
    if (g_sr_pref_probed) return;
    g_sr_pref_probed = true;
    for (const char *p : kSrPrefCandidates) {
        FILE *f = fopen(p, "ae");  // 只探测可写性，不截断既有内容
        if (f != nullptr) {
            fclose(f);
            g_sr_pref_path = p;
            LOGI("偏好文件落点：%s", p);
            return;
        }
        LOGE("偏好文件 %s 不可写 errno=%d", p, errno);
    }
    LOGE("没有可写的偏好文件 —— 采样率偏好只在本次 bluetooth 进程内保持");
}

// 文件格式：一行 "<对端 MAC 12 位十六进制> <56 字节配置的 112 位十六进制>"。
// 只认 MAC 与长度都对得上的行；老格式（只剩采样率）一律忽略，当作没有偏好。
void sr_load_pref() {
    if (g_sr_pref_path == nullptr) return;
    FILE *f = fopen(g_sr_pref_path, "re");
    if (f == nullptr) return;

    char mac[16] = {0};
    char hex[130] = {0};
    const int n = fscanf(f, "%12s %128s", mac, hex);
    fclose(f);
    if (n != 2 || strlen(hex) != sizeof(SrCodecConfig) * 2) {
        if (n > 0) LOGI("偏好文件格式不认识（按老格式忽略）：%s", hex[0] ? hex : mac);
        return;
    }

    uint8_t mac_bytes[6] = {0};
    for (int i = 0; i < 6; i++) {
        unsigned v = 0;
        if (sscanf(mac + i * 2, "%2x", &v) != 1) return;
        mac_bytes[i] = static_cast<uint8_t>(v);
    }
    uint8_t raw[sizeof(SrCodecConfig)] = {0};
    for (size_t i = 0; i < sizeof(raw); i++) {
        unsigned v = 0;
        if (sscanf(hex + i * 2, "%2x", &v) != 1) return;
        raw[i] = static_cast<uint8_t>(v);
    }
    memcpy(&g_sr_cfg, raw, sizeof(g_sr_cfg));
    memcpy(g_sr_mac, mac_bytes, sizeof(g_sr_mac));
    g_sr_have = true;
    LOGI("从 %s 读到用户偏好：codec_type=%d priority=%d sample_rate=0x%x bits=0x%x channel=0x%x",
         g_sr_pref_path, g_sr_cfg.codec_type, g_sr_cfg.codec_priority, g_sr_cfg.sample_rate,
         g_sr_cfg.bits_per_sample, g_sr_cfg.channel_mode);
}

void sr_save_pref() {
    if (g_sr_pref_path == nullptr || !g_sr_have) return;
    FILE *f = fopen(g_sr_pref_path, "we");
    if (f == nullptr) {
        LOGE("偏好文件 %s 不可写 errno=%d —— 偏好只在本次 bluetooth 进程内保持",
             g_sr_pref_path, errno);
        return;
    }
    for (int i = 0; i < 6; i++) fprintf(f, "%02x", g_sr_mac[i]);
    fputc(' ', f);
    const uint8_t *raw = reinterpret_cast<const uint8_t *>(&g_sr_cfg);
    for (size_t i = 0; i < sizeof(g_sr_cfg); i++) fprintf(f, "%02x", raw[i]);
    fputc('\n', f);
    fclose(f);
}

// ---------------------------------------------------------------------------
// 捕获用户选择。bta_av_co_set_codec_user_config(RawAddress const&, config const&, bool*)
using set_user_config_t = bool (*)(const void *, const SrCodecConfig *, bool *);
set_user_config_t g_orig_set_user_config = nullptr;

bool hooked_set_user_config(const void *peer_address, const SrCodecConfig *cfg, bool *restart) {
    if (g_orig_set_user_config == nullptr) return false;
    const bool ok = g_orig_set_user_config(peer_address, cfg, restart);
    if (!ok) return false;  // 没生效的那几项不记

    g_sr_cfg = *cfg;
    if (peer_address != nullptr) {
        memcpy(g_sr_mac, peer_address, sizeof(g_sr_mac));
    }
    g_sr_have = true;
    LOGI("捕获用户偏好并已生效：codec_type=%d priority=%d sample_rate=0x%x bits=0x%x "
         "channel=0x%x specific=%lld/%lld/%lld/%lld",
         cfg->codec_type, cfg->codec_priority, cfg->sample_rate, cfg->bits_per_sample,
         cfg->channel_mode, static_cast<long long>(cfg->codec_specific[0]),
         static_cast<long long>(cfg->codec_specific[1]),
         static_cast<long long>(cfg->codec_specific[2]),
         static_cast<long long>(cfg->codec_specific[3]));
    sr_save_pref();
    return true;
}

// ---------------------------------------------------------------------------
// 连接建立（AVDTP 流已打开）后，把用户那次选择原样重放一遍 —— 重试到生效为止
//
// 为什么必须重试：原生在连接刚建立时会给两个「还没准备好」的拒绝，
// 都已经在设备上实测到：
//   bta_av_co.cc(2054) E ... cannot find peer SEP to configure for codec type 12
//   bta_av_co.cc(2039) W ... not all peer's capabilities have been retrieved
// 用户手动点选之所以有效，是因为那时候对端状态早就齐了。所以这里不做「挑一个
// 完美时点」的猜测，改成：每次拿到读数就比对，不一致就再试一次，一致就收手。
// 失败的重放是空操作，成功的那次会触发一次 AVDTP RECONFIGURE，所以「生效即停」
// 既不会多触发也不会漏。

using process_open_t = void (*)(void *, uintptr_t, const void *, uintptr_t);
process_open_t g_orig_process_open = nullptr;

// A2dpCodecs::getCodecConfigAndCapabilities(btav_a2dp_codec_config_t* out, vector*, vector*)
using get_cfg_t = bool (*)(void *, SrCodecConfig *, void *, void *);
get_cfg_t g_orig_get_cfg = nullptr;

volatile uint32_t g_sr_effective = 0;  // 原生当前实际生效的采样率

uint8_t g_sr_pending_mac[6] = {0};     // 本次连接的对端（准备重放）
bool g_sr_pending = false;
int g_sr_tries = 0;
int64_t g_sr_next_try_ms = 0;

constexpr int kSrMaxTries = 12;        // 最多试 12 次
constexpr int64_t kSrRetryGapMs = 1000;

bool hooked_get_cfg(void *self, SrCodecConfig *out, void *v1, void *v2) {
    bool ok = false;
    if (g_orig_get_cfg != nullptr) ok = g_orig_get_cfg(self, out, v1, v2);
    if (ok && out != nullptr) g_sr_effective = out->sample_rate;
    return ok;
}

// 由频繁出现的时点（属性读取）驱动，不必自己造定时器
void sr_tick() {
    if (!g_sr_pending || !g_sr_have || g_orig_set_user_config == nullptr) return;

    if (g_sr_effective == g_sr_cfg.sample_rate) {
        LOGI("采样率已生效（实际 = 期望 = 0x%x）—— 重放结束，共试 %d 次", g_sr_effective,
             g_sr_tries);
        g_sr_pending = false;
        return;
    }
    if (g_sr_tries >= kSrMaxTries) {
        LOGI("重放 %d 次仍未生效（实际仍为 0x%x，期望 0x%x）—— 放弃，本次连接不再尝试",
             g_sr_tries, g_sr_effective, g_sr_cfg.sample_rate);
        g_sr_pending = false;
        return;
    }

    const int64_t now = sr_now_ms();
    if (g_sr_next_try_ms != 0 && now < g_sr_next_try_ms) return;
    g_sr_tries++;
    g_sr_next_try_ms = now + kSrRetryGapMs;

    bool restart = false;
    const bool ok = g_orig_set_user_config(g_sr_pending_mac, &g_sr_cfg, &restart);
    LOGI("第 %d/%d 次重放用户偏好：期望 0x%x，返回 %d（实际仍为 0x%x，restart=%d）", g_sr_tries,
         kSrMaxTries, g_sr_cfg.sample_rate, ok ? 1 : 0, g_sr_effective, restart ? 1 : 0);
}

// BtaAvCo::ProcessOpen(unsigned char seid, RawAddress const& peer_address, unsigned short mtu)
void hooked_process_open(void *self, uintptr_t seid, const void *peer_addr, uintptr_t mtu) {
    if (g_orig_process_open != nullptr) g_orig_process_open(self, seid, peer_addr, mtu);
    if (!g_sr_have || peer_addr == nullptr) return;
    if (memcmp(peer_addr, g_sr_mac, sizeof(g_sr_mac)) != 0) {
        LOGI("本次对端不是记录那副耳机 —— 不重放");
        return;
    }
    memcpy(g_sr_pending_mac, peer_addr, sizeof(g_sr_pending_mac));
    g_sr_pending = true;
    g_sr_tries = 0;
    g_sr_next_try_ms = 0;  // 立刻试第一次
    LOGI("连接建立，准备重放用户偏好（期望 0x%x，当前实际 0x%x）", g_sr_cfg.sample_rate,
         g_sr_effective);
}

// ---------------------------------------------------------------------------
// 装钩子。认不出构建就整体放弃，绝不在陌生代码上动手。
bool sr_install() {
    // 捕获入口必须还是那个三参数改写封装
    for (int i = 0; i < 7; i++) {
        const uint32_t cur =
            *reinterpret_cast<const volatile uint32_t *>(g_sr_bias + 0x6998e0 + i * 4);
        if (cur != kThunkOrig[i]) {
            LOGE("用户配置入口 0x%08x 与本补丁的目标构建不一致（期望 0x%08x 实际 0x%08x）"
                 " —— 放弃采样率持久化", 0x6998e0 + i * 4, kThunkOrig[i], cur);
            return false;
        }
    }

    // 捕获入口：GOT 重定向（与 P0 同款手法，纯数据页写入）
    if (!redirect_got(g_sr_bias + kGotUserConfig,
                      reinterpret_cast<void *>(&hooked_set_user_config),
                      reinterpret_cast<void **>(&g_orig_set_user_config),
                      "采样率捕获入口")) {
        LOGE("捕获入口注册失败 —— 无法记录用户选择");
    }
    // 重放触发点
    if (!redirect_got(g_sr_bias + kGotOpen,
                      reinterpret_cast<void *>(&hooked_process_open),
                      reinterpret_cast<void **>(&g_orig_process_open),
                      "采样率重放触发点")) {
        LOGE("重放触发点注册失败 —— 重连时不会重新下发偏好");
    }

    // 生效读数
    if (!redirect_got(g_sr_bias + kGotGetCfg, reinterpret_cast<void *>(&hooked_get_cfg),
                      reinterpret_cast<void **>(&g_orig_get_cfg), "采样率生效读数")) {
        LOGE("生效读数注册失败 —— 重放将无法判断是否成功");
    }

    if (g_sr_have) {
        LOGI("已载入用户偏好（sample_rate=0x%x）—— 连接建立后会原样重放", g_sr_cfg.sample_rate);
    } else {
        LOGI("暂无用户偏好 —— 用户改一次采样率后才会被记录，本模块在此之前完全不介入");
    }
    return true;
}
// ---------------------------------------------------------------------------

uintptr_t find_load_bias(const char *soname) {
    FILE *f = fopen("/proc/self/maps", "re");
    if (f == nullptr) return 0;

    char line[512];
    uintptr_t bias = 0;
    while (fgets(line, sizeof(line), f) != nullptr) {
        if (strstr(line, soname) == nullptr) continue;
        // 只采信可读映射：加载过程中某段可能已列出但保护位尚未就绪，
        // 此时访问会以 SEGV_ACCERR 崩溃。
        char perms[8] = {0};
        uintptr_t start = 0, off = 0;
        if (sscanf(line, "%" SCNxPTR "-%*x %7s %" SCNxPTR, &start, perms, &off) != 3) continue;
        if (perms[0] != 'r') continue;
        bias = start - off;
        break;
    }
    fclose(f);
    return bias;
}

// 只用于数据页（.rodata / GOT）。首次 mprotect 失败就**不写**，避免留下半改状态。
//
// 不要拿它去改 .text：本机 SELinux 下 RW→恢复 R|X 会被 execmod 拒绝（实测 errno=13），
// 而 memcpy 已经执行，页会永久失去执行位，一执行到那页就 SEGV_ACCERR。详见实现报告 §5.5.3。
bool patch_bytes(uintptr_t addr, const void *src, size_t len) {
    const long page_size = sysconf(_SC_PAGESIZE);
    const uintptr_t first = addr & ~(static_cast<uintptr_t>(page_size) - 1);
    const uintptr_t last = (addr + len - 1) & ~(static_cast<uintptr_t>(page_size) - 1);

    for (uintptr_t p = first; p <= last; p += page_size) {
        errno = 0;
        if (mprotect(reinterpret_cast<void *>(p), page_size, PROT_READ | PROT_WRITE) != 0) {
            LOGE("patch_bytes: mprotect(RW) @0x%" PRIxPTR " 失败 errno=%d —— 不写入", p, errno);
            return false;
        }
    }

    memcpy(reinterpret_cast<void *>(addr), src, len);

    bool ok = true;
    for (uintptr_t p = first; p <= last; p += page_size) {
        errno = 0;
        if (mprotect(reinterpret_cast<void *>(p), page_size, PROT_READ) != 0) {
            LOGE("patch_bytes: 恢复 R @0x%" PRIxPTR " 失败 errno=%d", p, errno);
            ok = false;
        }
    }
    return ok;
}

// 写 .text。与 patch_bytes 的唯一区别：首次 mprotect 就带上 X（页自始至终可执行，
// 没有「瞬时不可执行」的崩溃窗口）。恢复成 R|X 会被 SELinux 以 execmod 拒绝
// （实测 errno=13），那就保持 RWX —— 可执行位没丢，不影响运行。
// 绝不要用 patch_bytes 去写 .text：它先摘 X，恢复失败就会把页永久留在不可执行状态。
bool patch_text(uintptr_t addr, const void *src, size_t len, const char *what) {
    const long page_size = sysconf(_SC_PAGESIZE);
    const uintptr_t first = addr & ~(static_cast<uintptr_t>(page_size) - 1);
    const uintptr_t last = (addr + len - 1) & ~(static_cast<uintptr_t>(page_size) - 1);

    for (uintptr_t p = first; p <= last; p += page_size) {
        errno = 0;
        if (mprotect(reinterpret_cast<void *>(p), page_size,
                     PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
            LOGE("%s: mprotect(RWX) @0x%" PRIxPTR " 失败 errno=%d —— 不改写", what, p, errno);
            return false;
        }
    }

    memcpy(reinterpret_cast<void *>(addr), src, len);

    for (uintptr_t p = first; p <= last; p += page_size) {
        errno = 0;
        if (mprotect(reinterpret_cast<void *>(p), page_size, PROT_READ | PROT_EXEC) != 0) {
            LOGI("%s: 恢复 R|X 被拒（页保持 RWX，可执行位未丢）", what);
        }
    }
    return true;
}

// ---------------------------------------------------------------------------

void try_abr_patch();

uintptr_t g_abr_bias = 0;  // liblhdcv5BT_enc.so 的 load bias；0 表示尚未映射

// 上爬门槛的绕过。原逻辑取 next = min(index+1, 表长-1)，随后要求 next > index 才下发；
// 而 index 初值就是表长-1，于是「已到顶格」时 next == index 恒成立，顶格的值永远用不上
// （实测冷启动封顶 400 kbps）。把已到顶格的索引退回一格，下一次决策就走正常的
// "取 table[index+1]" 路径，顶格的值照样下发 —— 等价于放宽那条门槛。
//
// 为什么不直接改那条分支指令：对 .text 的两条路都被 SELinux 堵死 ——
// mprotect 加回 X 被 execmod 拒绝（errno=13），且失败的页会留在不可执行状态，
// 一执行到就 SEGV_ACCERR（实测把蓝牙打进崩溃循环）；/proc/self/mem 连 open 都 EACCES。
// 而这个索引是 .bss 里的普通可写内存，直接 store 即可，不涉及任何保护位。
//
// 只在确实等于顶格时写，所以降档（索引归 0 后的上爬）路径完全不受影响。
void nudge_abr_index() {
    if (g_abr_bias == 0) return;
    auto *idx = reinterpret_cast<volatile uint32_t *>(g_abr_bias + kAbrIdxOff);
    if (*idx == kAbrSlots - 1) *idx = kAbrSlots - 2;
}

using osi_property_get_t = int (*)(const char *, char *, const char *);
osi_property_get_t g_orig_osi_property_get = nullptr;

int hooked_osi_property_get(const char *key, char *value, const char *default_value) {
    // ABR 表补丁的触发线：编码器库由协议栈运行时按需加载，而那条加载路径上
    // 没有一个可以安全 hook 的点（原因见 kGotOsiPropertyGet 处）。属性读取是
    // 协议栈里稳定出现的时点，未映射时代价只是一次 /proc/self/maps 扫描。
    try_abr_patch();
    nudge_abr_index();
    sr_tick();

    // createCodec 只认 5 个机型代号；这里让它看到白名单内的一个。
    if (key != nullptr && value != nullptr && strcmp(key, "ro.product.name") == 0) {
        strcpy(value, kSpoofName);
        LOGI("机型伪装命中: ro.product.name -> %s", kSpoofName);
        return static_cast<int>(strlen(kSpoofName));
    }
    if (g_orig_osi_property_get == nullptr) return 0;
    return g_orig_osi_property_get(key, value, default_value);
}

// ---------------------------------------------------------------------------

bool g_armed = false;     // 尚未处理 libbluetooth_jni.so
bool g_applied = false;   // libbluetooth_jni.so 补丁已尝试过（无论成败）
bool g_abr_done = false;  // ABR 表已处理（或已放弃重试）

void apply_patches();
void apply_abr_patch();

// 目标库可能比 libbluetooth_jni.so 晚很多才映射（首次建 LHDC 连接时才 dlopen），
// 所以未映射不算"处理过"，留到下一次调用再试。
void try_abr_patch() {
    if (g_abr_done) return;
    if (find_load_bias(kAbrSoname) == 0) return;
    g_abr_done = true;
    apply_abr_patch();
}

void maybe_patch(const char *name) {
    if (name == nullptr) return;
    // 两个目标库的加载先后不确定，各自独立处理
    if (g_armed && !g_applied && strstr(name, kSoname) != nullptr) {
        g_armed = false;
        g_applied = true;
        apply_patches();
        return;
    }
    if (strstr(name, kAbrSoname) != nullptr) try_abr_patch();
}

using open_native_library_t = void *(*)(JNIEnv *, int32_t, const char *, jobject,
                                        const char *, void *, bool *, char **);
open_native_library_t g_orig_open_native_library = nullptr;

void *hooked_open_native_library(JNIEnv *env, int32_t target_sdk_version, const char *path,
                                 jobject class_loader, const char *caller_location,
                                 void *library_path, bool *needs_native_bridge, char **error_msg) {
    void *handle = nullptr;
    if (g_orig_open_native_library != nullptr) {
        handle = g_orig_open_native_library(env, target_sdk_version, path, class_loader,
                                            caller_location, library_path, needs_native_bridge,
                                            error_msg);
    }
    maybe_patch(path);
    return handle;
}

using android_dlopen_ext_t = void *(*)(const char *, int, const void *);
android_dlopen_ext_t g_orig_android_dlopen_ext = nullptr;

void *hooked_android_dlopen_ext(const char *filename, int flag, const void *extinfo) {
    void *handle = nullptr;
    if (g_orig_android_dlopen_ext != nullptr) {
        handle = g_orig_android_dlopen_ext(filename, flag, extinfo);
    }
    // dlopen 已返回，库此时完成映射与重定位，是唯一安全的改造时机
    // （轮询 /proc/self/maps 可能看到保护位尚未确定的段而崩溃）。
    maybe_patch(filename);
    return handle;
}

// ---------------------------------------------------------------------------

bool redirect_got(uintptr_t got_addr, void *replacement, void **out_original,
                  const char *what) {
    const uintptr_t current = *reinterpret_cast<volatile uintptr_t *>(got_addr);
    if (current == 0) {
        LOGE("%s: GOT 槽 0x%" PRIxPTR " 为空，拒绝改写", what, got_addr);
        return false;
    }
    if (current == reinterpret_cast<uintptr_t>(replacement)) {
        LOGI("%s: GOT 槽已指向本模块", what);
        return true;
    }
    // 必须先交出原函数再改 GOT：本进程是多线程的，GOT 一改，
    // 任何正在调该符号的线程就会进入本模块的 hook，此时若 out_original
    // 还是空，hook 只能返回空值 —— dlopen 返回 NULL 会静默毁掉调用方
    // 的加载（实测会让 LHDC 编码器库加载失败、编码列表里丢掉 LHDC）。
    *out_original = reinterpret_cast<void *>(current);

    if (!patch_bytes(got_addr, &replacement, sizeof(replacement))) {
        LOGE("%s: 无法写入 GOT 槽 0x%" PRIxPTR, what, got_addr);
        return false;
    }

    const uintptr_t after = *reinterpret_cast<volatile uintptr_t *>(got_addr);
    const bool ok = after == reinterpret_cast<uintptr_t>(replacement);
    LOGI("%s: GOT 0x%" PRIxPTR " 0x%" PRIxPTR " -> 0x%" PRIxPTR " (%s)", what, got_addr,
         current, after, ok ? "读回一致" : "读回不一致");
    return ok;
}

void apply_patches() {
    LOGI("=== apply_patches: begin ===");

    const uintptr_t bias = find_load_bias(kSoname);
    if (bias == 0) {
        LOGE("本进程中找不到 %s", kSoname);
        return;
    }
    LOGI("load bias = 0x%" PRIxPTR, bias);

    // 构建指纹：只校验 P0 那一处，不匹配就整体放弃
    const uint32_t site =
        *reinterpret_cast<const volatile uint32_t *>(bias + kCreateCodecSite);
    LOGI("createCodec 处原始字节 = 0x%08x", site);
    if (site != kCreateCodecExpect) {
        LOGE("本机库与该补丁的目标构建不一致 —— 放弃改写");
        LOGE("  期望 0x%08x，实际 0x%08x", kCreateCodecExpect, site);
        return;
    }
    LOGI("构建指纹校验通过");

    redirect_got(bias + kGotOsiPropertyGet,
                 reinterpret_cast<void *>(&hooked_osi_property_get),
                 reinterpret_cast<void **>(&g_orig_osi_property_get), "P0 osi_property_get");

    // 采样率偏好持久化。与准入是两件独立的事：这里的指纹认不出来就自己放弃，
    // 不影响上面那两项已经装好的补丁。
    g_sr_bias = bias;
    sr_pick_path();
    sr_load_pref();
    sr_install();

    // 万一编码器库在本次加载的依赖闭包里已经就位
    try_abr_patch();

    LOGI("=== apply_patches: done ===");
}

// 降档改成一格一格降。三步走，顺序不能变：
//   1) 先只读地把宿主 44 字节与两个站点都核对一遍 —— 构建不对（比如哪天换成惰性绑定的
//      构建，PLT0 就成了活代码）就整体放弃，绝不能在认错构建的情况下往别人代码区里写；
//   2) 写跳板；
//   3) 最后才把站点改成跳过去。反过来会出现「站点已指向尚未写入的跳板」的窗口。
void apply_abr_code_patches(uintptr_t bias) {
    for (uint32_t i = 0; i < kAbrHostWords; i++) {
        const uintptr_t addr = bias + kAbrHost + i * 4;
        const uint32_t cur = *reinterpret_cast<const volatile uint32_t *>(addr);
        // 允许已是目标值，便于重复执行时幂等
        if (cur != kAbrHostOrig[i] && cur != kAbrHostNew[i]) {
            LOGE("跳板宿主 0x%" PRIxPTR " 与本补丁的目标构建不一致（期望 0x%08x 实际 0x%08x）"
                 " —— 放弃降档改写", kAbrHost + i * 4, kAbrHostOrig[i], cur);
            return;
        }
    }
    for (const AbrCodeSite &s : kAbrCodeSites) {
        const uint32_t cur = *reinterpret_cast<const volatile uint32_t *>(bias + s.off);
        if (cur != s.expect && cur != s.want) {
            LOGE("%s 站点 0x%" PRIxPTR " 与本补丁的目标构建不一致（期望 0x%08x 实际 0x%08x）"
                 " —— 放弃降档改写", s.what, s.off, s.expect, cur);
            return;
        }
    }

    if (!patch_text(bias + kAbrHost, kAbrHostNew, sizeof(kAbrHostNew), "降档跳板")) {
        LOGE("跳板写入失败 —— 站点保持原样（降档仍回 table[0]）");
        return;
    }
    {
        uint32_t after[kAbrHostWords] = {0};
        memcpy(after, reinterpret_cast<const void *>(bias + kAbrHost), sizeof(after));
        LOGI("降档跳板 %zu 字节写入 0x%" PRIxPTR "..0x%" PRIxPTR "（%s）",
             sizeof(kAbrHostNew), kAbrHost, kAbrHost + sizeof(kAbrHostNew),
             memcmp(after, kAbrHostNew, sizeof(after)) == 0 ? "读回一致" : "读回不一致");
    }

    for (const AbrCodeSite &s : kAbrCodeSites) {
        const uintptr_t site = bias + s.off;
        const uint32_t cur = *reinterpret_cast<const volatile uint32_t *>(site);
        if (cur == s.want) {
            LOGI("%s: 已是目标值", s.what);
            continue;
        }
        if (!patch_text(site, &s.want, sizeof(s.want), s.what)) continue;
        const uint32_t after = *reinterpret_cast<const volatile uint32_t *>(site);
        LOGI("%s: 0x%08x -> 0x%08x (%s)", s.what, cur, after,
             after == s.want ? "读回一致" : "读回不一致");
    }
}

void apply_abr_patch() {
    LOGI("=== apply_abr_patch: begin ===");

    const uintptr_t bias = find_load_bias(kAbrSoname);
    if (bias == 0) {
        LOGE("本进程中找不到 %s", kAbrSoname);
        return;
    }
    LOGI("load bias = 0x%" PRIxPTR, bias);

    // 三张表都认得出来才认为「是本机这个构建」。kAbrIdxOff 处的语义依赖这一点，
    // 认不出来时绝不去动它。
    int recognised = 0;

    for (const AbrTable &t : kAbrTables) {
        const uintptr_t table = bias + t.off;

        uint32_t cur[6] = {0};
        memcpy(cur, reinterpret_cast<const void *>(table), sizeof(cur));
        if (memcmp(cur, t.old_val, sizeof(cur)) != 0) {
            if (memcmp(cur, t.new_val, sizeof(cur)) == 0) {
                LOGI("ABR 表 %s 已是目标值", t.label);
                recognised++;
                continue;
            }
            LOGE("ABR 表 %s 与本补丁的目标构建不一致 —— 跳过", t.label);
            LOGE("  期望 %u/%u/%u/%u/%u/%u", t.old_val[0], t.old_val[1], t.old_val[2],
                 t.old_val[3], t.old_val[4], t.old_val[5]);
            LOGE("  实际 %u/%u/%u/%u/%u/%u", cur[0], cur[1], cur[2], cur[3], cur[4], cur[5]);
            continue;
        }

        if (!patch_bytes(table, t.new_val, sizeof(t.new_val))) {
            LOGE("ABR 表 %s 写入失败", t.label);
            continue;
        }

        uint32_t after[6] = {0};
        memcpy(after, reinterpret_cast<const void *>(table), sizeof(after));
        const bool ok = memcmp(after, t.new_val, sizeof(after)) == 0;
        LOGI("ABR 表 %s %u/%u/%u/%u/%u/%u -> %u/%u/%u/%u/%u/%u (%s)", t.label,
             cur[0], cur[1], cur[2], cur[3], cur[4], cur[5],
             after[0], after[1], after[2], after[3], after[4], after[5],
             ok ? "读回一致" : "读回不一致");
        if (ok) recognised++;
    }

    if (recognised == static_cast<int>(sizeof(kAbrTables) / sizeof(kAbrTables[0]))) {
        g_abr_bias = bias;  // nudge_abr_index 由此开始生效
        LOGI("构建已确认，启用 ABR 索引退格");
        apply_abr_code_patches(bias);
    } else {
        LOGE("只认出 %d/%zu 张表 —— 不启用 ABR 索引退格", recognised,
             sizeof(kAbrTables) / sizeof(kAbrTables[0]));
    }

    LOGI("=== apply_abr_patch: done ===");
}

}  // namespace

class LhdcV5AdmissionModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        api_ = api;
        env_ = env;
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *args) override {
        if (args->nice_name == nullptr) return;

        const char *name = env_->GetStringUTFChars(args->nice_name, nullptr);
        if (name == nullptr) return;
        const bool target = strcmp(name, kTargetProcess) == 0;
        env_->ReleaseStringUTFChars(args->nice_name, name);
        if (!target) return;

        // libbluetooth_jni.so 此刻尚未映射（实测），只能挂到已映射的加载器上。
        g_armed = true;

        LOGI("postAppSpecialize：libbluetooth_jni.so 已映射？%s",
             find_load_bias(kSoname) != 0 ? "是" : "否");

        struct stat st{};
        if (stat(kRuntimeLibPath, &st) == 0) {
            api_->pltHookRegister(st.st_dev, st.st_ino, "OpenNativeLibrary",
                                  reinterpret_cast<void *>(&hooked_open_native_library),
                                  reinterpret_cast<void **>(&g_orig_open_native_library));
            LOGI("已注册 OpenNativeLibrary @ %s", kRuntimeLibPath);
        } else {
            LOGE("stat(%s) 失败 errno=%d", kRuntimeLibPath, errno);
        }

        struct stat nl{};
        if (stat(kNativeLoaderPath, &nl) == 0) {
            api_->pltHookRegister(nl.st_dev, nl.st_ino, "android_dlopen_ext",
                                  reinterpret_cast<void *>(&hooked_android_dlopen_ext),
                                  reinterpret_cast<void **>(&g_orig_android_dlopen_ext));
            LOGI("已注册 android_dlopen_ext @ %s", kNativeLoaderPath);
        } else {
            LOGE("stat(%s) 失败 errno=%d", kNativeLoaderPath, errno);
        }

        const bool committed = api_->pltHookCommit();
        LOGI("pltHookCommit -> %s", committed ? "true" : "false");

        // 刻意不调用 setOption(DLCLOSE_MODULE_LIBRARY)：
        // 模块代码被 GOT 槽引用，必须常驻。
    }

private:
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
};

REGISTER_ZYGISK_MODULE(LhdcV5AdmissionModule)
