#!/usr/bin/env python3
"""Summarise a Yosys synth_xilinx log against the Nexys A7-100T (XC7A100T).
Usage: fpga_report.py synth.log
Yosys counts are an estimate: Vivado usually needs fewer LUTs."""
import re, sys

CAP = {"LUT": 63400, "FF": 126800, "BRAM36": 135, "DSP": 240}
LUTRAM_LUTS = {"RAM64M": 4, "RAM32M": 4, "RAM128X1D": 4, "RAM64X1D": 2, "RAM32X1D": 2,
               "RAM256X1S": 4, "RAM128X1S": 2, "RAM64X1S": 1, "RAM32X1S": 1,
               "SRL16E": 1, "SRLC32E": 1}

text = open(sys.argv[1]).read()
# The last statistics block is the whole design (hierarchy totals)
blk = text[text.rfind("=== design hierarchy ==="):] if "=== design hierarchy ===" in text else text[text.rfind("Printing statistics"):]
cells = {}
for name, n in re.findall(r"^\s+([A-Z][A-Z0-9_]+)\s+(\d+)\s*$", blk, re.M):
    cells[name] = cells.get(name, 0) + int(n)

logic = sum(v for k, v in cells.items() if re.fullmatch(r"LUT[1-6]", k))
lutram = sum(cells.get(k, 0) * w for k, w in LUTRAM_LUTS.items())
ff = sum(v for k, v in cells.items() if re.fullmatch(r"FD[CPRS]E?", k))
bram = cells.get("RAMB36E1", 0) + cells.get("RAMB18E1", 0) / 2
dsp = cells.get("DSP48E1", 0)
rows = [("LUT (logic + LUT RAM)", logic + lutram, CAP["LUT"]),
        ("  of which LUT RAM", lutram, None),
        ("Flip-flops", ff, CAP["FF"]),
        ("Block RAM (36 Kb)", bram, CAP["BRAM36"]),
        ("DSP48", dsp, CAP["DSP"])]
print(f"{'Resource':24s} {'Used':>9s} {'XC7A100T':>9s} {'Use':>6s}")
for name, used, cap in rows:
    pct = f"{100 * used / cap:5.1f}%" if cap else ""
    print(f"{name:24s} {used:>9g} {cap if cap else '':>9} {pct:>6s}")
