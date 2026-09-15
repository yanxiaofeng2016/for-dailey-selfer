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
LABEL_COLOR = "#8A8A8A"
TITLE_COLOR = "#8A8A8A"
R_MAX = 0.10
R_TICKS = [0.00, 0.02, 0.04, 0.06, 0.08, 0.10]


def polygon_angles(n: int) -> np.ndarray:
    """Regular polygon angles: first vertex at top, then clockwise."""
    return np.pi / 2 - np.arange(n, dtype=float) * (2 * np.pi / n)


def closed(values: np.ndarray) -> np.ndarray:
    return np.append(values, values[0])


def label_alignment(angle: float) -> tuple[str, str]:
    deg = (np.degrees(angle) + 360) % 360
    if 80 <= deg <= 100:
        return "center", "bottom"
    if deg <= 20 or deg >= 340:
        return "left", "center"
    if 250 <= deg <= 300:
        return "left", "top"
    if 200 <= deg <= 250:
        return "right", "top"
    return "right", "center"


def main() -> None:
    n = len(CATEGORIES)
    angles = polygon_angles(n)
    angles_c = closed(angles)

    fig, ax = plt.subplots(figsize=(12.8, 8.4))
    fig.patch.set_facecolor("white")
    ax.set_facecolor("white")
    ax.set_aspect("equal")
    ax.axis("off")

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
        ax.plot(
            radius * np.cos(angles_c),
            radius * np.sin(angles_c),
            color=color,
            linewidth=2.35,
            label=name,
            solid_capstyle="round",
            solid_joinstyle="round",
            zorder=3,
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

    label_radius = R_MAX * 1.18
    for category, angle in zip(CATEGORIES, angles):
        ha, va = label_alignment(angle)
        extra_y = R_MAX * 0.06 if category == "cpu" else 0
        ax.text(
            label_radius * np.cos(angle),
            label_radius * np.sin(angle) + extra_y,
            category,
            ha=ha,
            va=va,
            color=LABEL_COLOR,
            fontsize=12,
        )

    ax.set_xlim(-R_MAX * 1.52, R_MAX * 1.52)
    ax.set_ylim(-R_MAX * 1.32, R_MAX * 1.42)

    fig.suptitle("与规格比值", color=TITLE_COLOR, fontsize=20, y=0.97)
    handles = [
        Line2D([0], [0], color=color, linewidth=2.35) for color in COLORS
    ]
    fig.legend(
        handles,
        [name for name, _ in SERIES],
        loc="upper center",
        bbox_to_anchor=(0.5, 0.915),
        ncol=4,
        frameon=False,
        fontsize=11,
        handlelength=2.6,
        handletextpad=0.55,
        columnspacing=1.8,
        labelcolor=LABEL_COLOR,
    )

    fig.subplots_adjust(top=0.82, bottom=0.06, left=0.08, right=0.92)
    output = Path(__file__).with_suffix(".png")
    fig.savefig(output, dpi=180, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"wrote {output}")


if __name__ == "__main__":
    main()
