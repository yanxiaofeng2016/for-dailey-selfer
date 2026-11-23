#!/usr/bin/env python3
"""Rebuild the HBase / Hygon slide from numbers that agree with each other.

The original page put "最终结果达到 Intel 的 97.5%" on a seven-step flowchart.
The same page says throughput is 31% of Intel, estimated latency is 1.7x,
and the CPU is 97% idle. 97.5% is not a row in either microarch table.
This deck drops that flowchart and keeps the GC-log ratios, the flame-graph
hotspots, the write-path notes, and the two tables whose ratio columns match
the two value columns.
"""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_CONNECTOR
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.oxml import parse_xml
from pptx.oxml.ns import qn
from pptx.util import Emu, Inches, Pt

ROOT = Path(__file__).resolve().parent
ASSET = ROOT / "assets"
FONT_PATH = "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"
FONT_NAME = "WenQuanYi Micro Hei"

# GC log, Hygon / Intel. Bar lengths on the source slide match these labels.
# Young average 546 ms / 130 ms = 4.2. Object Copy 5.3x is the same figure
# cited in the GC finding.
GC_RATIOS = [
    ("Ext Root 扫描", 2.3),
    ("Young 平均停顿", 4.2),
    ("Cleanup STW", 4.6),
    ("Young P99", 5.2),
    ("Object Copy", 5.3),
    ("GC 开销（全程）", 8.9),
    ("Worker 启动差", 17.5),
]

# Flame-graph CPU share of the process. These four rows are separate hits.
# They overlap in the stack, so they are not slices of the 23.5% GC CPU.
FLAME = [
    ("对象复制\ntrim_queue", 19.3, 4.4),
    ("survivor\n复制", 11.5, 2.3),
    ("RSet\n扫描", 1.1, 2.2),
    ("并发\nrefine", 0.5, 5.2),
]

# write microarch, OpenJDK 1.8 vs Hygon JDK. The third column is Hygon/OpenJDK.
JDK_ROWS = [
    ("IPC", "0.24", "0.24", "100%"),
    ("l1-icache-bw", "153.24 G", "215.37 G", "141%"),
    ("l1-icache-miss", "9.39%", "8.56%", "91%"),
    ("l1-icache-mpki", "12.14", "11.41", "94%"),
    ("l1-dcache-bw", "1124.36 G", "1478.59 G", "132%"),
    ("l1-dcache-miss", "8.24%", "8.57%", "104%"),
    ("l1-dcache-mpki", "39.05", "39.24", "100%"),
    ("l2-dcache-bw", "92.55 G", "126.75 G", "137%"),
    ("l2-dcache-miss", "22.29%", "21.13%", "95%"),
    ("l2-dcache-mpki", "8.69", "8.27", "95%"),
    ("l2-prefetch-miss", "54.91%", "52.64%", "96%"),
    ("l2-prefetch-mpki", "9.04", "8.96", "99%"),
    ("l3-cache-access", "36.20 G", "48.72 G", "135%"),
    ("l3-cache-miss", "18.18%", "18.02%", "99%"),
]

# Same Hygon JDK write run, SMT on vs off. SMT-on matches the Hygon JDK column.
SMT_ROWS = [
    ("IPC", "0.24", "0.52", "217%"),
    ("l1-icache-bw", "215.37 G", "232.44 G", "108%"),
    ("l1-icache-miss", "8.56%", "9.15%", "107%"),
    ("l1-icache-mpki", "11.41", "12.53", "110%"),
    ("l1-dcache-bw", "1478.59 G", "1646.68 G", "111%"),
    ("l1-dcache-miss", "8.57%", "7.23%", "84%"),
    ("l1-dcache-mpki", "39.24", "35.07", "89%"),
    ("l2-icache-bw", "53.92 G", "64.55 G", "120%"),
    ("l2-icache-miss", "39.98%", "40.28%", "101%"),
    ("l2-icache-mpki", "13.31", "15.35", "115%"),
    ("l2-dcache-bw", "126.75 G", "119.35 G", "94%"),
    ("l2-dcache-miss", "21.13%", "20.59%", "97%"),
    ("l2-dcache-mpki", "8.27", "7.25", "88%"),
    ("l2-prefetch-miss", "52.64%", "44.50%", "85%"),
    ("l2-prefetch-mpki", "8.96", "7.99", "89%"),
    ("l3-cache-access", "48.72 G", "50.11 G", "103%"),
    ("l3-cache-miss", "18.02%", "18.60%", "103%"),
]


def _num(text):
    return float(text.replace("%", "").replace(" G", "").replace("G", "").strip())


def _check_ratios():
    for name, left, right, shown in JDK_ROWS:
        got = round(100 * _num(right) / _num(left))
        assert f"{got}%" == shown, (name, got, shown)
    for name, on, off, shown in SMT_ROWS:
        got = round(100 * _num(off) / _num(on))
        assert f"{got}%" == shown, (name, got, shown)
    # SMT-on is the Hygon JDK column, on the rows both tables share.
    jdk = {row[0]: row[2] for row in JDK_ROWS}
    for name, on, _off, _shown in SMT_ROWS:
        if name in jdk:
            assert jdk[name] == on, (name, jdk[name], on)


def set_run_font(run, size, bold=False, color="1A1A1A"):
    run.font.name = FONT_NAME
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = RGBColor.from_string(color)
    rpr = run._r.get_or_add_rPr()
    for tag in ("a:latin", "a:ea", "a:cs"):
        node = rpr.find(qn(tag))
        if node is None:
            node = parse_xml(
                f'<{tag} xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
                f' typeface="{FONT_NAME}"/>'
            )
            rpr.append(node)
        else:
            node.set("typeface", FONT_NAME)


def add_text(slide, x, y, w, h, lines, size=12, bold=False, color="1A1A1A",
             align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, spacing=1.0):
    shape = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = shape.text_frame
    tf.word_wrap = True
    tf.auto_size = None
    tf.margin_left = Inches(0.02)
    tf.margin_right = Inches(0.02)
    tf.margin_top = Inches(0.0)
    tf.margin_bottom = Inches(0.0)
    tf.anchor = anchor
    if isinstance(lines, str):
        lines = [lines]
    for i, line in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.space_before = Pt(0)
        p.space_after = Pt(0)
        p.line_spacing = spacing
        run = p.add_run()
        run.text = line
        set_run_font(run, size, bold, color)
    return shape


def add_box(slide, x, y, w, h, lines, size=10):
    shape = slide.shapes.add_shape(1, Inches(x), Inches(y), Inches(w), Inches(h))
    shape.fill.solid()
    shape.fill.fore_color.rgb = RGBColor.from_string("FFFFFF")
    shape.line.color.rgb = RGBColor.from_string("B5B5B5")
    shape.line.width = Pt(0.75)
    tf = shape.text_frame
    tf.word_wrap = True
    tf.auto_size = None
    tf.margin_left = Inches(0.06)
    tf.margin_right = Inches(0.05)
    tf.margin_top = Inches(0.04)
    tf.margin_bottom = Inches(0.03)
    tf.anchor = MSO_ANCHOR.MIDDLE
    for i, (text, bold, color) in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = PP_ALIGN.LEFT
        p.space_before = Pt(0)
        p.space_after = Pt(0)
        p.line_spacing = 1.0
        run = p.add_run()
        run.text = text
        set_run_font(run, size, bold, color)
    return shape


def add_line(slide, x1, y1, x2, y2):
    conn = slide.shapes.add_connector(
        MSO_CONNECTOR.STRAIGHT, Inches(x1), Inches(y1), Inches(x2), Inches(y2)
    )
    conn.line.color.rgb = RGBColor.from_string("5C5C5C")
    conn.line.width = Pt(1.15)
    line = conn.line._get_or_add_ln()
    line.append(
        parse_xml(
            '<a:tailEnd xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
            ' type="triangle" w="med" len="sm"/>'
        )
    )
    return conn


def _font():
    font_manager.fontManager.addfont(FONT_PATH)
    return font_manager.FontProperties(fname=FONT_PATH)


def render_gc_chart(path):
    prop = _font()
    names = [n for n, _ in GC_RATIOS]
    values = [v for _, v in GC_RATIOS]
    fig, ax = plt.subplots(figsize=(3.85, 2.45), dpi=200)
    fig.patch.set_facecolor("white")
    ax.barh(names, values, color="#C0392B", height=0.62)
    for bar, value in zip(ax.patches, values):
        ax.text(
            value + 0.25,
            bar.get_y() + bar.get_height() / 2,
            f"{value:.1f}×",
            va="center",
            ha="left",
            fontsize=8,
            color="#1A1A1A",
            fontproperties=prop,
        )
    ax.set_xlim(0, 22)
    ax.set_title("GC 日志倍数（Hygon / Intel）", fontproperties=prop, fontsize=11, loc="left", color="#1A1A1A")
    ax.tick_params(axis="y", length=0, labelsize=8)
    ax.tick_params(axis="x", labelsize=7, colors="#555555")
    for label in ax.get_yticklabels() + ax.get_xticklabels():
        label.set_fontproperties(prop)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.grid(axis="x", color="#E6E6E6", linewidth=0.6)
    fig.tight_layout(pad=0.3)
    fig.savefig(path, dpi=200)
    plt.close(fig)


def render_flame_chart(path):
    prop = _font()
    labels = [n for n, _, _ in FLAME]
    hygon = [h for _, h, _ in FLAME]
    intel = [i for _, _, i in FLAME]
    import numpy as np

    x = np.arange(len(labels))
    width = 0.36
    fig, ax = plt.subplots(figsize=(3.85, 2.45), dpi=200)
    fig.patch.set_facecolor("white")
    b1 = ax.bar(x - width / 2, hygon, width, color="#C0392B", label="Hygon")
    b2 = ax.bar(x + width / 2, intel, width, color="#2C5F8A", label="Intel")
    for bars in (b1, b2):
        for bar in bars:
            height = bar.get_height()
            ax.text(
                bar.get_x() + bar.get_width() / 2,
                height + 0.35,
                f"{height:.1f}",
                ha="center",
                va="bottom",
                fontsize=7.5,
                color="#1A1A1A",
                fontproperties=prop,
            )
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontproperties=prop, fontsize=8)
    ax.set_ylim(0, 26)
    ax.set_ylabel("占进程 CPU %", fontproperties=prop, fontsize=8)
    ax.set_title(
        "火焰图热点（各项单独统计，不能加总）",
        fontproperties=prop,
        fontsize=11,
        loc="left",
        color="#1A1A1A",
    )
    legend = ax.legend(frameon=False, prop=prop, fontsize=8, loc="upper right")
    for text in legend.get_texts():
        text.set_fontproperties(prop)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.grid(axis="y", color="#E6E6E6", linewidth=0.6)
    ax.tick_params(axis="y", labelsize=7, colors="#555555")
    fig.tight_layout(pad=0.3)
    fig.savefig(path, dpi=200)
    plt.close(fig)


def render_metric_table(path, title, headers, rows, figsize):
    """Draw the table as an image so a slide app cannot stretch the rows over the next block."""
    prop = _font()
    fig, ax = plt.subplots(figsize=figsize, dpi=200)
    fig.patch.set_facecolor("white")
    ax.axis("off")
    ax.set_title(title, fontproperties=prop, fontsize=11, loc="left", color="#1A1A1A", pad=2)
    cell_text = [list(row) for row in rows]
    table = ax.table(cellText=cell_text, colLabels=headers, loc="upper center", cellLoc="right")
    table.auto_set_font_size(False)
    table.set_fontsize(7.5)
    table.scale(1.0, 1.18)
    widths = [0.36, 0.22, 0.21, 0.21]
    for (r, c), cell in table.get_celld().items():
        cell.set_width(widths[c])
        cell.set_edgecolor("#E4E4E4")
        cell.set_linewidth(0.4)
        text = cell.get_text()
        text.set_fontproperties(prop)
        text.set_fontsize(7.5)
        text.set_color("#1A1A1A")
        if r == 0:
            cell.set_facecolor("#F3F3F3")
            text.set_fontweight("bold")
        elif r % 2 == 1:
            cell.set_facecolor("#FFF8F0")
        else:
            cell.set_facecolor("#FFFFFF")
        if c == 0:
            text.set_ha("left")
            # matplotlib pads left-aligned text from the cell edge
            text.set_position((0.02, 0.5))
            text.set_va("center")
    fig.tight_layout(pad=0.15)
    fig.savefig(path, dpi=200)
    plt.close(fig)


def build():
    _check_ratios()
    ASSET.mkdir(parents=True, exist_ok=True)
    gc_path = ASSET / "hbase-gc.png"
    flame_path = ASSET / "hbase-flame.png"
    jdk_path = ASSET / "hbase-jdk.png"
    smt_path = ASSET / "hbase-smt.png"
    render_gc_chart(gc_path)
    render_flame_chart(flame_path)
    render_metric_table(
        jdk_path,
        "写场景，OpenJDK 1.8 与 Hygon JDK",
        ["指标", "OpenJDK 1.8", "Hygon JDK", "Hygon/OpenJDK"],
        JDK_ROWS,
        (4.95, 3.05),
    )
    render_metric_table(
        smt_path,
        "同一套 Hygon JDK，SMT 开 / 关",
        ["指标", "SMT 开", "SMT 关", "关/开"],
        SMT_ROWS,
        (4.95, 3.35),
    )

    prs = Presentation()
    prs.slide_width = Inches(13.333)
    prs.slide_height = Inches(7.5)
    prs.core_properties.title = "HBase 美团业务场景：Hygon 相对 Intel 的差距"
    slide = prs.slides.add_slide(prs.slide_layouts[6])

    add_text(slide, 0.32, 0.10, 11.5, 0.32, "HBase 美团业务场景：Hygon 相对 Intel 的差距", size=20, bold=True)
    add_text(slide, 12.15, 0.14, 0.9, 0.24, "机密", size=12, bold=True, color="666666", align=PP_ALIGN.RIGHT)
    rule = slide.shapes.add_shape(1, Inches(0.32), Inches(0.44), Inches(12.68), Emu(9525))
    rule.fill.solid()
    rule.fill.fore_color.rgb = RGBColor.from_string("C0392B")
    rule.line.fill.background()
    add_text(
        slide, 0.32, 0.48, 12.6, 0.26,
        "本地用 HBase + YCSB 复现写路径。GC 倍数来自日志，热点来自火焰图，右侧两表是同一套写场景的微架构计数。",
        size=11, color="333333",
    )

    add_text(slide, 0.32, 0.78, 2.2, 0.22, "写路径", size=12, bold=True)
    headers_y = 1.00
    box_y = 1.40
    box_h = 1.58
    col_w = 2.36
    xs = (0.32, 2.86, 5.40)
    add_text(slide, xs[0], headers_y, col_w, 0.36, "压测客户端", size=11, bold=True)
    add_text(slide, xs[1], headers_y, col_w, 0.36, ["本机 10.101.19.161", "ssd-dn，同机混部"], size=11, bold=True, spacing=0.95)
    add_text(slide, xs[2], headers_y, col_w, 0.36, "远端节点", size=11, bold=True)

    ink = "1A1A1A"
    muted = "555555"
    warn = "8C2F2F"
    add_box(slide, xs[0], box_y, col_w, box_h, [
        ("YCSB client，写为主", True, ink),
        ("① RPC Put 到 RegionServer :16020", False, ink),
        ("⑦ 等本机和远端 DataNode", False, ink),
        ("都 ack 之后返回客户端", False, ink),
    ], size=10)
    add_box(slide, xs[1], box_y, col_w, box_h, [
        ("RegionServer :16020", True, ink),
        ("② 写入 MemStore（offheap）", False, ink),
        ("flush / compaction 走 BucketCache", False, ink),
        ("③ WAL 主写 DataNode :50010", False, ink),
        ("⑤ NVMe /data13", False, ink),
        ("w_await 0.46 ms，util 10–14%", False, ink),
        ("磁盘不是瓶颈", False, muted),
    ], size=10)
    add_box(slide, xs[2], box_y, col_w, box_h, [
        ("DataNode 10.101.19.154:50010", True, ink),
        ("WAL 副本，然后远端落盘", False, ink),
        ("其他 RS 186 / 147", False, ink),
        ("含 154 的副本写入", False, ink),
        ("⑥ 等本机 DN + 远端 DN 都 ack", False, warn),
        ("slow sync 约 147–158 ms", False, warn),
    ], size=10)
    add_line(slide, xs[0] + col_w, box_y + box_h / 2, xs[1], box_y + box_h / 2)
    add_line(slide, xs[1] + col_w, box_y + 0.55, xs[2], box_y + 0.42)

    add_text(
        slide, 0.32, 3.04, 7.5, 0.24,
        "请求 92% 的时间在等 WAL ack。全局 STW 期间 handler 和 ack 都停住。",
        size=11, color="333333",
    )

    slide.shapes.add_picture(str(gc_path), Inches(0.28), Inches(3.30), Inches(3.85), Inches(2.35))
    slide.shapes.add_picture(str(flame_path), Inches(4.10), Inches(3.30), Inches(3.75), Inches(2.35))

    # Findings sit under the charts. Young 546/130 = 4.2, same as the bar.
    add_text(slide, 0.32, 5.68, 3.7, 0.22, "差距 1　GC 停顿和 CPU", size=12, bold=True)
    add_text(
        slide, 0.32, 5.90, 3.75, 1.45,
        "Young GC 平均 546 ms 对 130 ms，是 4.2 倍。GC 占 CPU 23.5% 对 12.6%。JDK 8 的 G1 不支持 NUMA，打开 +UseNUMA 没有效果。对象复制受访存延迟限制，Object Copy 为 5.3 倍。",
        size=11, color="1A1A1A", spacing=1.05,
    )
    add_text(slide, 4.15, 5.68, 3.7, 0.22, "差距 2　请求延迟，估算 1.7 倍", size=12, bold=True)
    add_text(
        slide, 4.15, 5.90, 3.7, 1.45,
        "CPU 有 97% 空闲，吞吐是 Intel 的 31%。延迟大约 1.7 倍，这是估算。时间主要耗在 WAL ack 上。",
        size=11, color="1A1A1A", spacing=1.05,
    )

    slide.shapes.add_picture(str(jdk_path), Inches(8.05), Inches(0.74), Inches(4.95), Inches(3.05))
    slide.shapes.add_picture(str(smt_path), Inches(8.05), Inches(3.88), Inches(4.95), Inches(3.35))

    notes = slide.notes_slide.notes_text_frame
    notes.text = (
        "去掉了右上角七步流程图。其中「最终结果达到 Intel 的 97.5%」在本页没有采样。"
        "同页写的是吞吐为 Intel 的 31%、延迟约 1.7 倍（估算）、CPU 97% 空闲。"
        "97.5% 和「CPU 97% 空闲」不是一个数，微架构表里也没有 97.5% 这一行。"
        "GC 条形图的长度和标注成比例，Young 平均 546/130=4.2，Object Copy 5.3 与结论一致。"
        "两张表的比值列等于后列除以前列，SMT 开的列与 Hygon JDK 列在共有指标上相同。"
        "火焰图四项是单独统计的热点，调用上有包含关系，不能相加后去对 GC 占 CPU 的 23.5%。"
        "绑定 NUMA 没有前后 QPS，页上只保留「JDK 8 的 G1 打开 +UseNUMA 没有效果」。"
        "写路径上的 IP、端口、/data13 的 w_await 和 slow sync 147–158 ms 按原图抄录。"
    )

    out = ROOT / "hbase-hygon.pptx"
    prs.save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    build()
