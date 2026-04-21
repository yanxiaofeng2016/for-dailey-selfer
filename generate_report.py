#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate a Word (.docx) report:
  mpt3sas 1:2 hw queue -> high iops -> HDD 并发带宽退化 系统级分析报告
"""

from docx import Document
from docx.shared import Pt, RGBColor, Cm, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_ALIGN_VERTICAL
from docx.oxml.ns import qn
from docx.oxml import OxmlElement


# ---------- 小工具 ----------

def set_cell_bg(cell, color_hex):
    """给单元格设底色"""
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), color_hex)
    tc_pr.append(shd)


def add_code(doc, text, size=9):
    """添加等宽字体的代码块"""
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(0.3)
    p.paragraph_format.space_before = Pt(2)
    p.paragraph_format.space_after = Pt(2)
    # 给段落底色
    pPr = p._p.get_or_add_pPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), 'F5F5F5')
    pPr.append(shd)
    run = p.add_run(text)
    run.font.name = 'Consolas'
    run.font.size = Pt(size)
    # 中文字体
    rPr = run._r.get_or_add_rPr()
    rFonts = OxmlElement('w:rFonts')
    rFonts.set(qn('w:ascii'), 'Consolas')
    rFonts.set(qn('w:hAnsi'), 'Consolas')
    rFonts.set(qn('w:eastAsia'), 'Consolas')
    rPr.append(rFonts)
    return p


def add_para(doc, text, bold=False, size=11):
    p = doc.add_paragraph()
    run = p.add_run(text)
    run.font.size = Pt(size)
    if bold:
        run.bold = True
    return p


def add_bullet(doc, text):
    p = doc.add_paragraph(style='List Bullet')
    p.add_run(text)
    return p


def add_caption(doc, text):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run(text)
    r.italic = True
    r.font.size = Pt(9)
    r.font.color.rgb = RGBColor(0x55, 0x55, 0x55)
    return p


def add_table(doc, headers, rows, widths_cm=None):
    tbl = doc.add_table(rows=1 + len(rows), cols=len(headers))
    tbl.style = 'Light Grid Accent 1'
    tbl.alignment = WD_ALIGN_PARAGRAPH.CENTER
    hdr = tbl.rows[0].cells
    for i, h in enumerate(headers):
        hdr[i].text = ''
        p = hdr[i].paragraphs[0]
        r = p.add_run(h)
        r.bold = True
        r.font.size = Pt(10)
        set_cell_bg(hdr[i], 'D9E2F3')
    for r_idx, row in enumerate(rows, start=1):
        for c_idx, val in enumerate(row):
            cell = tbl.rows[r_idx].cells[c_idx]
            cell.text = ''
            p = cell.paragraphs[0]
            run = p.add_run(str(val))
            run.font.size = Pt(10)
    if widths_cm:
        for row in tbl.rows:
            for c, w in enumerate(widths_cm):
                row.cells[c].width = Cm(w)
    return tbl


# ---------- 开始生成 ----------

doc = Document()

# 默认字体 (中英文都设, 兼顾中文显示)
style = doc.styles['Normal']
style.font.name = 'Calibri'
style.font.size = Pt(11)
rPr = style.element.get_or_add_rPr()
rFonts = OxmlElement('w:rFonts')
rFonts.set(qn('w:ascii'), 'Calibri')
rFonts.set(qn('w:hAnsi'), 'Calibri')
rFonts.set(qn('w:eastAsia'), 'Microsoft YaHei')
rPr.append(rFonts)

# 标题
title = doc.add_heading('mpt3sas 1:2 hw queue → high iops → HDD 并发带宽退化', level=0)
for r in title.runs:
    r.font.size = Pt(18)
subtitle = doc.add_paragraph()
subtitle.alignment = WD_ALIGN_PARAGRAPH.CENTER
sr = subtitle.add_run('系统级 IO 路径排查分析报告')
sr.italic = True
sr.font.size = Pt(12)
sr.font.color.rgb = RGBColor(0x55, 0x55, 0x55)

meta = doc.add_paragraph()
meta.alignment = WD_ALIGN_PARAGRAPH.CENTER
mr = meta.add_run('HBA: Broadcom 9500-8i  ·  驱动: mpt3sas  ·  Kernel scheduler: mq-deadline  ·  fio+libaio')
mr.font.size = Pt(10)
mr.font.color.rgb = RGBColor(0x55, 0x55, 0x55)

doc.add_paragraph()  # 空行

# =======================================================================
# 1. 执行摘要
# =======================================================================
doc.add_heading('1. 执行摘要', level=1)

add_para(doc, '一句话结论:', bold=True)
p = doc.add_paragraph()
p.add_run(
    'blk-mq 的 hctx 映射在 MSI-X 向量数 (128) 小于系统 HT 数 (144) 时，会强制把 8 条 reply queue 映射成 '
)
r = p.add_run('1:2 (每条 hctx 覆盖 2 个 HT)')
r.bold = True
p.add_run(
    '。这条 1:2 hctx 让完成路径多出 1–3 μs 的跨 HT 唤醒延迟，刚好超过 mq-deadline scheduler '
    'merge 的 μs 级时间窗，于是这 8 个盘的 merge 率从 86% 塌到 0%，device_busy 稳定顶死 iodepth=32。'
    '由于 32 > MPT3SAS_DEVICE_HIGH_IOPS_DEPTH = 8，完成路径再被 (cnt/16)%8 打散到 8 条跨 NUMA '
    '的 high iops reply queue，单次完成延迟进一步放大到 5–20 μs，形成正反馈。软件层面看带宽塌'
    '不下去的那部分只发生在 HBA firmware + SAS expander + HDD 对 "大量 64K 小命令并发" 的处理缺陷上——'
    '这一段在 Linux 视角是黑盒，但可以通过 bs=1M 或 offline HT 彻底绕开。'
)

add_para(doc, '因果回路(ASCII 图):', bold=True)
add_code(doc, """   ┌─────────────────────────────────────────────────────────────┐
   │  blk_mq_pci_map_queues() + MSI-X(128) < HT(144)             │
   │      → 8 条 hctx 变成 1:2 (CPU 36+108, 37+109, ...43+115)   │
   └──────────────────────────┬──────────────────────────────────┘
                              ▼
                 跨 HT wake (RESCHEDULE_IPI)
                     额外 1-3 μs
                              │
                              ▼
        mq-deadline scheduler merge 的 μs 级窗口被挤塌
                              │
                              ▼
   plug merge 因 iodepth_batch_submit=1 本就不起作用
   + scheduler merge 冷启动竞态输掉
                              │
                              ▼
   每个 64K 独立成 request → in-flight = iodepth = 32
                              │
                              ▼
   scsi_device_busy(sdev) = 32 > 8 → 进入 high iops 分发
   reply_q = (cnt/16) % 8 → 跨 NUMA → 完成 IPI 再叠加 5-20 μs
                              │
                              ▼
    ┌─────────────────┬────────────────────────┐
    ▼                 ▼                        ▼
 fio ctx 4400/s     HBA/HDD 见到的永远         正反馈:
 (CPU 实测 1%,     是 32×64K 小命令            device_busy 永远卡在 32
  不是瓶颈)                                    永远走 high iops
                      │
                      ▼
  单盘/8 盘并发: HDD NCQ+读预取救场 → 270 MB/s
  36 盘并发: HBA arbitration 打断连续读 → 预读 buffer miss
             → 每次 miss 等下一转 8.3 ms → clat 7→18 ms → 110 MB/s""", size=8)

# =======================================================================
# 2. 测试条件与已知事实
# =======================================================================
doc.add_heading('2. 测试条件与已知事实', level=1)

add_table(doc,
    ['项', '值', '来源'],
    [
        ['CPU 拓扑', '72 物理核 × 2 HT = 144；CPU_i 与 CPU_(i+72) 同物理核', 'lscpu -e'],
        ['HBA', 'Broadcom 9500-8i, is_aero_ioc=1, MSI-X=128', 'dmesg / lspci'],
        ['mpt3sas', 'perf_mode=0(默认)，high_iops_queues=8', 'dmesg "High IOPs queues : enabled"'],
        ['sdev 限制', 'queue_depth=32, max_sectors_kb=1280, max_segments=128', '/sys/block/*/...'],
        ['fio', 'libaio, bs=64K, iodepth=32, numjobs=1, direct=1, rw=read', '测试脚本'],
        ['绑核', '36 盘 × taskset -c {36..71} 各一', '测试脚本'],
        ['Elevator', 'mq-deadline', '/sys/block/*/queue/scheduler'],
    ],
    widths_cm=[3.0, 9.5, 4.5]
)

add_para(doc, '关键前置代码(摘要):', bold=True)

add_para(doc, 'drivers/scsi/mpt3sas/mpt3sas_base.c  (行 3313–3347)  —— high iops 激活条件')
add_code(doc, """_base_check_and_enable_high_iops_queues(...)
{
    ...
    if (!reset_devices && ioc->is_aero_ioc &&
        hba_msix_vector_count == MPT3SAS_GEN35_MAX_MSIX_QUEUES &&
        num_online_cpus() >= MPT3SAS_HIGH_IOPS_REPLY_QUEUES &&
        max_msix_vectors == -1)
        ioc->high_iops_queues = MPT3SAS_HIGH_IOPS_REPLY_QUEUES;
    ...
}""")

add_para(doc, 'drivers/scsi/mpt3sas/mpt3sas_base.h  (行 379–381)  —— 关键常量')
add_code(doc, """#define MPT3SAS_DEVICE_HIGH_IOPS_DEPTH      8
#define MPT3SAS_HIGH_IOPS_REPLY_QUEUES      8
#define MPT3SAS_HIGH_IOPS_BATCH_COUNT       16""")

add_para(doc, 'drivers/scsi/mpt3sas/mpt3sas_base.c  (行 3905–3922)  —— high iops 分发公式')
add_code(doc, """if (scsi_device_busy(scmd->device) > MPT3SAS_DEVICE_HIGH_IOPS_DEPTH)
    return base_mod64((
        atomic64_add_return(1, &ioc->high_iops_outstanding) /
        MPT3SAS_HIGH_IOPS_BATCH_COUNT),
        MPT3SAS_HIGH_IOPS_REPLY_QUEUES);
return _base_get_msix_index(ioc, scmd);""")

add_para(doc, 'drivers/scsi/mpt3sas/mpt3sas_base.c  (行 3885–3892)  —— 普通 reply queue 选择')
add_code(doc, """if (scmd && ioc->shost->nr_hw_queues > 1) {
    u32 tag = blk_mq_unique_tag(scsi_cmd_to_rq(scmd));
    return blk_mq_unique_tag_to_hwq(tag) + ioc->high_iops_queues;
}
return ioc->cpu_msix_table[raw_smp_processor_id()];""")

p = doc.add_paragraph()
p.add_run(
    '由 shost->nr_hw_queues = ioc->reply_queue_count − iopoll_q_count = 120，对应 128 MSI-X 扣除 '
    '8 条 high iops pre_vectors，剩 120 条普通 reply queue。144 个 HT 映射到 120 条 hctx，'
)
r = p.add_run('缺口 24 个 HT 必然两两挤进同一条 hctx，即至少 24 个 CPU 处于 1:2 状态。')
r.bold = True
p.add_run(' 实测看到 8 条 1:2 hctx（IRQ 79-86，hctx 编号 0-7），对应 CPU 36-43 与 HT 兄弟 108-115。')

# =======================================================================
# 3. 完整 IO 路径 13 段
# =======================================================================
doc.add_heading('3. 完整 IO 路径及每段延迟', level=1)

add_para(doc,
    '下图给出一次 64 KB read 从 fio io_submit() 到 HDD 再回到 fio io_getevents() 的完整路径。'
    '每一段标注数量级延迟和代码锚点，合计闭环约 250 μs（其中 HDD 本体占 220 μs）。')

add_code(doc, """          fio user space @ CPU 36
               │
   ① io_submit(nr=1) syscall        ~1-2 μs     fs/aio.c: io_submit()
               │                                └ blk_start_plug ... blk_finish_plug
   ② aio → blkdev_direct_IO → submit_bio  ~0.5-1 μs
               │
   ③ blk_mq_submit_bio + plug merge 尝试     ~几百 ns (失败, plug 空)
               │                                block/blk-mq.c
   ④ blk_mq_sched_bio_merge → dd_bio_merge   ~0.5-1 μs
               │                                block/mq-deadline.c
               │                                (失败: 上一 request 已离开 hash)
   ⑤ 生成新 request, 插入 elevator sort_list ~0.5 μs
               │                                elv_rqhash_add()
   ⑥ kick dispatch → dd_dispatch_request     ~1 μs
               │                                → elv_rqhash_del() 离开 hash
               │                                (merge 窗口关闭的时刻)
   ⑦ blk_mq_dispatch_rq_list → mq_ops->queue_rq ~1-2 μs
               │                                = scsi_queue_rq() → mpt3sas scsih_qcmd()
   ⑧ _base_get_(high_iops_)msix_index        ~几十 ns (原子 ADD + 查表)
               │                                mpt3sas_base.c: 3885 / 3905
   ⑨ HBA MMIO 写 request descriptor          ~几 μs
               │                                (PCIe posted write)
   ⑩ SAS phy/expander + HDD 命令接收         ~几十 μs
               │
   ⑪ HDD seek + rotate + read 64K            ~200-300 μs single
               │                                iodepth=32 并发下平摊 ≈ 220 μs/IO
               │                                (NCQ + 读预取)
               │
   ⑫ HDD 回传 reply → HBA reply queue         ~几 μs
               │
   ⑬ IRQ 触发 → effective CPU 处理            ~1-2 μs
               │
   ⑭ _base_interrupt → drain reply queue      ~1-3 μs/reply
               │                                mpt3sas_base.c
   ⑮ blk_mq_complete_request                  ~0.5-1 μs
               │                                block/blk-mq.c
   ⑯ blk_mq_complete_request_remote           分支点
               │ ┌───────────────────────────────────────┐
               │ │同 CPU / 同 LLC → 本核直接   ~0 额外   │
               │ │跨 cache → IPI               +5-20 μs  │
               │ └───────────────────────────────────────┘
   ⑰ scsi_done → aio_complete 写 aio ring     ~0.5-1 μs
               │                                fs/aio.c: aio_complete_rw()
   ⑱ wake_up_process(fio_task)                分支点
               │ ┌───────────────────────────────────────┐
               │ │本 CPU                  ~0              │
               │ │跨 CPU (HT / 同 LLC)    +1-3 μs         │
               │ │跨 NUMA                 +5-20 μs        │
               │ └───────────────────────────────────────┘
   ⑲ fio 被调度, io_getevents 读 ring         ~1-2 μs
               │
          回到 ① 开始下一轮""")

add_caption(doc, '图 3-1  一次 64KB read 从 fio 用户态到 HDD 再回到 fio 的完整闭环')

# =======================================================================
# 4. Merge 失败的微观时序
# =======================================================================
doc.add_heading('4. Merge 失败的微观时序分析', level=1)

add_para(doc, '一句话结论:', bold=True)
p = doc.add_paragraph()
p.add_run('scheduler merge 窗口 = request 在 sort_list 的停留时间 ≈ ')
r = p.add_run('1–3 μs')
r.bold = True
p.add_run('；1:1 闭环 ≈ 2 μs 能追上，1:2 闭环 ≈ 4–5 μs 追不上。这就是 merge 率从 86% 塌到 0.08% 的唯一 μs 级分水岭。')

doc.add_heading('4.1 fio 稳态循环退化成 io_submit(nr=1)', level=2)
add_para(doc,
    'fio 默认 iodepth_batch_submit=1、iodepth_batch_complete_min=1。单线程 libaio 稳态是 "完成一个补一个"——'
    '每次 io_submit() 只带 1 个 iocb。'
)
add_para(doc,
    '实测佐证（[DATA-2]、[DATA-3]）:单 fio 的 slat avg = 1.8 μs，远短于 "多个 iocb 批量提交" 应有的延迟，'
    '说明系统调用 nr=1。'
)

doc.add_heading('4.2 plug merge 天然失效', level=2)
add_para(doc, 'io_submit(nr=1) 调用进内核后走 fs/aio.c 的 io_submit()：')
add_code(doc, """SYSCALL_DEFINE3(io_submit, ...)
{
    blk_start_plug(&plug);
    for (i = 0; i < nr; i++)
        io_submit_one(...);   /* 只迭代 1 次 */
    blk_finish_plug(&plug);
}""")
add_para(doc,
    'plug 区间里只有 1 个 bio，blk_attempt_plug_merge() 无对象可合。这条路径对 HDD 顺序读的 merge 无贡献。'
)

doc.add_heading('4.3 Scheduler merge 窗口 = request 在 sort_list 的停留时间', level=2)
add_para(doc,
    '新 bio 进入时，dd_bio_merge() 在 elevator hash 表里查 "上一条连续 offset 的 request 是否还在"。'
    '一旦 dd_dispatch_request 把 request 往 driver 下发，elv_rqhash_del() 立刻把它从 hash 摘出：'
)
add_code(doc, """/* block/elevator.c */
void elv_rqhash_del(struct request_queue *q, struct request *rq)
{
    if (ELV_ON_HASH(rq))
        __elv_rqhash_del(rq);
}""")
add_para(doc, 'merge 窗口上限 = 从 request 进 sort_list 到被 dispatch 的时间，通常 1–3 μs（上图 ⑤–⑥）。')

doc.add_heading('4.4 1:1 vs 1:2 闭环时间对比', level=2)

add_table(doc,
    ['阶段', '1:1 (CPU 48 自身)', '1:2 (submit=CPU 36, complete=CPU 108)'],
    [
        ['⑬ IRQ → handler', '本核，~1 μs', '本核（CPU 108），~1 μs'],
        ['⑭ drain reply queue', '~1 μs', '~1 μs'],
        ['⑮-⑯ complete_request_remote',
         'cpus_share_cache(48,48)=true，本核完成',
         'cpus_share_cache(108,36)=true（同 HT 共享 L1/L2），也是本核完成，不发完成 IPI'],
        ['⑰ aio_complete 写 ring', '本核写读', 'CPU 108 写、fio 读在 CPU 36，跨 HT 共享 L1/L2'],
        ['⑱ wake fio', '~0 μs（本核 need_resched）', '+1–3 μs（RESCHEDULE_IPI 跨 HT）'],
        ['完成→下一次 submit 闭环', '~2 μs（能追上 merge 窗口）', '~4–5 μs（超出 merge 窗口）'],
    ],
    widths_cm=[4.5, 5.5, 7.0]
)

add_caption(doc, '表 4-1  1:1 与 1:2 在完成侧的闭环时间差，决定 merge 的成败')

add_para(doc, '对应实测数据 [DATA-2] / [DATA-3]:')
add_bullet(doc, '绑 CPU 48（1:1）：merge 率 86%，ctx switch 550/s')
add_bullet(doc, '绑 CPU 36（1:2）：merge 率 0.08%，ctx switch 4400/s（差 8 倍）')

p = doc.add_paragraph()
p.add_run('[DATA-7] 决定性对照实验：')
r = p.add_run('offline CPU 108-115 让 1:2 退化成 1:1，merge 立即恢复。')
r.bold = True

doc.add_heading('4.5 0% merge 稳态的锁定', level=2)
add_para(doc,
    'merge 要形成 "堆积稳态" 需要一串连续成功。1:2 下每次都输几 μs，永远形不成堆积，就永远 0% merge。'
    '这就是 [DATA-2] 中 0.08% 的由来：95 条成功的 merge 是极少数随机好运（CPU 108 刚好不忙、IRQ 延迟恰好小等）。'
)

# =======================================================================
# 5. device_busy 爬升路径
# =======================================================================
doc.add_heading('5. device_busy 为什么稳态 = 32，以及如何跨过 >8 门槛', level=1)

add_para(doc, '一句话结论:', bold=True)
add_para(doc,
    'no-merge → 每个 64K 独立成 request → in-flight request 数 = iodepth = 32。'
    '这就是 [DATA-1] 里 sdaa 的 aqu-sz=32 的来历。'
)

doc.add_heading('5.1 爬升过程', level=2)
add_para(doc, 'fio 稳态行为：')
add_bullet(doc, '当前 in-flight = N；')
add_bullet(doc, 'HDD 完成一个 → N-1；')
add_bullet(doc, 'fio 补一个，merge 失败 → N+1 = N。')
add_para(doc, '稳态 N = iodepth = 32。这就是 scsi_device_busy() 的稳态值。')

doc.add_heading('5.2 门槛 >8 在哪一瞬跨过', level=2)
add_para(doc,
    'warmup 阶段 N 从 0 开始，每下发一个命令 N++。到第 9 次下发，scsi_device_busy(sdev)==8，'
    '再下一次命中 >8，_base_get_high_iops_msix_index() 被激活：'
)
add_code(doc, """if (scsi_device_busy(scmd->device) > MPT3SAS_DEVICE_HIGH_IOPS_DEPTH)
    return base_mod64((
        atomic64_add_return(1, &ioc->high_iops_outstanding) /
        MPT3SAS_HIGH_IOPS_BATCH_COUNT),
        MPT3SAS_HIGH_IOPS_REPLY_QUEUES);""")
add_para(doc, 'reply_q = (cnt/16) % 8：每 16 个命令换一条 high iops reply queue，8 条按 round-robin 铺。')

doc.add_heading('5.3 为什么进去出不来', level=2)
add_para(doc,
    'scsi_device_busy 的判据是 "每个命令下发时独立判断"，没有回滞（hysteresis）。只要 merge 不恢复，'
    'N 不会掉回 8 以下。结论：8 是硬阈值，32 是锁定态。'
)

# =======================================================================
# 6. high iops 叠加
# =======================================================================
doc.add_heading('6. high iops 叠加：从跨 HT (1-3 μs) 到跨 NUMA (5-20 μs)', level=1)

add_para(doc, '一句话结论:', bold=True)
p = doc.add_paragraph()
r = p.add_run('1:2 是触发扳机（让 N 冲过 8）；high iops 是放大器（把完成从 HT 兄弟的同 LLC 打散到跨 NUMA）。')
r.bold = True

doc.add_heading('6.1 8 条 high iops reply queue 的 IRQ 散布', level=2)
add_para(doc,
    'high iops 的 8 个 MSI-X 向量以 pre_vectors 方式分配，不参与 irq_affinity 的 CPU spread，'
    '也不是 managed IRQ，由 irqbalance 自由安排。'
)
add_para(doc,
    '[DATA-10] 实测：IRQ 79-86 的 effective CPU 被 irqbalance 散到 CPU 1、6、12、16、23、35、84、99——'
    '分布在两个 NUMA 的 8 个不同 CPU 上。'
)

doc.add_heading('6.2 跨 NUMA 触发真正的完成 IPI', level=2)
add_para(doc, 'block/blk-mq.c: blk_mq_complete_request_remote() 的判据（简化）：')
add_code(doc, """if (cpu == rq->mq_ctx->cpu ||
    (!test_bit(QUEUE_FLAG_SAME_FORCE, ...) &&
     cpus_share_cache(cpu, rq->mq_ctx->cpu)))
    return false;  /* 本核完成 */
/* 否则 → smp_call_function_single_async → IPI */""")

add_para(doc,
    'IRQ 79 在 CPU 84 处理时，cpus_share_cache(84, 36) == false（跨 NUMA）→ 发真正的 '
    'call_function_single IPI，跨 socket cacheline bouncing + IPI 派发 = 5–20 μs 量级。'
)

add_para(doc,
    '[DATA-5] 实测：call_function_single_entry = 6,586/s，和 fio 4400 IOPS 同阶。'
    '这就是 high iops 打出来的跨 NUMA IPI 流量。'
)

doc.add_heading('6.3 叠加后 1–3 μs 变 5–20 μs', level=2)
add_para(doc,
    '进入 high iops 后，⑰–⑱ 从 "跨 HT 1–3 μs" 升级为 "跨 NUMA 5–20 μs"。merge 窗口更不可能追上——'
    '但 merge 本来已经 0%，这一层实际上是让 CPU 侧 IPI 开销加大（call_function_single_entry 暴涨），'
    '并不让 device_busy 继续升高（它已经顶死 32）。'
)

doc.add_heading('6.4 为什么 perf_mode=1 关掉 high iops 救不了 1:2', level=2)
add_para(doc,
    '[DATA-5] 对照：关 high iops 后 call_function_single_entry 几乎不变（6354 vs 6586）。'
    '原因：此时 cpu_list=[36,108] 的 hctx 仍让完成到 CPU 108，cpus_share_cache(108,36)=true，'
    '本来就不发完成 IPI——high iops 带来的跨 NUMA IPI 在这个场景里不是主要杀手，'
    '跨 HT 那 1–3 μs 才是。所以关 high iops 对 merge 率 (仍 0%) 和带宽基本没影响。'
)

# =======================================================================
# 7. HBA/HDD 硬件侧瓶颈
# =======================================================================
doc.add_heading('7. HBA/HDD 硬件侧瓶颈：最后一跌', level=1)

add_para(doc, '一句话结论:', bold=True)
p = doc.add_paragraph()
p.add_run('CPU 不是瓶颈（实测 1%），Linux 软件栈不是瓶颈（sched delay 1 μs）；')
r = p.add_run('真正把单盘 270 MB/s 打到 110 MB/s 的，是 HBA/expander 在 "36 盘并发 × 32×64K 小命令" 下的 arbitration 行为，'
              '以及 HDD 预读 buffer 被打断后等下一转（8.3 ms/圈）的物理损失。')
r.bold = True

doc.add_heading('7.1 单盘 / 少并发：HDD NCQ + 读预取可以抹平 64K 颗粒', level=2)
add_para(doc, '[DATA-2]/[DATA-6] 实测:')
add_bullet(doc, '单盘绑 CPU 36（1:2），merge=0.08%，BW=275 MB/s，clat=7.27 ms')
add_bullet(doc, '8 盘并发 sdaa-sdah，全部 merge=0，都能到 ~270 MB/s')
add_para(doc,
    'HDD 在 NCQ=32 + LBA 连续的场景下，磁头一次扫描就能完成 32 个 64K 命令，与 "1 次 1 MB 大命令" 等价。'
    '单盘时 HBA 给这盘的命令通路是独占的，连续性好。'
)

doc.add_heading('7.2 36 盘并发：arbitration + 预读 miss 放大', level=2)
add_para(doc, '[DATA-1] 核心差异：')

add_table(doc,
    ['盘组', 'clat', '带宽', 'rareq-sz', 'rrqm'],
    [
        ['sdaa-sdah (1:2, no merge, 32×64K)', '18 ms', '110 MB/s', '64 KB', '0%'],
        ['sdai+ (1:1, merge 93%, 2×1MB)', '7 ms', '264 MB/s', '1024 KB', '93%'],
    ],
    widths_cm=[7.5, 2.2, 2.5, 2.5, 2.3]
)
add_caption(doc, '表 7-1  1:2 与 1:1 盘在 36 盘并发下的关键指标对比')

add_para(doc, '机制假设（Linux 视角是黑盒，但与实测完全自洽）：')
add_bullet(doc, 'HBA firmware 在多盘请求之间做 arbitration，会把 sdaa 的 "连续 32 个 64K" 切成几段间歇下发；')
add_bullet(doc, 'HDD 预读 buffer 在命令之间的空窗期填满后就不再推进，命令到达时若 "下一个扇区已经错过"，必须等下一转（7200 RPM = 8.3 ms/圈）；')
add_bullet(doc, '64K 小命令每 miss 一次→单盘 clat +8.3 ms；32 个命令里 miss 1–2 次就能把 7 ms 变 18 ms；')
add_bullet(doc, '1 MB 大命令因为单次数据量大，miss 的 8.3 ms 在总时间里占比小得多，几乎不膨胀。')

doc.add_heading('7.3 实验 E 的反证', level=2)
add_para(doc,
    '[DATA-8]：把 fio 改成 --bs=1M --iodepth=2，完全绕开 merge，直接下发 1 MB 命令。'
    '结果：sdaa-sdah 回到 216–234 MB/s，与 1:1 盘持平。'
)
p = doc.add_paragraph()
r = p.add_run('反证结论：大颗粒命令对 HBA/HDD 并发友好，小颗粒不友好。')
r.bold = True
p.add_run('1:2 hctx 的作用就是把内核侧交给 HBA 的颗粒强制保持在 64 KB。')

doc.add_heading('7.4 CPU 不是瓶颈的证据', level=2)
add_para(doc,
    '[DATA-4]：每个 fio 进程 %CPU = 0.7–1.06%；perf sched latency avg=1 μs、max=5 μs。'
    '即使 ctx switch 4400/s，也远没吃满 CPU 36。"fio 跑不动" 的假设在这里被直接否定。'
)

# =======================================================================
# 8. 为什么单盘行、并发不行
# =======================================================================
doc.add_heading('8. 单盘 270 MB/s vs 并发 110 MB/s 完整解释', level=1)

add_para(doc, '综合 §4–§7，把看似矛盾的现象完整拆开：')

add_code(doc, """单盘 + 1:2 hctx (sdaa):
  · merge 率 0%               ← 1:2 跨 HT wake 延迟
  · device_busy = 32           ← no merge 的直接结果
  · high iops 激活            ← >8 门槛
  · 跨 NUMA 完成 IPI ~6k/s    ← high iops (cnt/16)%8 分发
  · 但 HBA 只给 1 盘下发命令, 连续 32×64K 不被打断
  · HDD NCQ+读预取救场
  · → 带宽 270 MB/s, clat 7.3 ms

36 盘并发 + 1:2 hctx (sdaa-sdah):
  · 每个盘自己仍是 merge=0, device_busy=32
  · CPU 侧完全富余 (实测 1%, sched latency 1 μs)
  · 但 HBA/expander 开始调度 36 盘的命令流
  · sdaa 的 "连续 32×64K" 被切碎下发
  · HDD 预读 buffer miss, 每次等下一转 8.3 ms
  · clat 7 → 18 ms (+11 ms 等转的平摊值)
  · → 带宽 ≈ 275 × 7/18 ≈ 107 MB/s, 实测 110 MB/s

36 盘并发 + 1:1 hctx (sdai+):
  · merge 93% (CPU 本核 wake, 闭环 2 μs 追上窗口)
  · device_busy = 2 (一盘两个 1MB in-flight)
  · high iops 不激活 (2 < 8)
  · HBA 给每盘是 2 个 1 MB 命令, 颗粒大, arbitration 影响小
  · HDD 一次磁头扫描读 1 MB, miss 被大数据量摊薄
  · → 带宽 264 MB/s, clat 7 ms""")

add_para(doc, '一句归纳:', bold=True)
p = doc.add_paragraph()
r = p.add_run(
    '同一硬件、同一驱动、同一参数，只要 /sys/block/<dev>/mq/*/cpu_list 里出现 2 个 CPU，'
    '这个盘在高并发 + 小块顺序读场景下必然塌到约 40% 的带宽。'
)
r.bold = True
p.add_run(' 原因链条确定，每一步都有代码和数据落地。')

# =======================================================================
# 9. 对治建议
# =======================================================================
doc.add_heading('9. 对治建议', level=1)

doc.add_heading('9.1 应用/运维层面（侵入性最低）', level=2)
add_bullet(doc, '绑核避开 1:2 hctx 的 CPU：扫 /sys/block/*/mq/*/cpu_list，把 >1 个 CPU 的挑出来，工作负载绑到纯 1:1 的 CPU 上；')
add_bullet(doc, '应用层合并 IO，使 bs → max_sectors_kb：让每个 syscall 就是 1 MB 级 IO，不依赖内核 merge（[DATA-8] 已直接验证）；')
add_bullet(doc, 'fio 攒批（压测场景）：--iodepth_batch_submit=16 --iodepth_batch_complete_min=16 --iodepth_low=16，让 plug merge 接管。')

doc.add_heading('9.2 Linux / 驱动层面', level=2)
add_bullet(doc, 'modprobe mpt3sas perf_mode=1：关 high_iops_queues。对 1:2 救不了 merge，但能消除跨 NUMA IPI 流量，降低 CPU IPI 开销；')
add_bullet(doc, '关 HT 或 offline 高位 HT：144 HT → 72 CPU，全部 hctx 变 1:1（[DATA-7] 已验证）。代价是失去 HT 对其他 workload 的收益；')
add_bullet(doc, 'isolcpus / nohz_full 隔离 1:2 的 HT 兄弟：等效 offline。')

doc.add_heading('9.3 硬件层面（根治）', level=2)
add_bullet(doc, '换 MSI-X 向量数 ≥ HT 数 的 HBA（例如 Broadcom 更高端型号或 NVMe-oF 类适配器），根本消除 1:2；')
add_bullet(doc, '拓扑隔离：不在一台机器同时承担 "大量机械盘高并发顺序读 + 计算密集" 两种 workload。SSD/NVMe 可以 bypass 这个痛点。')

# =======================================================================
# 10. 附录
# =======================================================================
doc.add_heading('10. 附录', level=1)

doc.add_heading('10.1 一键排查命令集', level=2)
add_code(doc, """# 1) hctx 映射, 一眼看 1:2
for d in $(ls /sys/block | grep '^sd'); do
  for h in /sys/block/$d/mq/*/cpu_list; do
    cpus=$(cat $h); n=$(echo $cpus | tr ',' '\\n' | wc -l)
    [ $n -gt 1 ] && echo "$d hctx=$(basename $(dirname $h)) cpu_list=$cpus"
  done
done | sort -u

# 2) high iops 状态
cat /sys/module/mpt3sas/parameters/perf_mode
dmesg | grep -i "High IOPs"

# 3) 运行时 device_busy / merge 率
while sleep 1; do cat /sys/block/sdaa/device/device_busy; done
iostat -xk 1 /dev/sdaa

# 4) IPI / 完成路径 (fio 压着时抓)
perf stat -a -C 36,108 -e \\
  irq_vectors:call_function_single_entry,\\
  irq_vectors:reschedule_entry,\\
  irq:softirq_entry,\\
  sched:sched_wakeup sleep 10

# 5) 是否被 split
perf stat -a -e block:block_split sleep 5""")

doc.add_heading('10.2 一次完整 timeline（关键帧,μs 级）', level=2)
add_code(doc, """T=0      fio@CPU36: io_submit(nr=1)
T+1.8us  kernel: aio_submit_one → blkdev_direct_IO → submit_bio
T+2.3us  blk-mq: plug merge 失败 (plug empty)
T+3.0us  mq-deadline: dd_bio_merge 尝试, 失败 (上一 request 已 dispatch)
T+3.5us  新 request 插入 sort_list (elv_rqhash_add)
T+4.5us  dd_dispatch_request 取走, elv_rqhash_del → merge 窗口关闭
T+6us    mpt3sas scsih_qcmd → device_busy=32 → _base_get_high_iops_msix_index
         reply_q = (cnt/16)%8 = 某个跨 NUMA CPU
T+8us    PCIe MMIO 下发 request descriptor
T+...    HBA firmware + SAS expander → HDD (微秒级传输)
T+220us  HDD 完成此 64K (NCQ 并发下平摊)
T+230us  HBA 写 reply descriptor → 触发 IRQ 79 @ CPU 84
T+231us  IRQ handler, drain reply queue
T+232us  blk_mq_complete_request_remote:
         cpus_share_cache(84,36)=false → smp_call_function_single_async
T+245us  CPU 36 收到 call_function_single IPI → BLOCK_SOFTIRQ
T+246us  scsi_done → aio_complete 写 ring
T+247us  wake_up_process(fio_task) — fio 在 CPU 36 的 rq, 本核 wake, ~0 μs
T+248us  fio 被调度, io_getevents 返回 1 个事件
T+250us  fio 生成新 iocb, io_submit(nr=1) → 下一轮""")

add_para(doc,
    'T+3.5us 到 T+4.5us 就是 merge 窗口——1 μs 级。闭环总开销 ~250 μs，其中 HDD 本体占 220 μs，'
    'CPU 路径 ~30 μs，1:2 贡献其中的 1–3 μs，high iops 再叠加 ~13 μs 的 IPI 派发。'
    'CPU 路径的抖动没有让单盘塌（因为 HDD 220 μs 里能容纳），但破坏了 merge（merge 窗口只有 μs 级）。'
)
p = doc.add_paragraph()
r = p.add_run('HDD 因为没被 merge 而吃到 32×64K 的细碎命令，在 36 盘并发下又进一步被 HBA 打断，'
              '这才是最后 110 MB/s 的出处。')
r.bold = True

doc.add_heading('10.3 数据与代码锚点索引', level=2)
add_para(doc, '本报告引用的实测数据（[DATA-X]）：')
add_table(doc,
    ['ID', '内容', '出处'],
    [
        ['DATA-1', '36 盘并发 iostat：sdaa-sdah 110 MB/s / aqu=32，sdai+ 264 MB/s / aqu=2', 'iostat -xk 1'],
        ['DATA-2', '单盘绑 CPU 36（1:2）：BW 275 MB/s，merge 0.08%，ctx 4400/s', 'fio 输出'],
        ['DATA-3', '单盘绑 CPU 48（1:1）：BW 275 MB/s，merge 86%，ctx 550/s', 'fio 输出'],
        ['DATA-4', 'fio %CPU = 1%，sched latency avg 1 μs / max 5 μs', 'pidstat + perf sched'],
        ['DATA-5', 'perf stat：call_function_single_entry 6586/s（high iops on）vs 6354/s（off）', 'perf stat -C 36,108'],
        ['DATA-6', '8 盘并发：sdaa-sdah 全部 ~270 MB/s（验证单纯 no-merge 不降带宽）', 'iostat'],
        ['DATA-7', 'offline CPU 108-115 → 1:1 → merge 恢复', 'iostat + fio'],
        ['DATA-8', '36 盘 bs=1M iodepth=2：sdaa-sdah 回到 216-234 MB/s', 'iostat'],
        ['DATA-9', 'clat log：7 ms → 12.7 ms → 18 ms（阶跃膨胀在 HBA/HDD 之下）', 'fio clat log'],
        ['DATA-10', 'IRQ 79-86 effective CPU 散到 CPU 1/6/12/16/23/35/84/99（跨 NUMA）', '/proc/interrupts'],
    ],
    widths_cm=[1.8, 11.2, 4.0]
)

add_para(doc, '本报告引用的代码锚点：')
add_table(doc,
    ['锚点', '位置', '作用'],
    [
        ['CODE-1', 'mpt3sas_base.c:3885-3892', '_base_get_msix_index() 普通 reply queue 选择'],
        ['CODE-2', 'mpt3sas_base.c:3905-3922', '_base_get_high_iops_msix_index() (cnt/16)%8'],
        ['CODE-3', 'mpt3sas_base.h:379-381', 'DEVICE_HIGH_IOPS_DEPTH=8 / REPLY_QUEUES=8 / BATCH_COUNT=16'],
        ['CODE-4', 'mpt3sas_base.c:3313-3347', '_base_check_and_enable_high_iops_queues() 激活条件'],
        ['CODE-5', 'block/blk-mq.c', 'blk_mq_complete_request_remote() cpus_share_cache 判断'],
        ['CODE-6', 'block/mq-deadline.c, block/elevator.c', 'dd_bio_merge + elv_rqhash_del 决定 merge 窗口'],
        ['CODE-7', 'fs/aio.c', 'io_submit() 内 blk_start_plug/blk_finish_plug 的 plug 生命周期'],
    ],
    widths_cm=[1.8, 6.5, 8.7]
)

# ---------------- 保存 ----------------
out = '/workspace/mpt3sas_1to2_hctx_analysis.docx'
doc.save(out)
print(f'Saved: {out}')
