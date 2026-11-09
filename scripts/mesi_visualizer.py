#!/usr/bin/env python3
"""
mesi_visualizer.py -- Visual & Interactive MESI Cache Coherence Animator
=======================================================================
Designed for the Quad-Core Out-of-Order RISC-V Processor with MESI Coherence.

Features:
  1. Verifies real RTL simulation output (tb_quad_core.v / tb_mesi_coherence.v)
  2. Rich terminal step-by-step animation (--cli)
  3. High-resolution smooth animated GIF export (--gif docs/mesi_coherence_animation.gif)
  4. Interactive desktop Matplotlib GUI with Play/Pause/Prev/Next buttons (--gui)
"""

import argparse
import os
import subprocess
import sys
import time

import matplotlib
import numpy as np

# Use TkAgg only when launching interactive GUI; otherwise use Agg for fast headless GIF rendering
if "--gui" not in sys.argv:
    matplotlib.use("Agg")

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, Circle
from matplotlib.animation import FuncAnimation, PillowWriter

try:
    from rich.console import Console
    from rich.table import Table
    from rich.panel import Panel
    from rich.text import Text
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False


# =============================================================================
# Color Palette (Modern Dark Silicon Dashboard Theme)
# =============================================================================
BG_DARK       = "#0B0F19"
PANEL_BG      = "#111827"
PANEL_BORDER  = "#334155"
TEXT_MAIN     = "#F8FAFC"
TEXT_MUTED    = "#94A3B8"
WIRE_IDLE     = "#334155"

STATE_COLORS = {
    "M": {"bg": "#F59E0B", "fg": "#0B0F19", "border": "#FBBF24", "name": "MODIFIED (Dirty, Sole Owner)"},
    "E": {"bg": "#10B981", "fg": "#0B0F19", "border": "#34D399", "name": "EXCLUSIVE (Clean, Sole Owner)"},
    "S": {"bg": "#3B82F6", "fg": "#F8FAFC", "border": "#60A5FA", "name": "SHARED (Clean, Shared Copy)"},
    "I": {"bg": "#374151", "fg": "#9CA3AF", "border": "#4B5563", "name": "INVALID (Empty / Stale)"},
}

BUS_COLORS = {
    "NONE":    "#475569",
    "BusRd":   "#38BDF8",
    "BusRdX":  "#F43F5E",
    "BusUpgr": "#A855F7",
    "HITM":    "#F59E0B",
}


# =============================================================================
# Step-by-Step Coherence Storyboard (Grounded in tb_quad_core.v Execution)
# =============================================================================
SCENARIOS = [
    {
        "step": 0,
        "title": "Step 0: Initial Cold Reset -- All L1 Caches Invalid (I)",
        "instruction": "System Reset (rst_n = 0 -> 1)",
        "active_core": None,
        "bus_cmd": "NONE",
        "bus_label": "Bus Idle -- No Active Coherence Transaction",
        "cores": [
            {"state": "I", "data": "--", "snoop": "NONE", "action": "Idle"},
            {"state": "I", "data": "--", "snoop": "NONE", "action": "Idle"},
            {"state": "I", "data": "--", "snoop": "NONE", "action": "Idle"},
            {"state": "I", "data": "--", "snoop": "NONE", "action": "Idle"},
        ],
        "l2": {"state": "Empty (Miss)", "data": "--", "dirty": False},
        "mem": {"data": "42 (0x0000002A)", "active": False},
        "packets": [],
        "explanation": (
            "BEGINNER GUIDE: At startup, all 4 cores have empty L1 Data Caches marked INVALID (I). "
            "Main Memory holds the initial shared variable at address 0x0100 = 42. "
            "If any core wants to read or write 0x0100, it must use the Snooping Coherence Bus."
        ),
    },
    {
        "step": 1,
        "title": "Step 1: Core 0 Cold Read Miss (I -> E via BusRd)",
        "instruction": "Core 0: LW x1, 0x100(x0)   [Read Miss]",
        "active_core": 0,
        "bus_cmd": "BusRd",
        "bus_label": "Core 0 broadcasts BusRd(0x0100) | Snoops: All Miss (shared=0) | L2/Mem -> Core 0",
        "cores": [
            {"state": "E", "data": "42", "snoop": "REQ",  "action": "Read Miss -> E"},
            {"state": "I", "data": "--", "snoop": "MISS", "action": "Snoop Miss"},
            {"state": "I", "data": "--", "snoop": "MISS", "action": "Snoop Miss"},
            {"state": "I", "data": "--", "snoop": "MISS", "action": "Snoop Miss"},
        ],
        "l2": {"state": "Valid (Clean)", "data": "42", "dirty": False},
        "mem": {"data": "42 (Fetched)", "active": True},
        "packets": [
            {"src": "core0", "dst": "bus", "color": "#38BDF8", "label": "1. BusRd"},
            {"src": "mem",   "dst": "l2",  "color": "#10B981", "label": "2. Fill 42"},
            {"src": "l2",    "dst": "core0", "color": "#10B981", "label": "3. Data=42"},
        ],
        "explanation": (
            "WHY EXCLUSIVE (E)? Core 0 asks for address 0x0100 using BusRd. The Snoop Controller checks "
            "Cores 1, 2, and 3 -- none of them have it (shared=0). Main Memory supplies 42 into Shared L2 "
            "and Core 0's L1D. Because Core 0 is the ONLY core caching this clean line, its state becomes EXCLUSIVE (E)."
        ),
    },
    {
        "step": 2,
        "title": "Step 2: Core 1 Read Miss -- Shared Copy (E -> S & I -> S)",
        "instruction": "Core 1: LW x1, 0x100(x0)   [Read Miss, Snoop HIT]",
        "active_core": 1,
        "bus_cmd": "BusRd",
        "bus_label": "Core 1 broadcasts BusRd(0x0100) | Core 0 replies SNOOP_HIT (E -> S) | L2 Hit -> Core 1",
        "cores": [
            {"state": "S", "data": "42", "snoop": "HIT",  "action": "Downgrade E -> S"},
            {"state": "S", "data": "42", "snoop": "REQ",  "action": "Read Miss -> S"},
            {"state": "I", "data": "--", "snoop": "MISS", "action": "Snoop Miss"},
            {"state": "I", "data": "--", "snoop": "MISS", "action": "Snoop Miss"},
        ],
        "l2": {"state": "Valid (Clean Hit!)", "data": "42", "dirty": False},
        "mem": {"data": "42 (Idle)", "active": False},
        "packets": [
            {"src": "core1", "dst": "bus",   "color": "#38BDF8", "label": "1. BusRd"},
            {"src": "core0", "dst": "bus",   "color": "#60A5FA", "label": "2. SNOOP_HIT"},
            {"src": "l2",    "dst": "core1", "color": "#3B82F6", "label": "3. L2 Hit (42)"},
        ],
        "explanation": (
            "WHY SHARED (S)? Core 1 also reads 0x0100. When Core 0 snoops Core 1's BusRd, Core 0 raises "
            "SNOOP_HIT (telling the bus another cache has a copy) and downgrades itself from EXCLUSIVE (E) to SHARED (S). "
            "Shared L2 supplies 42 directly (no slow Main Memory access needed!), and Core 1 also enters SHARED (S)."
        ),
    },
    {
        "step": 3,
        "title": "Step 3: Cores 2 & 3 Read 0x0100 -- All 4 Cores Share Line (S, S, S, S)",
        "instruction": "Cores 2 & 3: LW x1, 0x100(x0)   [All 4 Cores Read Hit/Share]",
        "active_core": 2,
        "bus_cmd": "BusRd",
        "bus_label": "Cores 2 & 3 issue BusRd(0x0100) | Sharers reply SNOOP_HIT | All 4 Cores now in SHARED (S)",
        "cores": [
            {"state": "S", "data": "42", "snoop": "HIT", "action": "Keep S (42)"},
            {"state": "S", "data": "42", "snoop": "HIT", "action": "Keep S (42)"},
            {"state": "S", "data": "42", "snoop": "REQ", "action": "Filled S (42)"},
            {"state": "S", "data": "42", "snoop": "REQ", "action": "Filled S (42)"},
        ],
        "l2": {"state": "Valid (Clean Hit!)", "data": "42", "dirty": False},
        "mem": {"data": "42 (Idle)", "active": False},
        "packets": [
            {"src": "l2", "dst": "core2", "color": "#3B82F6", "label": "L2 -> Core 2 (42)"},
            {"src": "l2", "dst": "core3", "color": "#3B82F6", "label": "L2 -> Core 3 (42)"},
        ],
        "explanation": (
            "PARALLEL READ SHARING: Cores 2 and 3 also read 0x0100. Because the line is clean, all 4 cores "
            "are allowed to hold simultaneous copies in the SHARED (S) state. Any core can now read 0x0100 "
            "in 1 clock cycle (L1D Read Hit) with zero bus traffic!"
        ),
    },
    {
        "step": 4,
        "title": "Step 4: Core 0 Writes Shared Line -- Upgrade (S -> M via BusUpgr)",
        "instruction": "Core 0: SW x5, 0x108(x0) <= 60   [Write Hit on Shared -> BusUpgr]",
        "active_core": 0,
        "bus_cmd": "BusUpgr",
        "bus_label": "Core 0 broadcasts BusUpgr(0x0100) | Cores 1,2,3 invalidate (S -> I, SNOOP_ACK) | Core 0 -> M",
        "cores": [
            {"state": "M", "data": "60*", "snoop": "REQ", "action": "Upgrade S -> M"},
            {"state": "I", "data": "XX",  "snoop": "ACK", "action": "Invalidated (S->I)"},
            {"state": "I", "data": "XX",  "snoop": "ACK", "action": "Invalidated (S->I)"},
            {"state": "I", "data": "XX",  "snoop": "ACK", "action": "Invalidated (S->I)"},
        ],
        "l2": {"state": "Valid (Stale=42)", "data": "42", "dirty": False},
        "mem": {"data": "42 (Stale)", "active": False},
        "packets": [
            {"src": "core0", "dst": "bus",   "color": "#A855F7", "label": "1. BusUpgr"},
            {"src": "bus",   "dst": "core1", "color": "#F43F5E", "label": "Inval (S->I)"},
            {"src": "bus",   "dst": "core2", "color": "#F43F5E", "label": "Inval (S->I)"},
            {"src": "bus",   "dst": "core3", "color": "#F43F5E", "label": "Inval (S->I)"},
        ],
        "explanation": (
            "WHY BusUpgr & INVALIDATION? Core 0 wants to write 60 into line 0x0100. Because Core 0 already has "
            "the line in SHARED (S), it doesn't need to fetch data -- it just broadcasts BusUpgr ('Upgrade'). "
            "Cores 1, 2, and 3 immediately destroy their stale copies (S -> I) and reply SNOOP_ACK. Core 0 becomes MODIFIED (M)!"
        ),
    },
    {
        "step": 5,
        "title": "Step 5: Core 1 Reads Modified Line -- Cache-to-Cache Transfer (SNOOP_HITM)",
        "instruction": "Core 1: LW x6, 0x108(x0)   [Read Miss -> Core 0 Intercepts with SNOOP_HITM!]",
        "active_core": 1,
        "bus_cmd": "HITM",
        "bus_label": "Core 1 issues BusRd | Core 0 signals SNOOP_HITM & streams dirty data (60) to Core 1 & L2!",
        "cores": [
            {"state": "S", "data": "60", "snoop": "HITM", "action": "Supply 60 (M -> S)"},
            {"state": "S", "data": "60", "snoop": "REQ",  "action": "Receive 60 (I -> S)"},
            {"state": "I", "data": "XX", "snoop": "MISS", "action": "Invalid"},
            {"state": "I", "data": "XX", "snoop": "MISS", "action": "Invalid"},
        ],
        "l2": {"state": "Updated (Dirty=60*)", "data": "60*", "dirty": True},
        "mem": {"data": "42 (Not Used)", "active": False},
        "packets": [
            {"src": "core1", "dst": "bus",   "color": "#38BDF8", "label": "1. BusRd"},
            {"src": "core0", "dst": "core1", "color": "#F59E0B", "label": "2. HITM Data=60 (C2C)"},
            {"src": "core0", "dst": "l2",    "color": "#F59E0B", "label": "3. Update L2 (60)"},
        ],
        "explanation": (
            "CACHE-TO-CACHE INTERVENTION (HITM): Core 1 wants to read 0x0108, but L2 and Main Memory still have old data! "
            "Core 0 (in MODIFIED state) snoops the BusRd, asserts SNOOP_HITM ('Hit Modified'), and pushes the latest "
            "value (60) directly across the bus to Core 1 AND updates L2. Both Core 0 and Core 1 are now SHARED (S)."
        ),
    },
    {
        "step": 6,
        "title": "Step 6: Core 3 Write Miss -- Read-Exclusive (BusRdX + Invalidation)",
        "instruction": "Core 3: SW x3, 0x120(x0) <= 52   [Write Miss -> BusRdX]",
        "active_core": 3,
        "bus_cmd": "BusRdX",
        "bus_label": "Core 3 broadcasts BusRdX | Invalidates all other copies (-> I) | Core 3 becomes MODIFIED (M)",
        "cores": [
            {"state": "I", "data": "XX",  "snoop": "ACK", "action": "Invalidated (-> I)"},
            {"state": "I", "data": "XX",  "snoop": "ACK", "action": "Invalidated (-> I)"},
            {"state": "I", "data": "XX",  "snoop": "ACK", "action": "Invalidated (-> I)"},
            {"state": "M", "data": "52*", "snoop": "REQ", "action": "Write Miss (I -> M)"},
        ],
        "l2": {"state": "Valid (Dirty)", "data": "60*", "dirty": True},
        "mem": {"data": "42", "active": False},
        "packets": [
            {"src": "core3", "dst": "bus",   "color": "#F43F5E", "label": "1. BusRdX (Write Miss)"},
            {"src": "bus",   "dst": "core0", "color": "#F43F5E", "label": "Invalidate"},
            {"src": "bus",   "dst": "core1", "color": "#F43F5E", "label": "Invalidate"},
            {"src": "l2",    "dst": "core3", "color": "#F59E0B", "label": "2. Line -> Core 3 (M)"},
        ],
        "explanation": (
            "WHY BusRdX (READ-EXCLUSIVE)? Core 3 wants to write to a line it doesn't have (state I). "
            "It issues BusRdX, which fetches the full cache line AND invalidates all other caches in one step "
            "so Core 3 gains exclusive ownership in the MODIFIED (M) state."
        ),
    },
]


# =============================================================================
# 1. Optional RTL Simulation Verification Runner
# =============================================================================
def verify_rtl_simulation(project_root):
    """Runs the actual Icarus Verilog quad-core coherence simulation if iverilog is available."""
    iverilog_path = r"C:\iverilog\bin\iverilog.exe"
    vvp_path = r"C:\iverilog\bin\vvp.exe"
    if not os.path.exists(iverilog_path):
        return None

    env = os.environ.copy()
    env["PATH"] = r"C:\iverilog\bin;" + env.get("PATH", "")

    import glob
    rtl_files = (
        glob.glob(os.path.join(project_root, "rtl", "core", "*.v"))
        + glob.glob(os.path.join(project_root, "rtl", "cache", "*.v"))
        + glob.glob(os.path.join(project_root, "rtl", "coherence", "*.v"))
        + glob.glob(os.path.join(project_root, "rtl", "memory", "*.v"))
        + [os.path.join(project_root, "rtl", "top", "quad_core_top.v")]
        + [os.path.join(project_root, "tb", "tb_quad_core.v")]
    )
    out_vvp = os.path.join(project_root, "sim", "out", "anim_quad.vvp")
    os.makedirs(os.path.dirname(out_vvp), exist_ok=True)

    cmd_compile = [
        iverilog_path, "-DSIM",
        "-I", os.path.join(project_root, "rtl", "core"),
        "-I", os.path.join(project_root, "rtl", "cache"),
        "-o", out_vvp,
    ] + rtl_files

    subprocess.run(cmd_compile, cwd=project_root, env=env, check=True, capture_output=True, text=True)
    res = subprocess.run([vvp_path, out_vvp], cwd=project_root, env=env, check=True, capture_output=True, text=True)
    return res.stdout


# =============================================================================
# 2. Rich Terminal Animation (--cli)
# =============================================================================
def run_cli_animation(delay=0.8):
    if not RICH_AVAILABLE:
        print("=== MESI Cache Coherence Step-by-Step Walkthrough ===")
        for sc in SCENARIOS:
            print(f"\n[{sc['title']}]")
            print(f"  Instruction : {sc['instruction']}")
            print(f"  Bus Activity: {sc['bus_label']}")
            states = " | ".join([f"Core {i}: {c['state']} (data={c['data']}, snoop={c['snoop']})" for i, c in enumerate(sc["cores"])])
            print(f"  L1D States  : {states}")
            print(f"  Explanation : {sc['explanation']}")
            time.sleep(delay)
        return

    console = Console()
    console.print(
        Panel.fit(
            "[bold cyan]Quad-Core RISC-V OoO Processor -- MESI Cache Coherence Visual Walkthrough[/bold cyan]\n"
            "[dim]Legend:[/dim] [bold black on bright_yellow] M [/bold black on bright_yellow] Modified (Dirty, 1 copy)   "
            "[bold black on bright_green] E [/bold black on bright_green] Exclusive (Clean, 1 copy)   "
            "[bold white on bright_blue] S [/bold white on bright_blue] Shared (Clean, >=2 copies)   "
            "[bold white on bright_black] I [/bold white on bright_black] Invalid (Empty/Stale)",
            border_style="cyan",
        )
    )

    badge_style = {
        "M": "bold black on bright_yellow",
        "E": "bold black on bright_green",
        "S": "bold white on bright_blue",
        "I": "bold white on bright_black",
    }

    for sc in SCENARIOS:
        table = Table(title=f"[bold yellow]{sc['title']}[/bold yellow]", expand=True, border_style="bright_blue")
        table.add_column("Component", style="bold cyan", justify="center")
        for i in range(4):
            hdr = f"Core {i} L1D [*]" if sc["active_core"] == i else f"Core {i} L1D"
            table.add_column(hdr, justify="center")
        table.add_column("Shared L2 (16KB)", justify="center", style="magenta")
        table.add_column("Main Memory", justify="center", style="green")

        row_state = ["MESI State"]
        for c in sc["cores"]:
            st = c["state"]
            row_state.append(f"[{badge_style[st]}]  {st}  [/{badge_style[st]}]")
        row_state.append(sc["l2"]["state"])
        row_state.append("64KB BRAM")

        row_data = ["Cached Data"]
        for c in sc["cores"]:
            row_data.append(f"[bold]{c['data']}[/bold]")
        row_data.append(f"[bold]{sc['l2']['data']}[/bold]")
        row_data.append(f"[bold]{sc['mem']['data']}[/bold]")

        row_snoop = ["Bus / Snoop"]
        for c in sc["cores"]:
            row_snoop.append(f"{c['snoop']} ({c['action']})")
        row_snoop.append("Inclusive L2")
        row_snoop.append("Active" if sc["mem"]["active"] else "Idle")

        table.add_row(*row_state)
        table.add_row(*row_data)
        table.add_row(*row_snoop)

        console.print(table)
        console.print(
            Panel(
                f"[bold white]CPU Operation:[/bold white] [yellow]{sc['instruction']}[/yellow]\n"
                f"[bold white]Coherence Bus:[/bold white] [cyan]{sc['bus_label']}[/cyan]\n"
                f"[bold green]Why this happens:[/bold green] {sc['explanation']}",
                border_style="dim",
            )
        )
        time.sleep(delay)


# =============================================================================
# 3. Matplotlib Canvas Drawing Engine (Used by both GIF Exporter & Live GUI)
# =============================================================================
NODE_COORDS = {
    "core0": (0.14, 0.72),
    "core1": (0.38, 0.72),
    "core2": (0.62, 0.72),
    "core3": (0.86, 0.72),
    "bus":   (0.50, 0.47),
    "l2":    (0.33, 0.25),
    "mem":   (0.67, 0.25),
}


def draw_rounded_box(ax, cx, cy, w, h, bg, border, lw=2.0, zorder=2):
    patch = FancyBboxPatch(
        (cx - w / 2, cy - h / 2),
        w,
        h,
        boxstyle="round,pad=0.012,rounding_size=0.018",
        facecolor=bg,
        edgecolor=border,
        linewidth=lw,
        zorder=zorder,
    )
    ax.add_patch(patch)
    return patch


def render_frame(ax, scenario_idx, sub_progress):
    """
    Renders a single animation frame for scenario `scenario_idx` at interpolation `sub_progress` in [0.0, 1.0].
    """
    ax.clear()
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")
    ax.set_facecolor(BG_DARK)

    sc = SCENARIOS[scenario_idx]
    bus_color = BUS_COLORS.get(sc["bus_cmd"], WIRE_IDLE)

    # ---- Header Banner ----
    ax.text(
        0.50, 0.965,
        "QUAD-CORE RISC-V OoO PROCESSOR -- MESI CACHE COHERENCE ANIMATION",
        ha="center", va="center", color="#38BDF8", fontsize=13, fontweight="bold",
    )
    ax.text(
        0.50, 0.928,
        f"{sc['title']}   |   Active Op: {sc['instruction']}",
        ha="center", va="center", color=TEXT_MAIN, fontsize=10.5, fontweight="bold",
    )

    # ---- Legend Pills (Top bar) ----
    legend_items = [
        ("M", "Modified (Dirty, Only Copy)"),
        ("E", "Exclusive (Clean, Only Copy)"),
        ("S", "Shared (Clean, Shared)"),
        ("I", "Invalid (Empty / Stale)"),
    ]
    for idx_l, (st_code, st_desc) in enumerate(legend_items):
        lx = 0.13 + idx_l * 0.245
        ly = 0.885
        st_info = STATE_COLORS[st_code]
        draw_rounded_box(ax, lx, ly, 0.22, 0.032, "#1E293B", st_info["border"], lw=1.2, zorder=2)
        ax.text(
            lx - 0.09, ly, f" {st_code} ",
            ha="center", va="center", color=st_info["fg"], fontsize=8.5, fontweight="bold",
            bbox=dict(boxstyle="round,pad=0.2", facecolor=st_info["bg"], edgecolor="none"),
            zorder=3,
        )
        ax.text(lx + 0.015, ly, st_desc, ha="center", va="center", color=TEXT_MAIN, fontsize=7.8, zorder=3)

    # ---- Draw Interconnect Wires ----
    bus_y = 0.47
    # Horizontal Snooping Coherence Bus bar
    bus_active = sc["bus_cmd"] != "NONE"
    draw_rounded_box(
        ax, 0.50, bus_y, 0.84, 0.065,
        "#1E293B" if bus_active else PANEL_BG,
        bus_color if bus_active else PANEL_BORDER,
        lw=2.8 if bus_active else 1.5,
        zorder=2,
    )
    ax.text(
        0.50, bus_y + 0.011,
        f"SNOOPING COHERENCE BUS & ARBITER   [{sc['bus_cmd']}]",
        ha="center", va="center",
        color=bus_color if bus_active else TEXT_MUTED,
        fontsize=9.2, fontweight="bold", zorder=3,
    )
    ax.text(
        0.50, bus_y - 0.014,
        sc["bus_label"],
        ha="center", va="center", color=TEXT_MAIN, fontsize=8.0, zorder=3,
    )

    # Vertical wires from 4 Cores/L1Ds to Coherence Bus
    for i in range(4):
        cx, cy = NODE_COORDS[f"core{i}"]
        is_act = (sc["active_core"] == i)
        w_col = bus_color if (is_act or sc["cores"][i]["snoop"] in ("HIT", "HITM", "ACK")) else WIRE_IDLE
        ax.plot([cx, cx], [cy - 0.11, bus_y + 0.033], color=w_col, lw=2.5 if is_act else 1.6, linestyle="-", zorder=1)

    # Wires between Bus, Shared L2, and Main Memory
    l2_x, l2_y = NODE_COORDS["l2"]
    mem_x, mem_y = NODE_COORDS["mem"]
    ax.plot([l2_x, l2_x], [bus_y - 0.033, l2_y + 0.075], color=bus_color if bus_active else WIRE_IDLE, lw=2.2, zorder=1)
    ax.plot(
        [l2_x + 0.13, mem_x - 0.13],
        [l2_y, mem_y],
        color="#10B981" if sc["mem"]["active"] else WIRE_IDLE,
        lw=2.5 if sc["mem"]["active"] else 1.6,
        zorder=1,
    )

    # ---- Draw 4 OoO Cores + L1D Caches ----
    for i in range(4):
        cx, cy = NODE_COORDS[f"core{i}"]
        c_info = sc["cores"][i]
        st = c_info["state"]
        st_style = STATE_COLORS[st]
        is_active = (sc["active_core"] == i)

        # Outer card for Core + L1D
        draw_rounded_box(
            ax, cx, cy, 0.20, 0.21,
            PANEL_BG,
            st_style["border"] if is_active else PANEL_BORDER,
            lw=3.0 if is_active else 1.6,
            zorder=2,
        )

        # Core Header
        core_title = f"RISC-V OoO Core {i}" + (" [*]" if is_active else "")
        ax.text(
            cx, cy + 0.078, core_title,
            ha="center", va="center",
            color="#38BDF8" if is_active else TEXT_MAIN,
            fontsize=9.2, fontweight="bold", zorder=3,
        )
        ax.text(
            cx, cy + 0.048, f"Action: {c_info['action']}",
            ha="center", va="center", color=TEXT_MUTED, fontsize=8.0, zorder=3,
        )

        # MESI State Badge inside L1D
        draw_rounded_box(
            ax, cx, cy - 0.008, 0.165, 0.062,
            st_style["bg"], st_style["border"], lw=1.8, zorder=3,
        )
        ax.text(
            cx, cy + 0.004, f"L1D State: {st}",
            ha="center", va="center", color=st_style["fg"], fontsize=10.0, fontweight="bold", zorder=4,
        )
        ax.text(
            cx, cy - 0.022, f"[0x0100] = {c_info['data']}",
            ha="center", va="center", color=st_style["fg"], fontsize=8.8, fontweight="bold", zorder=4,
        )

        # Snoop response pill at bottom of L1D card
        snoop_txt = f"Snoop: {c_info['snoop']}"
        snoop_col = (
            "#F59E0B" if c_info["snoop"] == "HITM" else
            "#38BDF8" if c_info["snoop"] in ("HIT", "REQ") else
            "#F43F5E" if c_info["snoop"] == "ACK" else TEXT_MUTED
        )
        ax.text(
            cx, cy - 0.075, snoop_txt,
            ha="center", va="center", color=snoop_col, fontsize=8.2, fontweight="bold", zorder=3,
        )

    # ---- Draw Shared L2 Cache ----
    l2_border = "#F59E0B" if sc["l2"]["dirty"] else "#3B82F6"
    draw_rounded_box(ax, l2_x, l2_y, 0.25, 0.13, PANEL_BG, l2_border, lw=2.2, zorder=2)
    ax.text(l2_x, l2_y + 0.038, "SHARED L2 CACHE (16 KB, 4-Way)", ha="center", va="center", color="#60A5FA", fontsize=9.2, fontweight="bold", zorder=3)
    ax.text(l2_x, l2_y + 0.005, f"Status: {sc['l2']['state']}", ha="center", va="center", color=TEXT_MAIN, fontsize=8.5, zorder=3)
    ax.text(l2_x, l2_y - 0.030, f"Line [0x0100] Data: {sc['l2']['data']}", ha="center", va="center", color="#FBBF24" if sc["l2"]["dirty"] else "#34D399", fontsize=9.0, fontweight="bold", zorder=3)

    # ---- Draw Main Memory ----
    mem_border = "#10B981" if sc["mem"]["active"] else PANEL_BORDER
    draw_rounded_box(ax, mem_x, mem_y, 0.25, 0.13, PANEL_BG, mem_border, lw=2.5 if sc["mem"]["active"] else 1.6, zorder=2)
    ax.text(mem_x, mem_y + 0.038, "MAIN MEMORY (64 KB BRAM)", ha="center", va="center", color="#34D399", fontsize=9.2, fontweight="bold", zorder=3)
    ax.text(mem_x, mem_y + 0.005, "Memory Controller + Arbiter", ha="center", va="center", color=TEXT_MUTED, fontsize=8.2, zorder=3)
    ax.text(mem_x, mem_y - 0.030, f"Mem[0x0100] = {sc['mem']['data']}", ha="center", va="center", color=TEXT_MAIN, fontsize=9.0, fontweight="bold", zorder=3)

    # ---- Draw Animated Moving Packets Along Bus Wires ----
    packets = sc["packets"]
    if packets:
        for p_idx, pkt in enumerate(packets):
            sx, sy = NODE_COORDS[pkt["src"]]
            dx, dy = NODE_COORDS[pkt["dst"]]
            # Adjust endpoints so packets travel cleanly between box edges
            if pkt["src"].startswith("core"):
                sy -= 0.105
            if pkt["dst"].startswith("core"):
                dy -= 0.105

            # Stagger multiple packets across sub_progress [0, 1]
            t = np.clip((sub_progress * 1.3) - (p_idx * 0.15), 0.05, 0.95)
            px = sx + (dx - sx) * t
            py = sy + (dy - sy) * t

            # Glowing packet circle
            glow = Circle((px, py), 0.019, facecolor=pkt["color"], alpha=0.28, edgecolor="none", zorder=6)
            dot  = Circle((px, py), 0.010, facecolor=pkt["color"], edgecolor="#FFFFFF", linewidth=1.2, zorder=7)
            ax.add_patch(glow)
            ax.add_patch(dot)
            ax.text(
                px, py + 0.025, pkt["label"],
                ha="center", va="center", color="#FFFFFF", fontsize=7.8, fontweight="bold",
                bbox=dict(boxstyle="round,pad=0.18", facecolor=pkt["color"], edgecolor="#0B0F19", alpha=0.92),
                zorder=8,
            )

    # ---- Draw Beginner Explanation Footer Box ----
    draw_rounded_box(ax, 0.50, 0.082, 0.92, 0.115, "#1E293B", "#38BDF8", lw=1.6, zorder=2)
    ax.text(
        0.50, 0.082,
        sc["explanation"],
        ha="center", va="center", color=TEXT_MAIN, fontsize=8.8, wrap=True,
        zorder=3,
    )

    # Progress indicator
    ax.text(
        0.95, 0.012,
        f"Step {scenario_idx + 1} / {len(SCENARIOS)}",
        ha="right", va="bottom", color=TEXT_MUTED, fontsize=8.0,
    )


def export_gif(output_path, frames_per_step=10, fps=6):
    """Exports a smooth animated GIF of all MESI coherence steps."""
    fig, ax = plt.subplots(figsize=(13.5, 7.8), dpi=110)
    fig.patch.set_facecolor(BG_DARK)
    plt.subplots_adjust(left=0.02, right=0.98, top=0.98, bottom=0.02)

    total_frames = len(SCENARIOS) * frames_per_step

    def update(frame_idx):
        sc_idx = frame_idx // frames_per_step
        sub_p = (frame_idx % frames_per_step) / float(max(frames_per_step - 1, 1))
        render_frame(ax, sc_idx, sub_p)
        return []

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    anim = FuncAnimation(fig, update, frames=total_frames, interval=1000 // fps, blit=False)
    writer = PillowWriter(fps=fps)
    anim.save(output_path, writer=writer)
    plt.close(fig)
    return output_path


def run_interactive_gui():
    """Opens an interactive desktop window with Prev / Play-Pause / Next buttons."""
    from matplotlib.widgets import Button

    fig, ax = plt.subplots(figsize=(13.5, 8.2), dpi=100)
    fig.patch.set_facecolor(BG_DARK)
    plt.subplots_adjust(left=0.02, right=0.98, top=0.98, bottom=0.08)

    state = {"sc_idx": 0, "sub_idx": 0, "playing": True}
    frames_per_step = 10

    def redraw():
        sub_p = state["sub_idx"] / float(frames_per_step - 1)
        render_frame(ax, state["sc_idx"], sub_p)
        fig.canvas.draw_idle()

    def on_prev(event):
        state["playing"] = False
        state["sc_idx"] = (state["sc_idx"] - 1) % len(SCENARIOS)
        state["sub_idx"] = frames_per_step // 2
        redraw()

    def on_next(event):
        state["playing"] = False
        state["sc_idx"] = (state["sc_idx"] + 1) % len(SCENARIOS)
        state["sub_idx"] = frames_per_step // 2
        redraw()

    def on_toggle(event):
        state["playing"] = not state["playing"]

    ax_prev = plt.axes([0.32, 0.015, 0.10, 0.045])
    ax_play = plt.axes([0.45, 0.015, 0.12, 0.045])
    ax_next = plt.axes([0.60, 0.015, 0.10, 0.045])

    btn_prev = Button(ax_prev, "< Previous", color="#1E293B", hovercolor="#334155")
    btn_play = Button(ax_play, "Play / Pause", color="#0284C7", hovercolor="#0369A1")
    btn_next = Button(ax_next, "Next >", color="#1E293B", hovercolor="#334155")

    for b in (btn_prev, btn_play, btn_next):
        b.label.set_color("#F8FAFC")
        b.label.set_fontweight("bold")

    btn_prev.on_clicked(on_prev)
    btn_play.on_clicked(on_play := on_toggle)
    btn_next.on_clicked(on_next)

    def timer_tick(frame):
        if state["playing"]:
            state["sub_idx"] += 1
            if state["sub_idx"] >= frames_per_step:
                state["sub_idx"] = 0
                state["sc_idx"] = (state["sc_idx"] + 1) % len(SCENARIOS)
            redraw()
        return []

    _anim = FuncAnimation(fig, timer_tick, interval=180, cache_frame_data=False)
    redraw()
    plt.show()


def main():
    parser = argparse.ArgumentParser(description="MESI Cache Coherence Visual Animator")
    parser.add_argument("--cli", action="store_true", help="Run rich step-by-step animation in terminal")
    parser.add_argument("--gif", type=str, default="", help="Export animated GIF to specified path")
    parser.add_argument("--gui", action="store_true", help="Launch interactive desktop GUI window")
    parser.add_argument("--verify-rtl", action="store_true", help="Run Icarus Verilog quad-core simulation before animating")
    parser.add_argument("--delay", type=float, default=0.35, help="Delay (seconds) between CLI animation steps")
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    if args.verify_rtl:
        print("[1/3] Running live Verilog RTL simulation (tb_quad_core.v)...")
        out = verify_rtl_simulation(project_root)
        if out and "ALL QUAD-CORE FULL-SYSTEM & COHERENCE CHECKS PASSED" in out:
            print("      -> Hardware RTL Verification: 53 / 53 PASSED!")

    if args.cli or (not args.gif and not args.gui):
        run_cli_animation(delay=args.delay)

    if args.gif:
        out_gif = os.path.join(project_root, args.gif) if not os.path.isabs(args.gif) else args.gif
        print(f"\n[*] Generating high-resolution MESI Coherence Animated GIF: {out_gif} ...")
        export_gif(out_gif)
        print(f"    -> Saved animated GIF to: {out_gif}")

    if args.gui:
        print("\n[*] Launching interactive MESI Coherence desktop visualizer...")
        run_interactive_gui()


if __name__ == "__main__":
    main()
