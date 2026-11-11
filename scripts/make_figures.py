"""Draw the project figures from the CSV files in results/.

Each figure is saved twice, for light and dark page backgrounds:

    figures/<name>_light.png
    figures/<name>_dark.png

    python scripts/make_figures.py

Chart rules followed: one job per chart, one axis per chart, a single hue
for magnitude, thin marks with a rounded data end, hairline gridlines,
values labelled at the mark, and text in ink colours rather than the
series colour.
"""
from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
from matplotlib import font_manager
from matplotlib.patches import FancyBboxPatch, Rectangle

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"
FIGURES = ROOT / "figures"

THEMES = {
    "light": {
        "surface": "#fcfcfb", "ink": "#0b0b0b", "ink2": "#52514e", "muted": "#898781",
        "grid": "#e1e0d9", "axis": "#c3c2b7",
        "blue": "#2a78d6", "blue_soft": "#86b6ef", "orange": "#eb6834", "context": "#898781",
    },
    "dark": {
        "surface": "#1a1a19", "ink": "#f0efec", "ink2": "#c3c2b7", "muted": "#898781",
        "grid": "#2c2c2a", "axis": "#383835",
        "blue": "#3987e5", "blue_soft": "#184f95", "orange": "#d95926", "context": "#898781",
    },
}
SOURCE = "Data: Diabetes 130-US Hospitals 1999-2008 (Strack et al. 2014), UCI Machine Learning Repository.  Analysis: Elisha Abraham."
DPI = 200

# Use the first system sans-serif that is installed, so the script runs
# quietly on Windows, macOS and Linux alike.
_installed = {font.name for font in font_manager.fontManager.ttflist}
plt.rcParams["font.family"] = next(
    (name for name in ("Segoe UI", "Helvetica Neue", "Arial", "DejaVu Sans") if name in _installed), "sans-serif"
)


# --------------------------------------------------------------------- helpers
def new_figure(theme: dict, title: str, subtitle: str, height: float = 4.3):
    fig = plt.figure(figsize=(7.2, height), dpi=DPI)
    fig.patch.set_facecolor(theme["surface"])
    top = 1 - 0.19 / height
    fig.text(0.04, top, title, fontsize=12.5, fontweight="semibold", color=theme["ink"], ha="left", va="top")
    fig.text(0.04, top - 0.30 / height, subtitle, fontsize=9, color=theme["ink2"], ha="left", va="top")
    fig.text(0.04, 0.10 / height, SOURCE, fontsize=6.8, color=theme["muted"], ha="left", va="bottom")
    return fig


def style_axes(ax, theme: dict, grid: str = "y") -> None:
    ax.set_facecolor(theme["surface"])
    for side in ("top", "right", "left", "bottom"):
        ax.spines[side].set_visible(False)
    baseline = "bottom" if grid == "y" else "left"
    ax.spines[baseline].set_visible(True)
    ax.spines[baseline].set_color(theme["axis"])
    ax.spines[baseline].set_linewidth(0.8)
    ax.grid(axis=grid, color=theme["grid"], linewidth=0.6, zorder=0)
    ax.set_axisbelow(True)
    ax.tick_params(axis="both", length=0, labelsize=9, colors=theme["muted"], pad=5)


def per_pixel(ax) -> tuple[float, float]:
    """Data units covered by one logical pixel (1/100 inch) on each axis."""
    ax.figure.canvas.draw()
    scale = ax.figure.dpi / 100
    (x0, y0), (x1, y1) = ax.transData.inverted().transform([(0, 0), (scale, scale)])
    return abs(x1 - x0), abs(y1 - y0)


def column(ax, x: float, height: float, color: str, dx: float, dy: float, width_px: float = 22) -> None:
    """A vertical bar: rounded at the data end, square at the baseline."""
    width, radius_px = width_px * dx, 4
    ax.add_patch(FancyBboxPatch((x - width / 2, 0), width, height, boxstyle=f"round,pad=0,rounding_size={radius_px * dx}",
                                mutation_aspect=dy / dx, facecolor=color, edgecolor="none", zorder=3))
    ax.add_patch(Rectangle((x - width / 2, 0), width, max(height - radius_px * dy, 0), facecolor=color, edgecolor="none", zorder=3))


def row_bar(ax, y: float, length: float, color: str, dx: float, dy: float, thickness_px: float = 16) -> None:
    """A horizontal bar: rounded at the data end, square at the baseline."""
    thickness, radius_px = thickness_px * dy, 4
    ax.add_patch(FancyBboxPatch((0, y - thickness / 2), length, thickness, boxstyle=f"round,pad=0,rounding_size={radius_px * dx}",
                                mutation_aspect=dy / dx, facecolor=color, edgecolor="none", zorder=3))
    ax.add_patch(Rectangle((0, y - thickness / 2), max(length - radius_px * dx, 0), thickness, facecolor=color, edgecolor="none", zorder=3))


def legend(fig, theme: dict, entries: list[tuple[str, str]], x: float, y: float, marker: str = "s") -> None:
    """A one-row legend drawn in figure coordinates: swatch then label."""
    for color, label in entries:
        fig.text(x, y, "■" if marker == "s" else "●", fontsize=9, color=color, ha="left", va="center")
        text = fig.text(x + 0.018, y, label, fontsize=8.5, color=theme["ink2"], ha="left", va="center")
        fig.canvas.draw()
        x = text.get_window_extent().x1 / (fig.get_figwidth() * fig.dpi) + 0.03


def percent_ticks(ax, values: list[int], axis: str = "y") -> None:
    labels = [f"{v}%" if v else "0" for v in values]
    if axis == "y":
        ax.set_yticks(values, labels)
    else:
        ax.set_xticks(values, labels)


def save(fig, name: str, theme_name: str) -> None:
    FIGURES.mkdir(exist_ok=True)
    fig.savefig(FIGURES / f"{name}_{theme_name}.png", dpi=DPI, facecolor=fig.get_facecolor())
    plt.close(fig)


# --------------------------------------------------------------------- figures
def prior_stays(theme_name: str, segments: pd.DataFrame, average: float) -> None:
    theme = THEMES[theme_name]
    data = segments[segments.dimension == "Prior inpatient stays (past year)"].sort_values("segment_order")
    fig = new_figure(theme, "Each stay in the past year raises the chance of a 30-day return",
                     "30-day readmission rate by inpatient stays in the previous year. Lines show 95% confidence intervals.")
    ax = fig.add_axes([0.08, 0.17, 0.79, 0.60])
    style_axes(ax, theme)
    ax.set_xlim(-0.6, len(data) - 0.4)
    ax.set_ylim(0, 45)
    percent_ticks(ax, [0, 10, 20, 30, 40])
    ax.set_xticks(range(len(data)), data.segment)
    ax.set_xlabel("Inpatient stays in the previous year", fontsize=9, color=theme["ink2"], labelpad=7)
    dx, dy = per_pixel(ax)
    # the label sits on a patch of surface colour so the reference line never runs through a number
    label_box = {"facecolor": theme["surface"], "edgecolor": "none", "pad": 1.5}
    for x, row in enumerate(data.itertuples()):
        column(ax, x, row.rate_pct, theme["blue"], dx, dy)
        ax.vlines(x, row.ci_low_pct, row.ci_high_pct, color=theme["ink2"], linewidth=1, zorder=4)
        ax.text(x, row.ci_high_pct + 6 * dy, f"{row.rate_pct:.1f}%", fontsize=9, color=theme["ink"], ha="center", va="bottom",
                bbox=label_box, zorder=5)
    ax.axhline(average, color=theme["ink2"], linewidth=0.8, zorder=2)
    ax.text(1.015, average, f"All stays\n{average:.1f}%", transform=ax.get_yaxis_transform(), fontsize=8.5,
            color=theme["ink2"], ha="left", va="center", linespacing=1.3)
    save(fig, "readmission_by_prior_stays", theme_name)


def discharge_destination(theme_name: str, segments: pd.DataFrame) -> None:
    theme = THEMES[theme_name]
    data = segments[segments.dimension == "Discharge destination"].sort_values("rate_pct")
    fig = new_figure(theme, "Rehabilitation discharges return three times as often as home discharges",
                     "30-day readmission rate by discharge destination. Lines show 95% confidence intervals.")
    ax = fig.add_axes([0.33, 0.17, 0.63, 0.60])
    style_axes(ax, theme, grid="x")
    ax.set_xlim(0, 34)
    ax.set_ylim(-0.6, len(data) - 0.4)
    percent_ticks(ax, [0, 10, 20, 30], axis="x")
    ax.set_yticks(range(len(data)), data.segment)
    ax.tick_params(axis="y", colors=theme["ink2"])
    dx, dy = per_pixel(ax)
    for y, row in enumerate(data.itertuples()):
        row_bar(ax, y, row.rate_pct, theme["blue"], dx, dy)
        ax.hlines(y, row.ci_low_pct, row.ci_high_pct, color=theme["ink2"], linewidth=1, zorder=4)
        ax.text(row.ci_high_pct + 6 * dx, y, f"{row.rate_pct:.1f}%", fontsize=9, color=theme["ink"], ha="left", va="center")
    save(fig, "readmission_by_discharge_destination", theme_name)


def patient_concentration(theme_name: str, concentration: pd.DataFrame) -> None:
    theme = THEMES[theme_name]
    data = concentration.sort_values("sort_key")
    fig = new_figure(theme, "2% of patients account for a quarter of all 30-day readmissions",
                     "Patients grouped by number of hospital stays in the data.")
    legend(fig, theme, [(theme["blue"], "Share of patients"), (theme["orange"], "Share of 30-day readmissions")], 0.04, 0.80)
    ax = fig.add_axes([0.08, 0.14, 0.88, 0.58])
    style_axes(ax, theme)
    ax.set_xlim(-0.6, len(data) - 0.4)
    ax.set_ylim(0, 88)
    percent_ticks(ax, [0, 20, 40, 60, 80])
    ax.set_xticks(range(len(data)), data.patient_group)
    dx, dy = per_pixel(ax)
    offset = 12 * dx  # two 22px columns with a 2px surface gap between them
    for x, row in enumerate(data.itertuples()):
        column(ax, x - offset, row.pct_of_patients, theme["blue"], dx, dy)
        column(ax, x + offset, row.pct_of_readmissions, theme["orange"], dx, dy)
        ax.text(x - offset, row.pct_of_patients + 4 * dy, f"{row.pct_of_patients:.0f}%", fontsize=9, color=theme["ink"], ha="center", va="bottom")
        ax.text(x + offset, row.pct_of_readmissions + 4 * dy, f"{row.pct_of_readmissions:.0f}%", fontsize=9, color=theme["ink"], ha="center", va="bottom")
    save(fig, "patient_concentration", theme_name)


def hba1c(theme_name: str, table: pd.DataFrame) -> None:
    theme = THEMES[theme_name]
    data = table.assign(gap=table.rate_tested_pct - table.rate_not_tested_pct).sort_values("gap", ascending=False)
    fig = new_figure(theme, "The HbA1c gap is widest where diabetes is the reason for admission",
                     "30-day readmission rate with and without an HbA1c result during the stay, by primary diagnosis.", height=4.6)
    legend(fig, theme, [(theme["blue"], "HbA1c measured"), (theme["blue_soft"], "Not measured")], 0.04, 0.815, marker="o")
    ax = fig.add_axes([0.19, 0.15, 0.60, 0.60])
    style_axes(ax, theme, grid="x")
    ax.set_xlim(6, 16)
    ax.set_ylim(-0.6, len(data) - 0.4)
    percent_ticks(ax, [6, 8, 10, 12, 14, 16], axis="x")
    ax.set_yticks(range(len(data)), data.primary_diagnosis_group)
    ax.tick_params(axis="y", colors=theme["ink2"])
    ax.spines["left"].set_visible(False)
    for y, row in enumerate(data.itertuples()):
        ax.hlines(y, row.rate_tested_pct, row.rate_not_tested_pct, color=theme["axis"], linewidth=2, zorder=2)
        ax.plot(row.rate_not_tested_pct, y, "o", markersize=8, color=theme["blue_soft"], markeredgecolor=theme["surface"], markeredgewidth=1.5, zorder=3)
        ax.plot(row.rate_tested_pct, y, "o", markersize=8, color=theme["blue"], markeredgecolor=theme["surface"], markeredgewidth=1.5, zorder=4)
        ax.text(1.03, y, f"{row.pct_tested:.0f}% tested", transform=ax.get_yaxis_transform(), fontsize=8.5, color=theme["ink2"], ha="left", va="center")
    top = data.iloc[-1]
    ax.text(top.rate_tested_pct - 0.25, len(data) - 1, f"{top.rate_tested_pct:.1f}%", fontsize=8.5, color=theme["ink"], ha="right", va="center")
    ax.text(top.rate_not_tested_pct + 0.25, len(data) - 1, f"{top.rate_not_tested_pct:.1f}%", fontsize=8.5, color=theme["ink"], ha="left", va="center")
    save(fig, "hba1c_testing", theme_name)


def risk_score(theme_name: str, tiers: pd.DataFrame, calibration: pd.DataFrame) -> None:
    theme = THEMES[theme_name]
    fig = new_figure(theme, "A five-item score sorts discharges from 6% to 27% readmission",
                     "Tested on 29,591 stays by patients the score was not built on.", height=4.6)

    # left panel: rate by tier, held-out patients
    data = tiers.sort_values("risk_tier_order")
    ax = fig.add_axes([0.08, 0.25, 0.38, 0.46])
    style_axes(ax, theme)
    ax.set_xlim(-0.6, len(data) - 0.4)
    ax.set_ylim(0, 45)
    percent_ticks(ax, [0, 10, 20, 30, 40])
    ax.set_xticks(range(len(data)), data.risk_tier)
    ax.set_title("Readmission rate by risk tier", fontsize=9.5, fontweight="semibold", color=theme["ink"], loc="left", pad=10)
    dx, dy = per_pixel(ax)
    for x, row in enumerate(data.itertuples()):
        column(ax, x, row.readmission_rate_pct, theme["blue"], dx, dy)
        ax.text(x, row.readmission_rate_pct + 4 * dy, f"{row.readmission_rate_pct:.1f}%", fontsize=9, color=theme["ink"], ha="center", va="bottom")
        ax.text(x, -0.20, f"{row.pct_of_stays:.0f}% of stays", transform=ax.get_xaxis_transform(), fontsize=7.5, color=theme["muted"], ha="center", va="top")

    # right panel: rate by score, training against held-out.
    # Held-out is the series that matters, so it takes the colour; training is context in grey.
    points = calibration.sort_values("risk_score_capped")
    ax2 = fig.add_axes([0.57, 0.25, 0.39, 0.46])
    style_axes(ax2, theme)
    ax2.set_xlim(-0.4, 9.9)
    ax2.set_ylim(0, 45)
    percent_ticks(ax2, [0, 10, 20, 30, 40])
    ax2.set_xticks(points.risk_score_capped, [str(v) if v < 8 else "8+" for v in points.risk_score_capped])
    ax2.set_xlabel("Risk score", fontsize=9, color=theme["ink2"], labelpad=7)
    ax2.set_title("Rate by score: training against held-out", fontsize=9.5, fontweight="semibold", color=theme["ink"], loc="left", pad=10)
    marker = {"marker": "o", "markersize": 7, "markeredgecolor": theme["surface"], "markeredgewidth": 1.5, "linewidth": 2, "solid_capstyle": "round"}
    ax2.plot(points.risk_score_capped, points.training_rate_pct, color=theme["context"], zorder=3, **marker)
    ax2.plot(points.risk_score_capped, points.held_out_rate_pct, color=theme["blue"], zorder=4, **marker)
    for y, color, label in [(0.93, theme["blue"], "Held-out patients (30%)"), (0.83, theme["context"], "Training patients (70%)")]:
        ax2.text(0.04, y, "●", transform=ax2.transAxes, fontsize=9, color=color, ha="left", va="center")
        ax2.text(0.09, y, label, transform=ax2.transAxes, fontsize=8.5, color=theme["ink2"], ha="left", va="center")
    last = points.iloc[-1]
    ax2.text(8.3, last.training_rate_pct, "Training", fontsize=8.5, color=theme["ink2"], ha="left", va="center")
    ax2.text(8.3, last.held_out_rate_pct, "Held out", fontsize=8.5, color=theme["ink2"], ha="left", va="center")
    save(fig, "risk_score_validation", theme_name)


def main() -> None:
    segments = pd.read_csv(RESULTS / "rpt_segment_rates.csv", dtype={"segment": str})
    headline = pd.read_csv(RESULTS / "rpt_headline.csv").iloc[0]
    concentration = pd.read_csv(RESULTS / "rpt_patient_concentration.csv")
    hba1c_table = pd.read_csv(RESULTS / "rpt_hba1c_by_diagnosis.csv")
    tiers = pd.read_csv(RESULTS / "rpt_risk_tiers.csv")
    calibration = pd.read_csv(RESULTS / "rpt_score_calibration.csv")
    for theme_name in THEMES:
        prior_stays(theme_name, segments, float(headline.readmission_rate_pct))
        discharge_destination(theme_name, segments)
        patient_concentration(theme_name, concentration)
        hba1c(theme_name, hba1c_table)
        risk_score(theme_name, tiers, calibration)
    print(f"Saved {len(list(FIGURES.glob('*.png')))} figures to {FIGURES}")


if __name__ == "__main__":
    main()
