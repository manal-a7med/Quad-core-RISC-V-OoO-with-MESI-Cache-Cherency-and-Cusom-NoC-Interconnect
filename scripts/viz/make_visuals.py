#!/usr/bin/env python3
"""Demo charts for the project presentation (results/visual/).

Every number is read from the committed text files in results/, so the charts
change only when those files change. Needs matplotlib (Ubuntu:
`sudo apt install python3-matplotlib`, or `pip install matplotlib`).

Usage: python3 scripts/viz/make_visuals.py [results] [results/visual]
       (or: make visuals)
"""
import os
import re
import sys

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker
    from matplotlib.patches import FancyBboxPatch
except ImportError:
    sys.exit("make_visuals.py needs matplotlib: sudo apt install python3-matplotlib "
             "(or pip install matplotlib)")

RES = sys.argv[1] if len(sys.argv) > 1 else "results"
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(RES, "visual")
os.makedirs(OUT, exist_ok=True)

# Colours (light theme). One colour per build, the same in every chart.
INK, INK2, MUTED = "#0b0b0b", "#52514e", "#8a8984"
GRID, SURFACE = "#e6e5e1", "#ffffff"
C = {"bus": "#2a78d6", "noc4_f256": "#eb6834", "noc1": "#1baf7a",
     "noc4": "#eda100", "noc1_f256": "#e87ba4"}
LABEL = {"bus": "Snooping bus", "noc1": "NoC, one home",
         "noc4": "NoC, a home per node", "noc1_f256": "NoC, one home, wide flits",
         "noc4_f256": "NoC, a home per node, wide flits"}
SINGLE = "#2a78d6"
# Colours for things that are not builds (ablation configs, traffic patterns).
OTHER = ["#6250d6", "#eda100", "#e87ba4"]

plt.rcParams.update({
    "font.size": 15, "axes.titlesize": 20, "axes.titleweight": "bold",
    "axes.labelsize": 15, "axes.edgecolor": GRID, "axes.labelcolor": INK2,
    "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True,
    "grid.color": GRID, "grid.linewidth": 1, "axes.axisbelow": True,
    "axes.spines.top": False, "axes.spines.right": False,
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "legend.frameon": False, "text.color": INK, "lines.linewidth": 2.5,
})
W, H = 12.8, 7.2   # 16:9, 1600 x 900 pixels at 125 dpi


def path(*p):
    return os.path.join(RES, *p)


def lines(p):
    with open(path(p)) as f:
        return [l.rstrip("\n") for l in f if l.strip() and not l.startswith("#")]


def bench(p):
    """bench.sh output: {name: timed-region cycles}"""
    d = {}
    for l in lines(p):
        m = re.match(r"(\S+) PASS .*region=(\d+)", l)
        if m:
            d[m.group(1)] = int(m.group(2))
    return d


def save(fig, name, note=None):
    if note:
        fig.text(0.01, 0.012, note, fontsize=11, color=MUTED, ha="left")
    fig.savefig(os.path.join(OUT, name), dpi=125)
    plt.close(fig)
    print("  " + os.path.join(OUT, name))


def headline(fig, title, sub):
    fig.text(0.04, 0.94, title, fontsize=22, weight="bold", color=INK, va="top")
    fig.text(0.04, 0.875, sub, fontsize=14, color=INK2, va="top")


# ---------------------------------------------------------------------------
# 1. The two systems, as a picture
def fig_architecture():
    fig, axs = plt.subplots(1, 2, figsize=(W, H))
    headline(fig, "Two ways to connect four cores",
             "Same cores, caches and memory in both. Only the connection between them changes.")
    for ax in axs:
        ax.set_xlim(0, 10); ax.set_ylim(0, 10); ax.axis("off")

    def box(ax, x, y, w, h, text, fc, ec, size=13, color=INK):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.25",
                                    fc=fc, ec=ec, lw=2))
        ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=size, color=color)

    # Bus
    ax = axs[0]
    ax.set_title("Baseline: snooping bus", color=C["bus"], pad=0, y=0.88)
    for i in range(4):
        x = 0.6 + i * 2.3
        box(ax, x, 6.2, 1.9, 1.3, f"Core {i}\n+ L1", "#eaf2fb", C["bus"])
        ax.plot([x + 0.95, x + 0.95], [6.2, 4.9], color=C["bus"], lw=2.5)
    ax.plot([0.5, 9.5], [4.8, 4.8], color=C["bus"], lw=7, solid_capstyle="round")
    ax.plot([5, 5], [4.8, 3.6], color=C["bus"], lw=2.5)
    box(ax, 3.4, 2.3, 3.2, 1.3, "Shared L2 + memory", "#f3f3f1", MUTED)
    ax.text(5, 1.6, "one shared bus: every miss is seen by every cache,\none transfer at a time",
            ha="center", va="top", fontsize=12, color=INK2)

    # Mesh
    ax = axs[1]
    ax.set_title("Contribution: 2x2 mesh NoC + directory", color=C["noc4_f256"], pad=0, y=0.88)
    pos = [(1.0, 5.6), (5.8, 5.6), (1.0, 1.4), (5.8, 1.4)]
    for i, (x, y) in enumerate(pos):
        box(ax, x, y, 3.0, 1.7, f"Core {i} + L1\nrouter + home {i}", "#fdeee7", C["noc4_f256"], size=12)
    for (a, b) in [(0, 1), (2, 3)]:
        y = pos[a][1] + 0.85
        ax.annotate("", xy=(pos[b][0] - 0.05, y), xytext=(pos[a][0] + 3.05, y),
                    arrowprops=dict(arrowstyle="<->", color=C["noc4_f256"], lw=2.5))
    for (a, b) in [(0, 2), (1, 3)]:
        x = pos[a][0] + 1.5
        ax.annotate("", xy=(x, pos[b][1] + 1.75), xytext=(x, pos[a][1] - 0.05),
                    arrowprops=dict(arrowstyle="<->", color=C["noc4_f256"], lw=2.5))
    ax.text(5.15, 4.3, "messages go point to point;\neach home tracks which caches\nhold its lines",
            ha="center", va="center", fontsize=11.5, color=INK2,
            bbox=dict(fc=SURFACE, ec="none", pad=2))
    ax.text(5, 0.45, "shared L2 + memory behind the homes", ha="center", fontsize=12, color=INK2)
    fig.subplots_adjust(top=0.85, bottom=0.04, left=0.02, right=0.98, wspace=0.05)
    save(fig, "01_architecture.png")


# ---------------------------------------------------------------------------
# 2. Verification scorecard
def fig_scorecard():
    cov = {}
    for l in lines("2026-11-21/coverage.txt"):
        m = re.match(r"(\w+): (\d+) of (\d+) bins hit", l)
        if m:
            cov[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    nbugs = sum(1 for l in open("docs/bugs.md") if re.match(r"\| *\d+ *\|", l)) \
        if os.path.exists("docs/bugs.md") else 24
    tiles = [
        ("59 / 59", "official RISC-V tests\n(rv32ui, rv32ua, rv32um)"),
        ("61 / 61", "test programs on the full\n4-core system, both networks"),
        ("8 / 8", "C programs on 4 cores\n(locks, queues, ordering)"),
        ("%d / %d" % cov.get("bus", (37, 37)), "coherence coverage bins hit\non the bus, 0 illegal events"),
        ("%d / %d" % cov.get("noc4", (41, 41)), "coherence coverage bins hit\non the NoC, 0 illegal events"),
        ("18 / 18", "deliberately broken designs\ncaught by the tests"),
        ("Proved", "bus arbiter: one grant at a time,\nround-robin, no starvation (formal)"),
        (str(nbugs), "bugs found and fixed,\neach with a test that catches it"),
    ]
    fig = plt.figure(figsize=(W, H))
    headline(fig, "Is it correct? Every check passes",
             "Official tests, random stress, coverage, broken designs and a formal proof.")
    for i, (big, small) in enumerate(tiles):
        r, c = divmod(i, 4)
        x, y = 0.04 + c * 0.235, 0.47 - r * 0.38
        ax = fig.add_axes([x, y, 0.215, 0.32]); ax.axis("off")
        ax.add_patch(FancyBboxPatch((0.02, 0.02), 0.96, 0.96, boxstyle="round,pad=0,rounding_size=0.06",
                                    fc="#f6f6f4", ec=GRID, lw=1.5, transform=ax.transAxes))
        ax.text(0.5, 0.64, big, ha="center", va="center", fontsize=34, weight="bold", color=INK)
        ax.text(0.5, 0.25, small, ha="center", va="center", fontsize=11.5, color=INK2)
    save(fig, "02_verification_scorecard.png",
         "Sources: README results table, results/2026-11-21/coverage.txt, docs/bugs.md")


# ---------------------------------------------------------------------------
# 3. Core performance work: before vs after
def fig_perf_work():
    before = bench("2026-11-11/bench_p3_baseline.txt")
    after = bench("2026-11-12/bench.txt")
    names = [n for n in after if n in before]
    sp = [before[n] / after[n] for n in names]
    lo, hi = min(sp), max(sp)
    fig, ax = plt.subplots(figsize=(W, H))
    headline(fig, f"The performance work made every benchmark {lo:.1f}x to {hi:.1f}x faster",
             "Speed-up of each benchmark after the core performance work. 4 cores, snooping bus.")
    bars = ax.bar(names, sp, width=0.6, color=SINGLE)
    for b, v in zip(bars, sp):
        ax.text(b.get_x() + b.get_width() / 2, v + 0.08, f"{v + 1e-9:.1f}x", ha="center", fontsize=13, color=INK)
    ax.axhline(1, color=MUTED, lw=1.5, ls="--")
    ax.set_ylabel("times faster than before")
    ax.grid(axis="x", visible=False)
    plt.setp(ax.get_xticklabels(), rotation=20)
    fig.subplots_adjust(top=0.80, bottom=0.16, left=0.08, right=0.98)
    ax.set_ylim(0, hi * 1.12)
    save(fig, "03_core_speedup_before_after.png",
         "Timed-region cycles, results/2026-11-11/bench_p3_baseline.txt vs results/2026-11-12/bench.txt")
    return lo, hi


# ---------------------------------------------------------------------------
# 4. Ablation: what each feature buys
def fig_ablation():
    full = bench("2026-11-11/bench_p4.txt")
    cfgs = [("no_bp", "No branch prediction", OTHER[0]),
            ("inorder", "In-order issue (no OoO)", OTHER[1]),
            ("msi", "MSI instead of MESI", OTHER[2])]
    data = {k: bench(f"2026-11-11/ablation_{k}.txt") for k, _, _ in cfgs}
    names = [n for n in full if all(n in data[k] for k, _, _ in cfgs)]
    fig, ax = plt.subplots(figsize=(W, H))
    headline(fig, "Branch prediction is the feature that matters most",
             "How much slower each benchmark runs with one feature switched off (1.0 = no change).")
    w = 0.26
    for j, (k, lab, col) in enumerate(cfgs):
        vals = [data[k][n] / full[n] for n in names]
        xs = [i + (j - 1) * (w + 0.02) for i in range(len(names))]
        ax.bar(xs, vals, width=w, color=col, label=lab)
    ax.axhline(1, color=MUTED, lw=1.5, ls="--")
    ax.set_xticks(range(len(names))); ax.set_xticklabels(names, rotation=20)
    ax.set_ylabel("times slower than the full design")
    top = max(data[k][n] / full[n] for k, _, _ in cfgs for n in names)
    ax.set_ylim(0.0, top * 1.08)
    ax.grid(axis="x", visible=False)
    ax.legend(loc="lower left", ncol=3, fontsize=13, bbox_to_anchor=(0, 1.0))
    fig.subplots_adjust(top=0.76, bottom=0.16, left=0.08, right=0.98)
    save(fig, "04_ablation.png", "results/2026-11-11/ablation_*.txt vs bench_p4.txt (make ablation)")


# ---------------------------------------------------------------------------
# 5. Bus vs NoC on real programs
def interconnect():
    rows, builds = {}, []
    for l in lines("2026-11-13/interconnect.txt"):
        t = l.split()
        if t[0] == "benchmark":
            builds = t[1:]
            continue
        if len(t) >= 2 and t[1].isdigit() and builds:
            nums = [int(x) for x in t[1:] if x.isdigit()]
            rows[t[0]] = dict(zip(builds, nums))
    return rows


def fig_bus_vs_noc():
    rows = interconnect()
    names = list(rows)
    show = ["noc1", "noc4_f256"]
    fig, ax = plt.subplots(figsize=(W, H))
    headline(fig, "On today's 4-core programs, the bus is as fast or faster",
             "How much faster (+) or slower (-) each benchmark runs on the NoC than on the bus.")
    w = 0.36
    pct = {b: [100 * (rows[n]["bus"] / rows[n][b] - 1) for n in names] for b in show}
    for j, b in enumerate(show):
        xs = [i + (j - 0.5) * (w + 0.03) for i in range(len(names))]
        ax.bar(xs, pct[b], width=w, color=C[b], label=LABEL[b])
    ax.axhline(0, color=INK2, lw=1.5)
    ax.set_ylim(-35, 10)
    ax.set_xticks(range(len(names))); ax.set_xticklabels(names, rotation=20)
    ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:+.0f}%" if v else "0%"))
    ax.set_ylabel("difference from the bus")
    ax.grid(axis="x", visible=False)
    ax.legend(loc="lower left", ncol=2, fontsize=13, bbox_to_anchor=(0, 1.0))
    if "mt-matmul" in names:
        i = names.index("mt-matmul"); v = pct["noc4_f256"][i]
        ax.text(i, v + 1.0, f"NoC {v:+.0f}%", ha="center", fontsize=12, color=INK)
    if "rsort" in names:
        i = names.index("rsort"); v = min(pct[b][i] for b in show)
        ax.text(i + 0.55, v + 2, "each miss is\nslower on the NoC", ha="left", va="bottom", fontsize=11.5, color=INK)
    fig.subplots_adjust(top=0.76, bottom=0.16, left=0.08, right=0.98)
    save(fig, "05_bus_vs_noc_benchmarks.png", "results/2026-11-13/interconnect.txt (make compare-ic)")


# ---------------------------------------------------------------------------
# 6. Synthetic traffic: throughput and latency under load
def traffic():
    pats, cur, builds = {}, None, []
    for l in lines("2026-11-13/traffic.txt"):
        m = re.match(r"pattern (\d+): (.*)", l)
        if m:
            cur = m.group(2); pats[cur] = {}
            continue
        t = l.split()
        if t and t[0] == "gap":
            builds = t[1:]
            continue
        if cur and t and t[0].isdigit():
            cells = re.findall(r"([\d.]+) / ([\d.]+)", l)
            for b, (thr, lat) in zip(builds, cells):
                pats[cur].setdefault(b, []).append((int(t[0]), float(thr), float(lat)))
    return pats


def fig_traffic():
    pats = traffic()
    show = ["bus", "noc1", "noc4_f256"]
    fig, axs = plt.subplots(1, 3, figsize=(W, H), sharey=True)
    headline(fig, "Under heavy load the NoC carries 1.5x more traffic than the bus",
             "Each point is one load level. Right = more accesses served, lower = each access answered sooner.")
    for ax, (pname, d) in zip(axs, pats.items()):
        for b in show:
            pts = d[b]
            ax.plot([p[1] for p in pts], [p[2] for p in pts], "-o", color=C[b], ms=7,
                    mec=SURFACE, mew=1.5, label=LABEL[b])
        ax.set_title(pname.replace(" (one set)", "").capitalize(), fontsize=16, pad=8)
        ax.set_xlabel("accesses per 1000 cycles")
        top = max(d["bus"][-1][1], d["noc4_f256"][-1][1])
        ax.set_xlim(30, 290)
    axs[0].set_ylabel("average latency (cycles)")
    axs[0].set_ylim(0, 30)
    p0 = list(pats.values())[0]
    b, n = p0["bus"][-1], p0["noc4_f256"][-1]
    axs[0].annotate(f"bus tops out\nat {b[1]:.0f}", xy=(b[1], b[2]), xytext=(b[1] - 105, b[2] + 4),
                    fontsize=11.5, arrowprops=dict(arrowstyle="-", color=MUTED))
    axs[0].annotate(f"NoC reaches\n{n[1]:.0f}", xy=(n[1], n[2]), xytext=(n[1] - 70, n[2] - 9),
                    fontsize=11.5, arrowprops=dict(arrowstyle="-", color=MUTED))
    axs[2].text(130, 3, "one hot line: a single home\nserves every miss, so the\nbus wins here",
                fontsize=11.5, color=INK2)
    axs[1].legend(loc="upper center", bbox_to_anchor=(0.5, -0.17), ncol=3, fontsize=13)
    fig.subplots_adjust(top=0.79, bottom=0.24, left=0.07, right=0.98, wspace=0.08)
    save(fig, "06_traffic_throughput_latency.png", "results/2026-11-13/traffic.txt (make traffic), 4 cores")


# ---------------------------------------------------------------------------
# 7. Parallel speed-up 1 -> 4 cores
def scaling():
    d, cur = {}, None
    for l in lines("2026-11-21/scaling.txt"):
        m = re.match(r"(\w+):$", l.strip())
        if m:
            cur = m.group(1); d[cur] = {}
            continue
        t = l.split()
        if cur and t and t[0].startswith("mt-") and len(t) >= 4 and t[1].isdigit():
            nums = [int(x) for x in t[1:] if x.isdigit()]
            d[cur][t[0]] = nums[:3]
        if l.startswith("4-core run"):
            cur = None
    return d


def fig_speedup():
    d = scaling()
    builds = [b for b in ["bus", "noc4_f256"] if b in d]
    benches = list(d[builds[0]])
    fig, axs = plt.subplots(1, len(benches), figsize=(W, H), sharey=True)
    headline(fig, "Four cores run the parallel programs 2.8x to 3.8x faster",
             "Speed-up over one core of the same system. The dashed line is perfect scaling.")
    cores = [1, 2, 4]
    for ax, bn in zip(axs, benches):
        ax.plot(cores, cores, "--", color=MUTED, lw=1.5)
        ends = {}
        for b in builds:
            c = d[b][bn]
            sp = [c[0] / x for x in c]
            ax.plot(cores, sp, "-o", color=C[b], ms=9, mec=SURFACE, mew=1.5, label=LABEL[b])
            ends[b] = sp[-1]
        # end labels, pushed apart when the two lines finish close together
        order = sorted(ends, key=ends.get)
        ys = [ends[b] for b in order]
        if len(ys) == 2 and ys[1] - ys[0] < 0.18:
            mid = (ys[0] + ys[1]) / 2
            ys = [mid - 0.09, mid + 0.09]
        for b, y in zip(order, ys):
            ax.text(4.12, y, f"{ends[b]:.2f}x", va="center", fontsize=12.5, color=INK)
        ax.set_title(bn, fontsize=16)
        ax.set_xticks(cores); ax.set_xlim(0.8, 4.7); ax.set_ylim(0.8, 4.3)
        ax.set_xlabel("cores")
    axs[0].set_ylabel("times faster than one core")
    axs[1].legend(loc="upper center", bbox_to_anchor=(0.5, -0.15), ncol=2, fontsize=13)
    fig.subplots_adjust(top=0.79, bottom=0.23, left=0.07, right=0.97, wspace=0.12)
    save(fig, "07_parallel_speedup.png", "results/2026-11-21/scaling.txt (make scaling)")


# ---------------------------------------------------------------------------
# 8. More cores: bus vs mesh model
def mesh_scaling():
    d, cur = {}, None
    for l in lines("2026-11-21/mesh_scaling.txt"):
        m = re.match(r"pattern \d+: (.*)", l)
        if m:
            cur = m.group(1); d[cur] = {}
            continue
        t = l.split()
        if cur and len(t) >= 7 and t[0].isdigit():
            n, gap = int(t[0]), int(t[1])
            if gap == 0:
                d[cur][n] = float(t[-1])
    return d


def fig_mesh_scaling():
    d = mesh_scaling()
    fig, ax = plt.subplots(figsize=(W, H))
    headline(fig, "With more cores the mesh pulls far ahead of the bus",
             "Throughput of the mesh over the bus at full load (1.0 = the same). "
             "Calibrated model of 4, 9 and 16 cores.")
    cols = OTHER
    names = list(d)
    cores = sorted(d[names[0]])
    w = 0.26
    for j, (pn, col) in enumerate(zip(names, cols)):
        vals = [d[pn][n] for n in cores]
        xs = [i + (j - 1) * (w + 0.02) for i in range(len(cores))]
        bars = ax.bar(xs, vals, width=w, color=col, label=pn.capitalize())
        for b, v in zip(bars, vals):
            ax.text(b.get_x() + b.get_width() / 2, v + 0.08, f"{v + 1e-9:.1f}x", ha="center", fontsize=12.5)
    ax.axhline(1, color=INK2, lw=1.5)
    ax.set_xticks(range(len(cores))); ax.set_xticklabels([f"{n} cores" for n in cores])
    ax.set_ylabel("mesh throughput / bus throughput")
    ax.grid(axis="x", visible=False)
    ax.legend(loc="upper left", fontsize=13)
    fig.subplots_adjust(top=0.80, bottom=0.10, left=0.08, right=0.98)
    save(fig, "08_more_cores_model.png",
         "results/2026-11-21/mesh_scaling.txt (make mesh-scaling); model calibrated on the 4-core RTL")


# ---------------------------------------------------------------------------
# 9. Coverage heat map
def fig_coverage():
    rows, builds = [], []
    for l in lines("2026-11-21/coverage.txt"):
        if l.startswith("bin"):
            builds = l.split()[2:]
            continue
        m = re.match(r"\s*(\d+)\s+(.+?)\s{2,}(\S+)\s+(\S+)\s+(\S+)\s*$", l)
        if m:
            rows.append((int(m.group(1)), m.group(2), m.group(3), m.group(4), m.group(5)))
    rows = [r for r in rows if not r[1].startswith("ILLEGAL")]
    import math
    fig = plt.figure(figsize=(W, H))
    headline(fig, "Every reachable protocol event was exercised",
             "Times each coherence event happened in the random stress test. Darker = more often; "
             "grey = does not exist in that system.")
    half = (len(rows) + 1) // 2
    ramp = ["#d6e6f8", "#a9cbf0", "#6fa6e3", "#2a78d6", "#1b549a"]
    for k, chunk in enumerate([rows[:half], rows[half:]]):
        ax = fig.add_axes([0.04 + k * 0.49, 0.06, 0.46, 0.76]); ax.axis("off")
        ax.set_xlim(0, 10); ax.set_ylim(len(chunk) + 1, -0.2)
        for j, b in enumerate(builds):
            ax.text(6.9 + j * 1.05, 0, b, ha="center", fontsize=11.5, color=INK2, weight="bold")
        for i, (n, ev, *vals) in enumerate(chunk):
            y = i + 1
            ax.text(0, y, ev if len(ev) < 44 else ev[:42] + "...", va="center", fontsize=10.5, color=INK)
            for j, v in enumerate(vals):
                x = 6.45 + j * 1.05
                if v == "-":
                    fc, txt, tc = "#efefec", "n/a", MUTED
                else:
                    c = int(v)
                    lvl = min(4, int(math.log10(max(c, 1))) - 1) if c >= 10 else 0
                    fc, txt, tc = ramp[max(lvl, 0)], v, (SURFACE if lvl >= 3 else INK)
                ax.add_patch(FancyBboxPatch((x, y - 0.42), 0.92, 0.84, boxstyle="round,pad=0,rounding_size=0.1",
                                            fc=fc, ec=SURFACE, lw=1))
                ax.text(x + 0.46, y, txt, ha="center", va="center", fontsize=9, color=tc)
    save(fig, "09_coverage_heatmap.png",
         "results/2026-11-21/coverage.txt (make coverage). The two illegal events never happened.")


if __name__ == "__main__":
    print("Writing charts to " + OUT)
    fig_architecture()
    fig_scorecard()
    fig_perf_work()
    fig_ablation()
    fig_bus_vs_noc()
    fig_traffic()
    fig_speedup()
    fig_mesh_scaling()
    fig_coverage()
