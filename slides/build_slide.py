#!/usr/bin/env python3
"""Rebuild the P455 / Mafka slide from the measured ratios only.

The original summary page included a radar whose title said Intel = 100,
while the plotted Intel series sat near 50 on every axis and the epoll
vertex fell inside the zero ring. Those axes are not in the flame-graph
ratios. This deck keeps the monitoring screenshot, the nine measured
ratios, and the architecture notes, and drops the unsupported radar
and the writev clause that had no sample behind it.
"""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from PIL import Image
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

# Flame-graph ratios, Hygon / Intel. Same figures as the original line chart
# and the sentences that cite them. Intel is 1.
RATIOS = [
    ("ksys_write", 1.23),
    ("tcp_sendmsg", 1.29),
    ("tcp_recvmsg", 1.50),
    ("ksys_read", 1.58),
    ("skb_copy", 1.76),
    ("_copy_to_iter", 1.85),
    ("HashMap.getNode", 1.93),
    ("HashMap.putVal", 2.00),
    ("copy_user", 2.06),
]

SLIDE_W = 13.333
SLIDE_H = 7.5


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


def add_box(slide, x, y, w, h, lines, size=11, fill="FFFFFF", line="B5B5B5"):
    shape = slide.shapes.add_shape(
        1, Inches(x), Inches(y), Inches(w), Inches(h)  # MSO_SHAPE.RECTANGLE = 1
    )
    shape.fill.solid()
    shape.fill.fore_color.rgb = RGBColor.from_string(fill)
    shape.line.color.rgb = RGBColor.from_string(line)
    shape.line.width = Pt(0.75)
    tf = shape.text_frame
    tf.word_wrap = True
    tf.auto_size = None
    tf.margin_left = Inches(0.06)
    tf.margin_right = Inches(0.04)
    tf.margin_top = Inches(0.02)
    tf.margin_bottom = Inches(0.02)
    tf.anchor = MSO_ANCHOR.MIDDLE
    for i, line in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = PP_ALIGN.CENTER
        p.space_before = Pt(0)
        p.space_after = Pt(0)
        p.line_spacing = 1.0
        run = p.add_run()
        run.text = line
        set_run_font(run, size, bold=(i == 0), color="1A1A1A")
    return shape


def add_line(slide, x1, y1, x2, y2, arrow=True):
    conn = slide.shapes.add_connector(
        MSO_CONNECTOR.STRAIGHT, Inches(x1), Inches(y1), Inches(x2), Inches(y2)
    )
    conn.line.color.rgb = RGBColor.from_string("5C5C5C")
    conn.line.width = Pt(1.25)
    if arrow:
        line = conn.line._get_or_add_ln()
        line.append(
            parse_xml(
                '<a:tailEnd xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
                ' type="triangle" w="med" len="med"/>'
            )
        )
    return conn


def render_chart(path: Path):
    font_manager.fontManager.addfont(FONT_PATH)
    prop = font_manager.FontProperties(fname=FONT_PATH)
    names = [n for n, _ in RATIOS]
    values = [v for _, v in RATIOS]

    fig, ax = plt.subplots(figsize=(5.15, 4.55), dpi=200)
    fig.patch.set_facecolor("white")
    ax.set_facecolor("white")
    bars = ax.barh(names, values, color="#2C5F8A", height=0.62, zorder=2)
    ax.axvline(1.0, color="#666666", linestyle="--", linewidth=0.8, zorder=1)
    ax.set_xlim(0, 2.55)
    ax.set_ylim(-0.55, len(names) - 0.35)
    ax.set_xlabel("Hygon / Intel    虚线为 Intel = 1", fontproperties=prop, fontsize=9, color="#333333")
    ax.tick_params(axis="x", labelsize=8, colors="#333333")
    ax.tick_params(axis="y", labelsize=9, colors="#1A1A1A", length=0)
    for label in ax.get_xticklabels() + ax.get_yticklabels():
        label.set_fontproperties(prop)
    for bar, value in zip(bars, values):
        ax.text(
            value + 0.04,
            bar.get_y() + bar.get_height() / 2,
            f"{value:.2f}",
            va="center",
            ha="left",
            fontsize=8.5,
            color="#1A1A1A",
            fontproperties=prop,
        )
    ax.set_title(
        "Hygon / Intel 耗时倍数\n大于 1 表示 Hygon 更重。数据来自客户火焰图。",
        fontproperties=prop,
        fontsize=11,
        color="#1A1A1A",
        loc="left",
        pad=10,
    )
    ax.grid(axis="x", color="#E6E6E6", linewidth=0.6, zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color("#BFBFBF")
    ax.spines["bottom"].set_color("#BFBFBF")
    fig.tight_layout(pad=0.35)
    fig.savefig(path, dpi=200)
    plt.close(fig)


def build():
    ASSET.mkdir(parents=True, exist_ok=True)
    chart_path = ASSET / "ratios.png"
    shot_path = ASSET / "qps-screenshot.png"
    render_chart(chart_path)

    prs = Presentation()
    prs.slide_width = Inches(SLIDE_W)
    prs.slide_height = Inches(SLIDE_H)
    prs.core_properties.title = "P455 进入美团 Mafka 业务优化"
    prs.core_properties.subject = "Hygon P455 与 Intel 4314 的开箱对比，仅保留有采样的结论"
    slide = prs.slides.add_slide(prs.slide_layouts[6])

    # White background is the default. Title and the one measured result.
    add_text(
        slide, 0.38, 0.16, 12.5, 0.38,
        "P455 进入美团 Mafka 业务优化",
        size=22, bold=True,
    )
    rule = slide.shapes.add_shape(1, Inches(0.38), Inches(0.56), Inches(12.56), Emu(9525))
    rule.fill.solid()
    rule.fill.fore_color.rgb = RGBColor.from_string("C0392B")
    rule.line.fill.background()

    add_text(
        slide, 0.38, 0.64, 12.5, 0.32,
        "开箱性能：Hygon P455 的 QPS 为 6 万，Intel 4314 为 18 万，是 Intel 的 33%。",
        size=14, color="333333",
    )

    add_text(
        slide, 0.38, 1.02, 7.3, 0.24,
        "压测 QPS    com.sankuai.mqs.proxy.itshaiguang01    2026-08-20 16:17",
        size=11, bold=True,
    )

    with Image.open(shot_path) as shot:
        aspect = shot.height / shot.width
    pic_w = 7.30
    pic_h = pic_w * aspect
    slide.shapes.add_picture(
        str(shot_path), Inches(0.38), Inches(1.28), Inches(pic_w), Inches(pic_h)
    )
    frame = slide.shapes.add_shape(
        1, Inches(0.38), Inches(1.28), Inches(pic_w), Inches(pic_h)
    )
    frame.fill.background()
    frame.line.color.rgb = RGBColor.from_string("D0D0D0")
    frame.line.width = Pt(0.75)

    # Architecture. Three columns, boxes aligned, no unverified dashed path.
    arch_top = 1.28 + pic_h + 0.12
    add_text(slide, 0.38, arch_top, 2.1, 0.24, "业务侧", size=12, bold=True)
    add_text(slide, 3.05, arch_top, 2.2, 0.24, "MQS 接入层", size=12, bold=True)
    add_text(slide, 5.72, arch_top, 2.1, 0.24, "后端", size=12, bold=True)
    add_text(
        slide, 3.05, arch_top + 0.24, 2.20, 0.22,
        "无 K8s Service，直连 Pod IP",
        size=9, color="555555",
    )

    box_y0 = arch_top + 0.50
    box_h = 0.56
    gap = 0.08
    col_w = 2.08
    xs = (0.38, 3.05, 5.72)
    stack_h = 3 * box_h + 2 * gap

    add_box(
        slide, xs[0], box_y0, col_w, 1.02,
        ["Producer / 压测端", "美团自研压测工具，不是 ghz", "gRPC 直连 Pod IP"],
        size=10,
    )
    add_box(
        slide, xs[0], box_y0 + 1.14, col_w, 0.68,
        ["Consumer", "gRPC 直连 Pod IP"],
        size=10,
    )

    proxies = ["test1341 ×2", "test1342 ×2", "test1343 ×2"]
    backends = [
        ["Kafka / MQ Broker", "mafka 存储面", "内网 mafka-kafka 客户端"],
        ["metasrv", "元数据"],
        ["Redis 集群"],
    ]
    for i, name in enumerate(proxies):
        y = box_y0 + i * (box_h + gap)
        add_box(slide, xs[1], y, col_w, box_h, ["Proxy Pod", name], size=11)
        add_box(slide, xs[2], y, col_w, box_h, backends[i], size=10)
        add_line(slide, xs[1] + col_w, y + box_h / 2, xs[2], y + box_h / 2)

    # One arrow into a bracket, so it is not read as only test1342.
    bracket_x = xs[1] - 0.05
    add_line(slide, bracket_x, box_y0, bracket_x, box_y0 + stack_h, arrow=False)
    add_line(
        slide,
        xs[0] + col_w,
        box_y0 + 1.08,
        bracket_x,
        box_y0 + stack_h / 2,
    )

    note_y = box_y0 + 3 * box_h + 2 * gap + 0.06
    add_text(
        slide, 0.38, note_y, 7.4, 0.36,
        "消费拉取有两条路径：经 Proxy，或生态客户端直连 Broker。直连 Broker 还没有采集证实。",
        size=10, color="555555",
    )

    chart_top = 1.28
    slide.shapes.add_picture(
        str(chart_path), Inches(7.90), Inches(chart_top), Inches(5.10), Inches(4.50)
    )

    conc_y = note_y + 0.40
    add_text(
        slide, 0.38, conc_y, 12.55, 0.22,
        "火焰图结论，来自客户环境采集",
        size=12, bold=True, color="1A1A1A",
    )
    conclusions = [
        "1. 热点分布和 Intel 一致。Netty、gRPC、RocketMQ、fastjson 占比相当，Hygon 没有独有代码热点。",
        "2. 内核收发更重。ksys_read 是 Intel 的 1.58 倍。copy_user 没有走 ERMS 快路径，是 Intel 的 2.06 倍。NIC 中断不在业务核，接收缓存偏冷。",
        "3. 访存更重。HashMap.getNode 是 1.93 倍，putVal 是 2.00 倍，怀疑与 L3、CCX、NUMA 延迟有关。epoll 空闲更少，Hygon 更早饱和。",
    ]
    add_text(slide, 0.38, conc_y + 0.24, 12.55, 0.95, conclusions, size=12, color="1A1A1A", spacing=1.05)

    notes = slide.notes_slide.notes_text_frame
    notes.text = (
        "这一页只保留有采样的内容。"
        "原「综合雷达」标题写 Intel = 100，图上 Intel 各轴约在 50，epoll 一项落到 0 刻度以内，"
        "和火焰图倍数对不上，已删除。"
        "结论里「epoll、wall 中 writev ×2.08」没有对应采样，已删除。"
        "条形图的九个倍数与原折线图一致，Intel = 1。"
        "直连 Broker 的消费路径原图用虚线表示、注明尚未证实，本页改为文字说明，不画这条路径。"
    )

    out = ROOT / "p455-mafka.pptx"
    prs.save(out)
    print(f"wrote {out}")
    print(f"screenshot height {pic_h:.3f} in, arch note y {note_y:.3f}, conclusion y {conc_y:.3f}")


if __name__ == "__main__":
    build()
