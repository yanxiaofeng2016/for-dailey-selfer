#!/usr/bin/env python3
"""Generate an Excel-style pentagon radar chart from 与规格比值 data."""

from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from matplotlib import font_manager
from matplotlib.lines import Line2D

FONT_PATH = "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"
font_manager.fontManager.addfont(FONT_PATH)
plt.rcParams["font.family"] = "WenQuanYi Micro Hei"
plt.rcParams["axes.unicode_minus"] = False

# Axes match the existing HBase write radar chart, clockwise from top.
CATEGORIES = ["cpu", "内存容量", "内存带宽", "网络带宽", "磁盘带宽"]

# 与规格比值 from the table. SMT OFF+默认 / 内存容量 was printed as 17.4
# (same as 原始数据); the other three columns are 0.04 for that metric.
SERIES = [
    ("SMT ON (默认)", [0.05, 0.04, 0.06, 0.005, 0]),
    ("SMT ON+ bind node", [0.09, 0.04, 0.07, 0.006, 0]),
    ("SMT OFF+ 默认", [0.09, 0.04, 0.05, 0.004, 0]),
    ("SMT OFF + bind node", [0.08, 0.04, 0.06, 0.008, 0]),
]

# Excel default palette used by the reference radar chart.
COLORS = ["#4472C4", "#ED7D31", "#A5A5A5", "#FFC000"]
GRID_COLOR = "#D4D4D4"
LABEL_COLOR = "#5A5A5A"
TITLE_COLOR = "#6A6A6A"
R_MAX = 0.10
R_TICKS = [0.00, 0.02, 0.04, 0.06, 0.08, 0.10]
# Bottom axes sit near the image edge; give those labels extra radius.
LABEL_RADIUS = {
    "cpu": 1.20,
    "内存容量": 1.22,
    "内存带宽": 1.28,
    "网络带宽": 1.28,
    "磁盘带宽": 1.22,
}


def polygon_angles(n: int) -> np.ndarray:
    """Regular polygon angles: first vertex at top, then clockwise."""
    return np.pi / 2 - np.arange(n, dtype=float) * (2 * np.pi / n)


def closed(values: np.ndarray) -> np.ndarray:
    return np.append(values, values[0])


def label_alignment(category: str) -> tuple[str, str]:
    return {
        "cpu": ("center", "bottom"),
        "内存容量": ("left", "center"),
        "内存带宽": ("center", "top"),
        "网络带宽": ("center", "top"),
        "磁盘带宽": ("right", "center"),
    }[category]


def format_ratio(value: float) -> str:
    if value == 0:
        return "0"
    if abs(value) < 0.01:
        return f"{value:.3f}"
    return f"{value:.2f}"


def main() -> None:
    n = len(CATEGORIES)
    angles = polygon_angles(n)
    angles_c = closed(angles)

    fig = plt.figure(figsize=(13.2, 11.2))
    fig.patch.set_facecolor("white")
    gs = fig.add_gridspec(2, 1, height_ratios=[3.6, 1.0], hspace=0.16)
    ax = fig.add_subplot(gs[0])
    ax_table = fig.add_subplot(gs[1])
    ax.set_facecolor("white")
    ax.set_aspect("equal")
    ax.axis("off")
    ax_table.axis("off")

    for radius in R_TICKS[1:]:
        ax.plot(
            radius * np.cos(angles_c),
            radius * np.sin(angles_c),
            color=GRID_COLOR,
            linewidth=1.05,
            zorder=1,
        )

    for angle in angles:
        ax.plot(
            [0, R_MAX * np.cos(angle)],
            [0, R_MAX * np.sin(angle)],
            color=GRID_COLOR,
            linewidth=1.05,
            zorder=1,
        )

    for (name, values), color in zip(SERIES, COLORS):
        radius = closed(np.asarray(values, dtype=float))
        xs = radius * np.cos(angles_c)
        ys = radius * np.sin(angles_c)
        ax.fill(xs, ys, color=color, alpha=0.07, zorder=2)
        ax.plot(
            xs,
            ys,
            color=color,
            linewidth=2.35,
            label=name,
            solid_capstyle="round",
            solid_joinstyle="round",
            zorder=3,
        )
        ax.scatter(
            xs[:-1],
            ys[:-1],
            s=28,
            color=color,
            zorder=4,
            edgecolors="white",
            linewidths=0.6,
        )

    # Keep small-axis values readable: 网络带宽 is ~10x smaller than cpu,
    # so points sit near the origin on a shared 0.10 scale.
    label_offsets = {
        "内存带宽": [0.012, 0.018, -0.012, 0.012],
        "网络带宽": [0.018, 0.028, 0.038, 0.048],
    }
    for series_idx, ((_, values), color) in enumerate(zip(SERIES, COLORS)):
        for category, extra in label_offsets.items():
            axis_idx = CATEGORIES.index(category)
            value = values[axis_idx]
            angle = angles[axis_idx]
            r_text = max(value, 0.012) + extra[series_idx]
            ax.text(
                r_text * np.cos(angle),
                r_text * np.sin(angle),
                format_ratio(value),
                color=color,
                fontsize=8.5,
                ha="center",
                va="center",
                zorder=5,
            )

    for tick in R_TICKS:
        ax.text(
            -R_MAX * 0.055,
            tick,
            f"{tick:.2f}",
            ha="right",
            va="center",
            color=LABEL_COLOR,
            fontsize=10,
            zorder=4,
        )

    for category, angle in zip(CATEGORIES, angles):
        ha, va = label_alignment(category)
        radius = R_MAX * LABEL_RADIUS[category]
        extra_y = R_MAX * 0.05 if category == "cpu" else 0
        extra_y -= R_MAX * 0.04 if category in {"内存带宽", "网络带宽"} else 0
        ax.text(
            radius * np.cos(angle),
            radius * np.sin(angle) + extra_y,
            category,
            ha=ha,
            va=va,
            color=LABEL_COLOR,
            fontsize=14,
        )

    ax.set_xlim(-R_MAX * 1.62, R_MAX * 1.62)
    ax.set_ylim(-R_MAX * 1.62, R_MAX * 1.48)

    fig.suptitle("与规格比值", color=TITLE_COLOR, fontsize=20, y=0.98)
    handles = [
        Line2D([0], [0], color=color, linewidth=2.35, marker="o", markersize=5)
        for color in COLORS
    ]
    fig.legend(
        handles,
        [name for name, _ in SERIES],
        loc="upper center",
        bbox_to_anchor=(0.5, 0.935),
        ncol=4,
        frameon=False,
        fontsize=11,
        handlelength=2.6,
        handletextpad=0.55,
        columnspacing=1.8,
        labelcolor=LABEL_COLOR,
    )

    col_labels = ["配置"] + CATEGORIES
    cell_text = [
        [name] + [format_ratio(value) for value in values]
        for name, values in SERIES
    ]
    table = ax_table.table(
        cellText=cell_text,
        colLabels=col_labels,
        loc="center",
        cellLoc="center",
    )
    table.auto_set_font_size(False)
    table.set_fontsize(10)
    table.scale(1.0, 1.55)
    for (row, col), cell in table.get_celld().items():
        cell.set_edgecolor("#E5E5E5")
        cell.set_linewidth(0.8)
        if row == 0:
            cell.set_facecolor("#F4F6F8")
            cell.set_text_props(color=LABEL_COLOR)
        elif col == 0:
            cell.set_text_props(ha="left", color=LABEL_COLOR)
            cell.PAD = 0.08
        else:
            cell.set_text_props(color=COLORS[row - 1])
        # Emphasize the two bandwidth columns the previous chart hid near the origin.
        if row == 0 and col in {3, 4}:
            cell.set_facecolor("#FFF6D8")

    fig.subplots_adjust(top=0.86, bottom=0.04, left=0.07, right=0.93)
    output = Path(__file__).with_suffix(".png")
    fig.savefig(output, dpi=180, bbox_inches="tight", facecolor="white", pad_inches=0.35)
    plt.close(fig)
    print(f"wrote {output}")


if __name__ == "__main__":
    main()
