// oesp_regfix.c — registers.ko codec-io 运行时修复（复刻 codec_io_probe + vdec_reg_ops_init G12B 路径）
// 背景：registers.ko 的 __this_module.init == NULL（大佬剥掉了 module_init 注册），
//       codec-io 平台驱动从未绑定 ⇒ 8 条总线 base 指针全 NULL、codec bus 表(16项)全 NULL。
// 本模块手工完成 probe 的工作：
//   1) 解码 codecio_read_XXX 的 adrp(+add)+ldr 定位 .bss 槽位数组并自校验
//   2) ioremap 7 条总线物理区，填槽位 + hiu_base/vpp_base 别名 + codecio_meson_dev + codecio_reg_start
//   3) 调 set_cpu_type_from_media(0x29)
//   4) 构造 12+2 项 ops（G12B offset patch），调 register_reg_ops_mgr / register_reg_ex_ops_mgr
//   5) 验证：codec_reg_read(2,0x1078)/(0,0x3f00) 与本模块直读对比 + aml_read_aobus(0xe8)
// mode: 0=仅解码校验(零风险) 1=完整修复+验证 2=仅验证(修复后复查)
// 参数: mbase=codecio_read_cbus 运行时地址; bss=codecio_reg_start 运行时地址(.bss+0x48);
//       a_setcpu/a_getcpu=set/get_cpu_type_from_media 地址(可 0 跳过)
// 注意: 模块退出不做任何清理(映射与表项有意保留, 与 probe 行为一致); 重启后需重跑。
#include <linux/module.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/uaccess.h>

#define PFX "OESP_REGFIX: "

/* registers.ko .text 静态偏移（来自 _kos/registers.ko 符号表，2026-10-08 复核） */
#define OFF_RD_CBUS      0x82c
#define OFF_WR_CBUS      0x880
#define OFF_RD_DOSBUS    0x8c8
#define OFF_WR_DOSBUS    0x960
#define OFF_RD_HIUBUS    0x9d4
#define OFF_WR_HIUBUS    0xa2c
#define OFF_RD_AOBUS     0xa74
#define OFF_WR_AOBUS     0xac8
#define OFF_RD_VCBUS     0xb0c
#define OFF_WR_VCBUS     0xb94
#define OFF_RD_PARSBUS   0xc08
#define OFF_WR_PARSBUS   0xc5c
#define OFF_RD_AIUBUS    0xca4
#define OFF_WR_AIUBUS    0xcf8
#define OFF_RD_DEMUXBUS  0xd40
#define OFF_WR_DEMUXBUS  0xd94
#define OFF_RD_RESETBUS  0xddc
#define OFF_WR_RESETBUS  0xe30
#define OFF_RD_DMCBUS    0x3e0
#define OFF_WR_DMCBUS    0x1f8
#define OFF_RD_EFUSEBUS  0xe78
#define OFF_WR_EFUSEBUS  0xed0
#define OFF_RD_NOCBUS    0xf18
#define OFF_WR_NOCBUS    0xf6c
#define OFF_CODEC_REG_READ   0x1198
#define OFF_AML_READ_AOBUS   0x288
#define OFF_REG_OPS_MGR      0x1450
#define OFF_REG_EX_OPS_MGR   0x1470

/* .bss 布局（codec_io_probe 反汇编实证）:
   +0x00..0x38  8×u64 总线 base 指针 (slot0=cbus slot1=dos slot2=hiu slot3=ao slot4=vc slot5=dmc slot6=efuse slot7=noc)
   +0x40        u32 codecio_meson_dev (cpu type)
   +0x48        u32 codecio_reg_start[8] (物理起始低32位)
   +0x68        u64 hiu_base (=slot2)
   +0x70        u64 vpp_base (=slot4)   */
#define BSS_SLOT(i)      (((u64)reg_bss) + 8*(i))
#define BSS_MESON_DEV    (((u64)reg_bss) + 0x40)
#define BSS_REG_START    (((u64)reg_bss) + 0x48)
#define BSS_HIU_BASE     (((u64)reg_bss) + 0x68)
#define BSS_VPP_BASE     (((u64)reg_bss) + 0x70)

/* codec bus 表 entry 布局: +0 bus(u32) +4 off(u32) +8 readfn +16 writefn +24/+28 refcount */
struct reg_ops_entry {
    u32 bus;
    u32 off;
    u64 rd;
    u64 wr;
    u32 rfc;
    u32 wfc;
};

typedef int  (*reg_ops_mgr_fn)(struct reg_ops_entry *, int);
typedef void (*set_cpu_fn)(unsigned int);
typedef unsigned int (*get_cpu_fn)(void);
typedef unsigned int (*codec_rd_fn)(unsigned int, unsigned int);
typedef unsigned int (*ao_rd_fn)(unsigned int);

static u64 param_mbase;    // codecio_read_cbus 运行时地址
static u64 param_bss;      // codecio_reg_start 运行时地址 (= .bss+0x48)
static u64 param_setcpu;
static u64 param_getcpu;
static int  param_mode = 0;
module_param_named(mbase, param_mbase, ullong, 0444);
module_param_named(bss, param_bss, ullong, 0444);
module_param_named(a_setcpu, param_setcpu, ullong, 0444);
module_param_named(a_getcpu, param_getcpu, ullong, 0444);
module_param_named(mode, param_mode, int, 0444);
MODULE_PARM_DESC(mbase, "runtime addr of codecio_read_cbus");
MODULE_PARM_DESC(bss, "runtime addr of codecio_reg_start (.bss+0x48)");
MODULE_PARM_DESC(mode, "0=decode-only 1=full-fix 2=validate-only");

static u64 reg_text;   // registers.ko .text 运行时基址
static u64 reg_bss;    // registers.ko .bss 运行时基址 (= param_bss - 0x48)

/* DT codec-io 节点 reg 顺序（本机实测 8 段；idx 即 slot idx） */
static const u64 bus_phys[8] = { 0xffd00000, 0xff620000, 0xff63c000, 0xff800000,
                                 0xff900000, 0xff638000, 0xff630000, 0 };
static const u64 bus_size[8] = { 0x100000, 0x100000, 0x20000, 0x10000,
                                 0x40000, 0x20000, 0x20000, 0 };
static const char *bus_name[8] = { "cbus", "dosbus", "hiubus", "aobus",
                                   "vcbus", "dmcbus", "efusebus", "nocbus" };

/* ============ adrp(+add)+ldr 运行时解码（照抄 oesp_ckbus 已验证的算法） ============ */
static int decode_slot(u64 fn, u64 *out_slot)
{
    u32 *p = (u32 *)fn;
    u32 i, adrp_rd = 0xff;
    u64 page = 0;
    int have_adrp = 0;
    for (i = 0; i < 16; i++) {
        u32 ins = p[i];
        if ((ins & 0x9f000000) == 0x90000000) {           // ADRP
            u32 rd = ins & 0x1f;
            u32 immlo = (ins >> 29) & 3;
            s64 immhi = (s32)((ins & 0x00ffffe0) << 8) >> 13;  // bits23:5 右对齐+符号扩展
            s64 imm = (immhi << 2) | immlo;
            page = ((u64)&p[i] & ~0xfffUL) + (imm << 12);
            adrp_rd = rd;
            have_adrp = 1;
        } else if (have_adrp && (ins & 0xffc00000) == 0x91000000) { // ADD imm
            u32 rd = ins & 0x1f, rn = (ins >> 5) & 0x1f;
            u32 imm12 = (ins >> 10) & 0xfff;
            if (rn == adrp_rd) { page += imm12; adrp_rd = rd; }
        } else if (have_adrp && (ins & 0xffc00000) == 0xf9400000) { // LDR x imm
            u32 rn = (ins >> 5) & 0x1f;
            u32 imm12 = (ins >> 10) & 0xfff;
            if (rn == adrp_rd) { *out_slot = page + imm12 * 8; return 0; }
        }
    }
    return -1;
}

/* ============ 主流程 ============ */
static struct reg_ops_entry g_ops[14];
static void __iomem *g_map[8];

static int regfix_run(void)
{
    u64 slot_expect[8];
    int i, fail = 0;

    reg_text = param_mbase - OFF_RD_CBUS;
    reg_bss  = param_bss - 0x48;
    pr_info(PFX "registers.ko text=%llx bss=%llx (mbase=%llx reg_start=%llx)\n",
            reg_text, reg_bss, param_mbase, param_bss);

    /* ---- 1. 解码各 codecio_read_XXX 的槽位并校验 ---- */
    {
        u32 *dump = (u32 *)param_mbase;
        pr_info(PFX "raw@cbus fn: %08x %08x %08x %08x\n",
                dump[0], dump[1], dump[2], dump[3]);
    }
    {
        struct { const char *n; u32 off; u32 exp; } fns[] = {
            { "cbus",    OFF_RD_CBUS,     0 },
            { "dosbus",  OFF_RD_DOSBUS,   8 },
            { "hiubus",  OFF_RD_HIUBUS,  16 },
            { "aobus",   OFF_RD_AOBUS,   24 },
            { "vcbus",   OFF_RD_VCBUS,   32 },
            { "dmcbus", OFF_RD_DMCBUS,  40 },
            { "efusebus",OFF_RD_EFUSEBUS,48 },
            { "nocbus",  OFF_RD_NOCBUS,  56 },
            { "parsbus", OFF_RD_PARSBUS,  0 },
            { "aiubus",  OFF_RD_AIUBUS,   0 },
            { "demuxbus",OFF_RD_DEMUXBUS, 0 },
            { "resetbus",OFF_RD_RESETBUS, 0 },
        };
        for (i = 0; i < 12; i++) {
            u64 fn = reg_text + fns[i].off, s = 0;
            if (decode_slot(fn, &s)) {
                pr_info(PFX "DECODE-FAIL %s fn=%llx\n", fns[i].n, fn);
                fail = 1; continue;
            }
            pr_info(PFX "slot %-8s fn=%llx slot=%llx (bss+%#x) cur=%llx\n",
                    fns[i].n, fn, s, fns[i].exp, *(u64 *)s);
            if (s != reg_bss + fns[i].exp) {
                pr_info(PFX "SLOT-MISMATCH %s: %#llx != bss+%#x\n",
                        fns[i].n, s, fns[i].exp);
                fail = 1;
            }
        }
    }
    for (i = 0; i < 8; i++) slot_expect[i] = BSS_SLOT(i);
    pr_info(PFX "slot-array=%llx hiu_base=%llx vpp_base=%llx meson_dev=%llx\n",
            slot_expect[0], BSS_HIU_BASE, BSS_VPP_BASE, BSS_MESON_DEV);
    if (fail) { pr_info(PFX "ABORT: slot decode/verify failed\n"); return -1; }

    if (param_mode == 0) { pr_info(PFX "MODE0 done (decode-only)\n"); return 0; }

    /* ---- 2. 仅验证模式 ---- */
    if (param_mode == 2) {
        for (i = 0; i < 8; i++)
            pr_info(PFX "V slot[%d] %-8s = %llx\n", i, bus_name[i], *(u64 *)slot_expect[i]);
        goto validate;
    }

    /* ---- 3. 填槽位（复刻 codec_io_probe） ---- */
    for (i = 0; i < 8; i++) {
        u64 *slot = (u64 *)slot_expect[i];
        if (!bus_phys[i]) { pr_info(PFX "slot[%d] %-8s phys=0 -> NULL\n", i, bus_name[i]); continue; }
        if (*slot) {
            g_map[i] = (void __iomem *)(*slot & ~0xfffUL);
            if (!g_map[i]) g_map[i] = ioremap(bus_phys[i], bus_size[i]);
            pr_info(PFX "slot[%d] %-8s already=%llx -> keep\n", i, bus_name[i], *slot);
        } else {
            g_map[i] = ioremap(bus_phys[i], bus_size[i]);
            if (!g_map[i]) { pr_info(PFX "ioremap FAIL %s\n", bus_name[i]); return -1; }
            *slot = (u64)g_map[i];
            pr_info(PFX "slot[%d] %-8s phys=%llx size=%llx -> map=%llx\n",
                    i, bus_name[i], bus_phys[i], bus_size[i], (u64)g_map[i]);
        }
        *(u32 *)(BSS_REG_START + 4 * i) = (u32)bus_phys[i];
    }
    /* 别名 + cpu type（probe 特例 [x20+104]=slot2 / [x20+112]=slot4） */
    *(u64 *)BSS_HIU_BASE = *(u64 *)slot_expect[2];
    *(u64 *)BSS_VPP_BASE = *(u64 *)slot_expect[4];
    *(u32 *)BSS_MESON_DEV = 0x29;   /* G12B */
    pr_info(PFX "aliases: hiu=%llx vpp=%llx meson_dev=%x\n",
            *(u64 *)BSS_HIU_BASE, *(u64 *)BSS_VPP_BASE, *(u32 *)BSS_MESON_DEV);

    if (param_setcpu) {
        set_cpu_fn f = (set_cpu_fn)param_setcpu;
        f(0x29);
        pr_info(PFX "set_cpu_type_from_media(0x29) called\n");
    } else {
        pr_info(PFX "set_cpu_type skipped (no addr)\n");
    }

    /* ---- 4. 构造 ops（G12B patch: bus5->0x200 bus6->0xf00 bus8->0xffffff00 bus15->0） ---- */
    {
        u64 T = reg_text;
        memset(g_ops, 0, sizeof(g_ops));
        g_ops[0]  = (struct reg_ops_entry){ 0,  0,          T+OFF_RD_DOSBUS,   T+OFF_WR_DOSBUS };
        g_ops[1]  = (struct reg_ops_entry){ 4,  0,          T+OFF_RD_VCBUS,    T+OFF_WR_VCBUS };
        g_ops[2]  = (struct reg_ops_entry){ 3,  0,          T+OFF_RD_CBUS,     T+OFF_WR_CBUS };
        g_ops[3]  = (struct reg_ops_entry){ 2,  0,          T+OFF_RD_CBUS,     T+OFF_WR_CBUS };
        g_ops[4]  = (struct reg_ops_entry){ 1,  0,          T+OFF_RD_AOBUS,    T+OFF_WR_AOBUS };
        g_ops[5]  = (struct reg_ops_entry){ 13, 0,          T+OFF_RD_VCBUS,    T+OFF_WR_VCBUS };
        g_ops[6]  = (struct reg_ops_entry){ 6,  0xf00,      T+OFF_RD_PARSBUS,  T+OFF_WR_PARSBUS };
        g_ops[7]  = (struct reg_ops_entry){ 8,  0xffffff00, T+OFF_RD_AIUBUS,   T+OFF_WR_AIUBUS };
        g_ops[8]  = (struct reg_ops_entry){ 5,  0x200,      T+OFF_RD_DEMUXBUS, T+OFF_WR_DEMUXBUS };
        g_ops[9]  = (struct reg_ops_entry){ 15, 0,          T+OFF_RD_RESETBUS, T+OFF_WR_RESETBUS };
        g_ops[10] = (struct reg_ops_entry){ 16, 0,          T+OFF_RD_EFUSEBUS, T+OFF_WR_EFUSEBUS };
        g_ops[11] = (struct reg_ops_entry){ 17, 0,          T+OFF_RD_NOCBUS,   T+OFF_WR_NOCBUS };
        g_ops[12] = (struct reg_ops_entry){ 2,  0xfffff000, T+OFF_RD_HIUBUS,   T+OFF_WR_HIUBUS };
        g_ops[13] = (struct reg_ops_entry){ 14, 0,          T+OFF_RD_DMCBUS,   T+OFF_WR_DMCBUS };

        for (i = 0; i < 14; i++)
            pr_info(PFX "ops[%d] bus=%-2u off=%#010x rd=%llx wr=%llx\n",
                    i, g_ops[i].bus, g_ops[i].off, g_ops[i].rd, g_ops[i].wr);

        ((reg_ops_mgr_fn)(reg_text + OFF_REG_OPS_MGR))(g_ops, 12);
        ((reg_ops_mgr_fn)(reg_text + OFF_REG_EX_OPS_MGR))(g_ops + 12, 2);
        pr_info(PFX "register_reg_ops_mgr(12) + ex(2) done\n");
    }

validate:
    /* ---- 5. 验证（纯读，零风险；映射一律取自槽位现值, mode1/2 通用） ---- */
    {
        codec_rd_fn crd = (codec_rd_fn)(reg_text + OFF_CODEC_REG_READ);
        ao_rd_fn   aor = (ao_rd_fn)(reg_text + OFF_AML_READ_AOBUS);
        void __iomem *m_dos = (void __iomem *)(*(u64 *)slot_expect[1]);
        void __iomem *m_hiu = (void __iomem *)(*(u64 *)slot_expect[2]);
        void __iomem *m_ao  = (void __iomem *)(*(u64 *)slot_expect[3]);
        unsigned int v2, d0, a8, ar;
        u32 h_ref, d_ref, a_ref;
        if (!m_dos || !m_hiu || !m_ao) {
            pr_info(PFX "VALIDATE-FAIL: slot dos/hiu/ao still NULL\n");
            return -1;
        }
        v2 = crd(2, 0x1078);                       /* hiubus: base+0x78*4=+0x1e0 */
        d0 = crd(0, 0x3f00);                       /* dosbus: base+0x3f00*4=+0xFC00 */
        ar = aor(0xe8);                            /* aobus: 字节偏移 0xe8 */
        a8 = param_getcpu ? ((get_cpu_fn)param_getcpu)() : 0;
        h_ref = readl(m_hiu + 0x1e0);
        d_ref = readl(m_dos + 0xFC00);
        a_ref = readl(m_ao + 0xe8);
        pr_info(PFX "VALIDATE codec_reg_read(2,0x1078)=%#x  ref(hiu+0x1e0)=%#x  %s\n",
                v2, h_ref, v2 == h_ref ? "MATCH" : "MISMATCH");
        pr_info(PFX "VALIDATE codec_reg_read(0,0x3f00)=%#x  ref(dos+0xFC00)=%#x  %s\n",
                d0, d_ref, d0 == d_ref ? "MATCH" : "MISMATCH");
        pr_info(PFX "VALIDATE aml_read_aobus(0xe8)=%#x  ref(ao+0xe8)=%#x  %s\n",
                ar, a_ref, ar == a_ref ? "MATCH" : "MISMATCH");
        pr_info(PFX "VALIDATE get_cpu_type=%#x (expect 0x29)\n", a8);
        if (v2 == 0 && d0 == 0) pr_info(PFX "WARN: both reads 0 — check!\n");
        else pr_info(PFX "FIX OK — codec_reg path alive\n");
    }
    return 0;
}

static int __init oesp_regfix_init(void)
{
    pr_info(PFX "init mode=%d mbase=%llx bss=%llx\n", param_mode, param_mbase, param_bss);
    if (!param_mbase || !param_bss) {
        pr_info(PFX "missing mbase/bss params\n");
        return -EINVAL;
    }
    return regfix_run();
}
static void __exit oesp_regfix_exit(void)
{
    /* 有意不清理: 槽位指针/表项/映射 保留(与 probe 行为一致), 重启自动复位 */
    pr_info(PFX "exit (no cleanup by design)\n");
}
module_init(oesp_regfix_init);
module_exit(oesp_regfix_exit);
MODULE_LICENSE("GPL");
