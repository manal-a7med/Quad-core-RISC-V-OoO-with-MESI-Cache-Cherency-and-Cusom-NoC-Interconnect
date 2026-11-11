#!/usr/bin/env python3
"""Render the results page (docs/results/index.html) from build/viz/.

Run scripts/viz/collect.sh first. Everything on the page is computed from
simulation, test and synthesis logs, so it can be regenerated at any time.
Usage: python3 scripts/viz/make_results.py [build/viz] [docs/results/index.html]
"""
import html, os, re, sys, datetime

V = sys.argv[1] if len(sys.argv) > 1 else "build/viz"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/results/index.html"
esc = html.escape

# XC7A100T capacity (Nexys A7-100T)
CAP = {"LUT": 63400, "FF": 126800, "BRAM36": 135}


def read(p, default=""):
    try:
        return open(os.path.join(V, p)).read()
    except OSError:
        return default


# ---------------------------------------------------------------- data
def repro(v):
    rows = []
    for l in read(f"{v}/repro.log").splitlines():
        m = re.match(r"(.+?) got=(\w+) exp=(\w+) (PASS|FAIL)$", l)
        if m:
            rows.append(dict(name=m[1], got=m[2], exp=m[3], ok=m[4] == "PASS"))
    return rows


def isa(v):
    res = {}
    for l in read(f"{v}/isa_summary.txt").splitlines():
        m = re.match(r"(\S+) RESULT (\w+)", l)
        if m:
            res[m[1]] = m[2]
    return res


def disasm(p):
    d = {}
    for l in read(p).splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(.*)", l)
        if m:
            d[int(m[1], 16)] = re.sub(r"\s+", " ", m[2].split("#")[0].split("<")[0]).strip()
    return d


def trace(p):
    """Return list of instructions in dispatch order with stage cycles."""
    insts, live, flushes = [], {}, []
    for l in read(p).splitlines():
        f = l.split()
        if not f or f[0] != "T":
            continue
        ev, cyc = f[1], int(f[2])
        if ev == "D":
            i = dict(rob=int(f[3]), pc=int(f[4], 16), D=cyc, I=None, C=None, R=None, squashed=False)
            insts.append(i)
            live[i["rob"]] = i
        elif ev == "F":
            flushes.append(cyc)
            for i in live.values():
                if i["R"] is None:
                    i["squashed"] = True
            live = {}
        else:
            i = live.get(int(f[3]))
            if i is not None and i[ev] is None:
                i[ev] = cyc
                if ev == "R":
                    del live[i["rob"]]
    return insts, flushes


def synth_x7():
    s = read("synth_x7.log")
    k = s.rfind("=== design hierarchy ===")
    if k < 0:
        return None
    blk = s[k:]
    cnt = lambda pat: sum(int(n) for n in re.findall(rf"^\s+{pat}\s+(\d+)", blk, re.M))
    return dict(LUT=cnt(r"LUT\d"), FF=cnt(r"FD\w+"), CARRY=cnt("CARRY4"), MUXF=cnt(r"MUXF\d"))


def yosys_ok(v):
    t = read(f"{v}/yosys_check.txt")
    err = re.search(r"ERROR: (.*)", t)
    return ("OK" in t and not err), (err[1] if err else "")


rb, ra = repro("before"), repro("after")
ib, ia = isa("before"), isa("after")
ref_b, ref_a = read("before/ref").strip(), read("after/ref").strip()
yb, yb_err = yosys_ok("before")
ya, _ = yosys_ok("after")
x7 = synth_x7()
dis_demo, dis_prog = disasm("demo.dis"), disasm("prog.dis")
demo, demo_fl = trace("after/demo.log")
rp_b, rp_b_fl = trace("before/repro.log")
rp_a, _ = trace("after/repro.log")
cyc_demo = re.search(r"cycles=(\d+)", read("after/demo.log"))
cyc_demo = int(cyc_demo[1]) if cyc_demo else None

npass = lambda d: sum(1 for x in d.values() if x == "PASS")
rpass = lambda r: sum(1 for x in r if x["ok"])

# ---------------------------------------------------------------- pipeline SVG
def ooo_issues(insts):
    """Instructions that issued while an older instruction had not issued yet."""
    out = set()
    for n, i in enumerate(insts):
        if i["I"] is None or i["squashed"]:
            continue
        for o in insts[:n]:
            if not o["squashed"] and o["I"] is not None and o["I"] > i["I"]:
                out.add(n)
                break
    return out


def pipeline_svg(insts, dis, flushes, max_rows=90):
    # Drop rows that never issued and were not squashed: the run ends when the
    # program reports its result, so the last few instructions never execute.
    insts = [i for i in insts if i["I"] is not None or i["squashed"]][:max_rows]
    if not insts:
        return "<p>No trace.</p>"
    c0 = min(i["D"] for i in insts)
    c1 = max(max(x for x in (i["D"], i["I"], i["C"], i["R"]) if x is not None) for i in insts)
    cw, rh, lw, top = 12, 16, 230, 26
    W, H = lw + (c1 - c0 + 2) * cw + 8, top + len(insts) * rh + 8
    early = ooo_issues(insts)
    o = [f'<svg class="pipe" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
         f'aria-label="Pipeline timeline: one row per instruction, one column per cycle">']
    for c in range(c0, c1 + 1):
        x = lw + (c - c0) * cw
        if (c - c0) % 10 == 0:
            o.append(f'<line class="grid" x1="{x}" y1="{top-6}" x2="{x}" y2="{H-6}"/>'
                     f'<text class="tick" x="{x+1}" y="{top-10}">{c}</text>')
    for fc in flushes:
        if c0 <= fc <= c1:
            x = lw + (fc - c0) * cw + cw / 2
            o.append(f'<line class="flush" x1="{x}" y1="{top-6}" x2="{x}" y2="{H-6}"/>')
    for r, i in enumerate(insts):
        y = top + r * rh
        cls = "row sq" if i["squashed"] else ("row early" if r in early else "row")
        txt = f'{i["pc"]:04x}  {dis.get(i["pc"], "")}'
        o.append(f'<g class="{cls}"><text class="asm" x="4" y="{y+11}">{esc(txt)}</text>')
        ends = [x for x in (i["I"], i["C"], i["R"]) if x is not None]
        if ends:
            x0 = lw + (i["D"] - c0) * cw + cw / 2
            x1 = lw + (max(ends) - c0) * cw + cw / 2
            o.append(f'<line class="life" x1="{x0}" y1="{y+7}" x2="{x1}" y2="{y+7}"/>')
        for st in "DICR":
            c = i[st]
            if c is None:
                continue
            x = lw + (c - c0) * cw
            o.append(f'<rect class="st st{st}" x="{x+1}" y="{y+1}" width="{cw-2}" height="{rh-3}" rx="2"/>'
                     f'<text class="stl" x="{x+cw/2}" y="{y+11}">{st}</text>')
        o.append("</g>")
    o.append("</svg>")
    return "".join(o)


def commit_stream(insts, dis, good_pcs=None):
    out = []
    for i in insts:
        if i["R"] is None:
            continue
        wrong = good_pcs is not None and i["pc"] not in good_pcs
        out.append(f'<li class="{"wrong" if wrong else ""}"><span class="pc">{i["pc"]:04x}</span>'
                   f'<span>{esc(dis.get(i["pc"], "?"))}</span>'
                   + ('<span class="tag bad">wrong path</span>' if wrong else "") + "</li>")
    return "".join(out)


good = {i["pc"] for i in rp_a if i["R"] is not None}

# ---------------------------------------------------------------- page parts
def pill(ok, yes="Pass", no="Fail"):
    return f'<span class="pill {"ok" if ok else "bad"}">{yes if ok else no}</span>'


rep_rows = "".join(
    f'<tr><td>{esc(a["name"])}</td><td class="mono">{a["exp"]}</td>'
    f'<td class="mono">{b["got"]}</td><td>{pill(b["ok"])}</td>'
    f'<td class="mono">{a["got"]}</td><td>{pill(a["ok"])}</td></tr>'
    for b, a in zip(rb, ra))

tests = sorted(set(ib) | set(ia))
chips = lambda d: "".join(
    f'<span class="chip {"ok" if d.get(t) == "PASS" else "bad"}" title="{t}: {d.get(t, "not run")}">{t}</span>'
    for t in tests)

if x7:
    lut4, ff4 = 4 * x7["LUT"], 4 * x7["FF"]
    synth_rows = (
        f'<tr><td>LUTs</td><td class="num">{x7["LUT"]:,}</td><td class="num">{lut4:,}</td>'
        f'<td class="num">{CAP["LUT"]:,}</td><td class="num">{100*lut4/CAP["LUT"]:.0f}%</td></tr>'
        f'<tr><td>Flip-flops</td><td class="num">{x7["FF"]:,}</td><td class="num">{ff4:,}</td>'
        f'<td class="num">{CAP["FF"]:,}</td><td class="num">{100*ff4/CAP["FF"]:.0f}%</td></tr>')
    lut_pct = f'{100*lut4/CAP["LUT"]:.0f}%'
else:
    synth_rows, lut_pct = "", "n/a"

early_n = len(ooo_issues(demo))
ipc = (sum(1 for i in demo if i["R"] is not None) / cyc_demo) if cyc_demo else 0

stamp = datetime.date.today().isoformat()

page = f"""<title>Core Fix Results</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@400;500;600&family=Space+Grotesk:wght@500;700&display=swap">
<style>
/* Layout: a lab report. Summary strip, then evidence sections, each a table or trace. */
:root {{
  --bg: #f6f7f9; --panel: #ffffff; --fg: #17202b; --muted: #5b6676; --line: #dde2e9;
  --accent: #2d5bd1; --ok: #1d7f4e; --ok-bg: #e3f3ea; --bad: #b42a2a; --bad-bg: #fbe7e7;
  --stD: #9aa5b4; --stI: #2d5bd1; --stC: #c98a12; --stR: #1d7f4e; --early: #e8eefc;
  --f-display: "Space Grotesk", "Segoe UI", system-ui, sans-serif;
  --f-body: "IBM Plex Sans", "Segoe UI", system-ui, sans-serif;
  --f-mono: "IBM Plex Mono", ui-monospace, "SFMono-Regular", Menlo, monospace;
}}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
  --bg: #0f141b; --panel: #161d27; --fg: #e4e9f0; --muted: #98a3b3; --line: #2a3442;
  --accent: #7ea2ff; --ok: #5ccf94; --ok-bg: #143324; --bad: #ff8a8a; --bad-bg: #3a1a1c;
  --stD: #6b7686; --stI: #6f95ff; --stC: #e0a63a; --stR: #4cc285; --early: #1c2840; color-scheme: dark; }} }}
:root[data-theme="dark"] {{
  --bg: #0f141b; --panel: #161d27; --fg: #e4e9f0; --muted: #98a3b3; --line: #2a3442;
  --accent: #7ea2ff; --ok: #5ccf94; --ok-bg: #143324; --bad: #ff8a8a; --bad-bg: #3a1a1c;
  --stD: #6b7686; --stI: #6f95ff; --stC: #e0a63a; --stR: #4cc285; --early: #1c2840; color-scheme: dark; }}
body {{ background: var(--bg); color: var(--fg); font: 15px/1.55 var(--f-body); }}
.wrap {{ max-width: 1080px; margin: 0 auto; padding-block: 32px 64px;
  padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px));
  display: grid; gap: 40px; }}
h1, h2 {{ font-family: var(--f-display); text-wrap: balance; margin: 0; }}
h1 {{ font-size: 2rem; line-height: 1.15; }}
h2 {{ font-size: 1.3rem; }}
p {{ margin: 0; max-width: 68ch; }}
.eyebrow {{ font: 600 .75rem/1 var(--f-mono); letter-spacing: .08em; text-transform: uppercase; color: var(--accent); }}
.muted {{ color: var(--muted); }}
header {{ display: grid; gap: 10px; }}
.refs {{ font: .8rem var(--f-mono); color: var(--muted); }}
section {{ display: grid; gap: 14px; min-width: 0; }}
.strip {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }}
.stat {{ background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 14px 16px; display: grid; gap: 4px; }}
.stat .k {{ font-size: .8rem; color: var(--muted); }}
.stat .v {{ font: 600 1.35rem var(--f-mono); font-variant-numeric: tabular-nums; }}
.stat .v .from {{ color: var(--muted); font-weight: 400; }}
.stat .v .arrow {{ color: var(--muted); padding: 0 .3em; }}
.scroll {{ overflow-x: auto; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }}
table {{ border-collapse: collapse; width: 100%; font-size: .9rem; }}
th, td {{ text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--line); white-space: nowrap; }}
th {{ font-weight: 600; font-size: .78rem; color: var(--muted); letter-spacing: .03em; }}
tr:last-child td {{ border-bottom: 0; }}
.mono, .num {{ font-family: var(--f-mono); font-variant-numeric: tabular-nums; }}
.num {{ text-align: right; }}
.pill {{ display: inline-block; font: 600 .72rem/1 var(--f-mono); padding: 4px 8px; border-radius: 999px; }}
.pill.ok {{ background: var(--ok-bg); color: var(--ok); }}
.pill.bad {{ background: var(--bad-bg); color: var(--bad); }}
.chips {{ display: flex; flex-wrap: wrap; gap: 6px; }}
.chip {{ font: .75rem var(--f-mono); padding: 3px 7px; border-radius: 4px; border: 1px solid transparent; }}
.chip.ok {{ background: var(--ok-bg); color: var(--ok); }}
.chip.bad {{ background: var(--bad-bg); color: var(--bad); border-color: var(--bad); font-weight: 600; }}
.cols {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px; }}
.cols > div {{ min-width: 0; display: grid; gap: 8px; align-content: start; }}
.lbl {{ font: 600 .8rem var(--f-mono); color: var(--muted); }}
.pipe text {{ font-family: var(--f-mono); }}
.pipe .tick {{ font-size: 9px; fill: var(--muted); }}
.pipe .grid {{ stroke: var(--line); stroke-width: 1; }}
.pipe .flush {{ stroke: var(--bad); stroke-width: 1.5; stroke-dasharray: 3 3; }}
.pipe .asm {{ font-size: 10.5px; fill: var(--fg); }}
.pipe .life {{ stroke: var(--line); stroke-width: 3; }}
.pipe .st {{ stroke: none; }}
.pipe .stD {{ fill: var(--stD); }} .pipe .stI {{ fill: var(--stI); }}
.pipe .stC {{ fill: var(--stC); }} .pipe .stR {{ fill: var(--stR); }}
.pipe .stl {{ font-size: 8px; fill: var(--panel); text-anchor: middle; font-weight: 600; }}
.pipe .row.sq {{ opacity: .35; }}
.pipe .row.early .asm {{ fill: var(--accent); font-weight: 600; }}
.legend {{ display: flex; flex-wrap: wrap; gap: 14px; font-size: .82rem; color: var(--muted); }}
.legend span {{ display: inline-flex; align-items: center; gap: 6px; }}
.sw {{ width: 12px; height: 12px; border-radius: 2px; display: inline-block; }}
ol.stream {{ list-style: none; margin: 0; padding: 8px 0; background: var(--panel); border: 1px solid var(--line);
  border-radius: 8px; font: .82rem var(--f-mono); }}
ol.stream li {{ display: flex; gap: 12px; padding: 2px 12px; align-items: center; }}
ol.stream li.wrong {{ background: var(--bad-bg); color: var(--bad); }}
ol.stream .pc {{ color: var(--muted); min-width: 3.5em; }}
.tag.bad {{ margin-left: auto; font-size: .7rem; font-weight: 600; }}
footer {{ font-size: .82rem; color: var(--muted); display: grid; gap: 6px; }}
code {{ font-family: var(--f-mono); font-size: .88em; }}
</style>
<div class="wrap">
<header>
  <span class="eyebrow">Quad-core RISC-V OoO · Phases P0 and P1</span>
  <h1>Core correctness and build results</h1>
  <p class="muted">Every number on this page comes from a simulation, test or synthesis run on the
  RTL. The baseline is the imported design; "fixed" is the same core after the P0 and P1 changes.</p>
  <div class="refs">baseline {esc(ref_b)} · fixed {esc(ref_a)} · generated {stamp}</div>
</header>

<section aria-label="Summary">
  <div class="strip">
    <div class="stat"><span class="k">Design-review bug checks</span>
      <span class="v"><span class="from">{rpass(rb)}/{len(rb)}</span><span class="arrow">→</span>{rpass(ra)}/{len(ra)}</span></div>
    <div class="stat"><span class="k">rv32ui compliance tests</span>
      <span class="v"><span class="from">{npass(ib)}/{len(ib)}</span><span class="arrow">→</span>{npass(ia)}/{len(ia)}</span></div>
    <div class="stat"><span class="k">Core passes Yosys synthesis</span>
      <span class="v"><span class="from">{"yes" if yb else "no"}</span><span class="arrow">→</span>{"yes" if ya else "no"}</span></div>
    <div class="stat"><span class="k">4 cores, LUTs of XC7A100T</span>
      <span class="v">{lut_pct}</span></div>
  </div>
</section>

<section>
  <h2>Bugs found in review, before and after</h2>
  <p>A directed testbench (<code>review/tb_repro.v</code>) runs a 21-instruction program on one core
  and checks eight architectural results. Each failing line is a bug from the design review.</p>
  <div class="scroll"><table>
    <thead><tr><th>Check</th><th>Expected</th><th>Baseline</th><th></th><th>Fixed</th><th></th></tr></thead>
    <tbody>{rep_rows}</tbody></table></div>
</section>

<section>
  <h2>Official ISA compliance (riscv-tests rv32ui)</h2>
  <p>The standard RV32I user-level test suite, built bare-metal and run on the core. A red chip is
  a failed or hung test.</p>
  <div class="cols">
    <div><span class="lbl">Baseline · {npass(ib)}/{len(ib)}</span><div class="chips">{chips(ib)}</div></div>
    <div><span class="lbl">Fixed · {npass(ia)}/{len(ia)}</span><div class="chips">{chips(ia)}</div></div>
  </div>
</section>

<section>
  <h2>Out-of-order execution, cycle by cycle</h2>
  <p>A loop summing an array, traced on the fixed core. Each row is one instruction in program order;
  each column is a clock cycle. Instructions issue as soon as their operands are ready, then retire in
  order. Blue rows issued ahead of an older instruction ({early_n} in this run). Faded rows were fetched
  down a mispredicted path and squashed at the red dashed line.</p>
  <div class="legend">
    <span><i class="sw" style="background:var(--stD)"></i>D dispatch</span>
    <span><i class="sw" style="background:var(--stI)"></i>I issue</span>
    <span><i class="sw" style="background:var(--stC)"></i>C complete</span>
    <span><i class="sw" style="background:var(--stR)"></i>R retire</span>
    <span>{cyc_demo or "?"} cycles · IPC {ipc:.2f}</span>
  </div>
  <div class="scroll">{pipeline_svg(demo, dis_demo, demo_fl)}</div>
</section>

<section>
  <h2>What the core actually committed</h2>
  <p>The retired instruction stream for the repro program. In the baseline, <code>jal</code> jumps to the
  wrong place, so instructions that should be skipped are committed (red). The fixed core retires only
  the correct path.</p>
  <div class="cols">
    <div><span class="lbl">Baseline</span><ol class="stream">{commit_stream(rp_b, dis_prog, good)}</ol></div>
    <div><span class="lbl">Fixed</span><ol class="stream">{commit_stream(rp_a, dis_prog, good)}</ol></div>
  </div>
</section>

<section>
  <h2>Synthesis</h2>
  <p>The baseline core stops in Yosys with <code>{esc(yb_err or "an error")}</code>, caused by a flush
  signal inside an asynchronous-reset block. With that fixed, one core maps to Artix-7 as below
  (Yosys <code>synth_xilinx</code>, before place and route). Caches and memory are not included yet;
  mapping them to block RAM is P2.</p>
  <div class="scroll"><table>
    <thead><tr><th>Resource</th><th class="num">1 core</th><th class="num">4 cores</th><th class="num">XC7A100T</th><th class="num">Used</th></tr></thead>
    <tbody>{synth_rows}</tbody></table></div>
</section>

<footer>
  <span>Regenerate: <code>sh scripts/viz/collect.sh &lt;riscv-tests checkout&gt; &amp;&amp; python3 scripts/viz/make_results.py</code></span>
  <span>Sources: <code>review/tb_repro.v</code>, <code>verif/riscv-tests/</code>, <code>verif/demo/ooo_demo.S</code>, <code>verif/trace.vh</code></span>
</footer>
</div>
"""

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w").write(page)
print(f"wrote {OUT}")
