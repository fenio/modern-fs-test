#!/usr/bin/env python3
"""Generate the static results dashboard (single self-contained index.html).

Usage: make-dashboard.py --runs <dir> --out <file> [--repo <url>]

<dir> holds one subdirectory per benchmark run, each containing the
result-<fs>-<layout>.json files produced by run-bench.sh. Files directly in
<dir> are treated as a single run.
"""

import argparse
import glob
import json
import os
import sys

# Composite encoding: hue follows the filesystem FAMILY (a fixed categorical
# slot per family, never cycled), and the variant within a family is carried
# by line style (solid / dashed / dotted) plus labels and tooltips. Slots are
# pinned explicitly — color follows the family forever (bcachefs=yellow was
# chosen over green, which read too close to xfs's aqua).
FAMILY_SLOT = {"ext4": 0, "xfs": 1, "zfs": 2, "btrfs": 3, "bcachefs": 4}
ENTITY_ORDER = [
    "ext4/single",
    "ext4/md-raid10",
    "ext4/lvm-raid10",
    "xfs/single",
    "xfs/md-raid10",
    "xfs/lvm-raid10",
    "zfs/mirror",
    "zfs/mirror-8k",
    "zfs/single",
    "btrfs/raid1",
    "btrfs/single",
    "bcachefs/replicas2",
    "bcachefs/single",
]

METRICS = [
    ("seqwrite_mbps", "Sequential write", "MB/s", "higher"),
    ("randwrite_iops", "Random write, 4k + fsync", "IOPS", "higher"),
    ("fsync_p99_ms", "fsync p99 latency", "ms", "lower"),
    ("fsync_p999_ms", "fsync p99.9 latency", "ms", "lower"),
    ("randread_iops", "Random read, 4k cold cache", "IOPS", "higher"),
    ("snapshot_create_ms", "Snapshot create", "ms", "lower"),
    ("snapshot_delete_ms", "Snapshot delete (all)", "ms", "lower"),
    ("reclaim_s", "Space reclaim after delete", "s", "lower"),
    ("reclaim_write_mbps", "Write during reclaim", "MB/s", "higher"),
    ("compress_ratio", "zstd compression ratio", "x", "higher"),
    ("compress_write_mbps", "Compressible-data write", "MB/s", "higher"),
    ("reflink_ms", "Reflink copy of 2G", "ms", "lower"),
    ("degraded_randwrite_iops", "Degraded random write", "IOPS", "higher"),
    ("degraded_randread_iops", "Degraded random read", "IOPS", "higher"),
    ("rebuild_s", "Rebuild after device loss", "s", "lower"),
    ("scrub_s", "Scrub after corruption", "s", "lower"),
]


def load_runs(runs_dir):
    runs = []
    subdirs = sorted(
        d for d in glob.glob(os.path.join(runs_dir, "*")) if os.path.isdir(d)
    )
    groups = (
        [(os.path.basename(d), glob.glob(os.path.join(d, "result-*.json")))
         for d in subdirs]
        if subdirs
        else [("run", glob.glob(os.path.join(runs_dir, "result-*.json")))]
    )
    for run_id, files in groups:
        results, dates, kernels = {}, [], set()
        for f in sorted(files):
            with open(f) as fh:
                doc = json.load(fh)
            entity = f"{doc['fs']}/{doc['layout']}"
            entry = dict(doc.get("results", {}))
            entry["calibration"] = doc.get("calibration")
            entry["version"] = doc.get("version") or None
            results[entity] = entry
            dates.append(doc.get("date", ""))
            kernels.add(doc.get("kernel", "?"))
        if results:
            runs.append({
                "id": run_id,
                "date": max(dates),
                "kernel": " / ".join(sorted(kernels)),
                "results": results,
            })
    runs.sort(key=lambda r: r["date"])
    return runs


def entity_list(runs):
    seen = {e for r in runs for e in r["results"]}
    ordered = [e for e in ENTITY_ORDER if e in seen]
    ordered += sorted(seen - set(ENTITY_ORDER))
    slots = dict(FAMILY_SLOT)
    variants = {}
    out = []
    for e in ordered:
        fam = e.split("/")[0]
        if fam not in slots:
            slots[fam] = max(slots.values()) + 1  # unknown family: next slot
        vi = variants.get(fam, 0)
        variants[fam] = vi + 1
        out.append({"id": e, "fi": slots[fam], "vi": vi})
    if max(v["fi"] for v in out) > 7:
        print("WARNING: more than 8 families; hues reused", file=sys.stderr)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", default="https://github.com/fenio/modern-fs-benchmark")
    args = ap.parse_args()

    runs = load_runs(args.runs)
    if not runs:
        print(f"no result JSON found under {args.runs}", file=sys.stderr)
        sys.exit(1)

    data = {
        "entities": entity_list(runs),
        "metrics": [
            {"key": k, "label": l, "unit": u, "better": b}
            for k, l, u, b in METRICS
        ],
        "runs": runs,
        "repo": args.repo,
    }
    html = TEMPLATE.replace("__DATA__", json.dumps(data, separators=(",", ":")))
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as fh:
        fh.write(html)
    print(f"wrote {args.out}: {len(runs)} run(s), {len(data['entities'])} filesystems")


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>modern-fs-benchmark</title>
<style>
:root {
  --surface: #fcfcfb; --page: #f9f9f7;
  --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --ring: rgba(11,11,11,0.10);
  /* family slots: ext4, xfs, zfs, btrfs, bcachefs — validated per mode */
  --s1:#1c5cab; --s2:#0891b2; --s3:#e34948; --s4:#0d8c34;
  --s5:#eda100; --s6:#4a3aa7; --s7:#e87ba4; --s8:#eb6834;
}
@media (prefers-color-scheme: dark) {
  :root {
    --surface: #1a1a19; --page: #0d0d0d;
    --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
    --s1:#256abf; --s2:#0da2b8; --s3:#e66767; --s4:#0d8c34;
    --s5:#c98500; --s6:#9085e9; --s7:#d55181; --s8:#d95926;
    --grid: #2c2c2a; --axis: #383835; --ring: rgba(255,255,255,0.10);
  }
}
* { box-sizing: border-box; margin: 0; }
body {
  background: var(--page); color: var(--ink);
  font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
  padding: 24px 16px 64px;
}
main { max-width: 1080px; margin: 0 auto; }
h1 { font-size: 22px; font-weight: 650; }
h2 { font-size: 15px; font-weight: 650; margin: 40px 0 4px; }
.sub { color: var(--ink-2); margin-top: 4px; }
.sub a { color: inherit; }
.note { color: var(--muted); font-size: 12.5px; margin: 2px 0 14px; }
.legend { display: flex; flex-wrap: wrap; gap: 6px 16px; margin: 18px 0 6px; }
.legend span { display: inline-flex; align-items: center; gap: 6px; color: var(--ink-2); font-size: 13px; }
.legend i { width: 12px; height: 12px; border-radius: 3px; display: inline-block; }
.grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px; }
@media (max-width: 720px) { .grid { grid-template-columns: 1fr; } }
.card {
  background: var(--surface); border: 1px solid var(--ring);
  border-radius: 10px; padding: 14px 16px 10px;
}
.card h3 { font-size: 13px; font-weight: 600; }
.card .unit { color: var(--muted); font-weight: 400; }
.cardhead { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; }
.sortbtn {
  background: none; border: 1px solid var(--ring); border-radius: 6px;
  color: var(--muted); font: 11px system-ui, -apple-system, "Segoe UI", sans-serif;
  padding: 2px 8px; cursor: pointer; flex: none;
}
.sortbtn:hover { color: var(--ink-2); border-color: var(--axis); }
.sortbtn[aria-pressed="true"] { color: var(--ink); border-color: var(--axis); }
.wide { overflow-x: auto; }
svg.chart { display: block; width: 100%; height: auto; }
svg text { font: 11.5px system-ui, -apple-system, "Segoe UI", sans-serif; }
svg.key { display: inline-block; width: 20px; height: 10px; flex: none; }
.tt {
  position: fixed; pointer-events: none; z-index: 10; display: none;
  background: var(--surface); border: 1px solid var(--ring); border-radius: 8px;
  padding: 8px 10px; font-size: 12.5px; box-shadow: 0 4px 14px rgba(0,0,0,.18);
  max-width: 260px;
}
.tt b { font-weight: 600; }
.tt .row { display: flex; align-items: center; gap: 6px; color: var(--ink-2); }
.tt i { width: 9px; height: 9px; border-radius: 2px; display: inline-block; flex: none; }
.tt .v { margin-left: auto; color: var(--ink); font-variant-numeric: tabular-nums; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { text-align: right; padding: 6px 10px; border-bottom: 1px solid var(--grid); white-space: nowrap; }
th { color: var(--ink-2); font-weight: 600; }
th:first-child, td:first-child { text-align: left; }
td { font-variant-numeric: tabular-nums; }
td i { width: 9px; height: 9px; border-radius: 2px; display: inline-block; margin-right: 7px; }
footer { color: var(--muted); font-size: 12.5px; margin-top: 48px; }
footer a { color: var(--ink-2); }
</style>
</head>
<body>
<main id="app"></main>
<div class="tt" id="tt"></div>
<script>
const DATA = __DATA__;
const SLOTS = ["--s1","--s2","--s3","--s4","--s5","--s6","--s7","--s8"];
const DASH = ["", "7 4", "2 4"];  // variant within a family: solid/dashed/dotted
const css = v => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const color = e => css(SLOTS[e.fi % SLOTS.length]);
const dash = e => DASH[e.vi % DASH.length];
const key = e =>
  `<svg class="key" viewBox="0 0 20 10"><line x1="1" y1="5" x2="19" y2="5"
   stroke="${color(e)}" stroke-width="2.5" stroke-linecap="round"
   ${dash(e) ? `stroke-dasharray="${dash(e)}"` : ""}/></svg>`;
const latest = DATA.runs[DATA.runs.length - 1];
const ents = DATA.entities;
const fmt = v => v == null ? "—"
  : typeof v === "string" ? v
  : v >= 100 ? Math.round(v).toLocaleString("en-US")
  : v >= 10 ? (v % 1 ? v.toFixed(1) : String(v))
  : (Math.round(v * 100) / 100).toString();
const el = (tag, attrs, html) => {
  const n = document.createElement(tag);
  for (const k in attrs || {}) n.setAttribute(k, attrs[k]);
  if (html != null) n.innerHTML = html;
  return n;
};
const svgel = (tag, attrs) => {
  const n = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const k in attrs || {}) n.setAttribute(k, attrs[k]);
  return n;
};
const tt = document.getElementById("tt");
function showTT(html, x, y) {
  tt.innerHTML = html; tt.style.display = "block";
  const w = tt.offsetWidth, h = tt.offsetHeight;
  tt.style.left = Math.min(x + 14, innerWidth - w - 8) + "px";
  tt.style.top = Math.max(8, Math.min(y - h - 10, innerHeight - h - 8)) + "px";
}
const hideTT = () => tt.style.display = "none";
const niceMax = m => { if (m <= 0) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(m)));
  for (const k of [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) if (k * p >= m) return k * p;
  return 10 * p; };

// Horizontal bar card: one row per filesystem, value at the tip.
function barCard(metric) {
  const rows = ents.map(e => ({e, v: (latest.results[e.id] || {})[metric.key]}));
  if (!rows.some(r => r.v != null)) return null;
  const card = el("div", {class: "card"});
  const head = el("div", {class: "cardhead"});
  head.appendChild(el("h3", {},
    `${metric.label} <span class="unit">${metric.unit} · ${metric.better} is better</span>`));
  const btn = el("button", {class: "sortbtn", type: "button",
    "aria-pressed": "false", title: "Toggle between best-first and grouped matrix order"}, "");
  head.appendChild(btn);
  card.appendChild(head);
  const holder = el("div");
  card.appendChild(holder);
  const bestFirst = () => [...rows].sort((a, b) => {
    if (a.v == null && b.v == null) return 0;
    if (a.v == null) return 1;  // missing values last
    if (b.v == null) return -1;
    return metric.better === "lower" ? a.v - b.v : b.v - a.v;
  });
  let sorted = true;  // best-first by default
  const render = () => {
    btn.setAttribute("aria-pressed", String(sorted));
    btn.textContent = sorted ? "\u21c5 matrix order" : "\u2713 best first";
    holder.replaceChildren(drawBars(sorted ? bestFirst() : rows, metric));
  };
  btn.addEventListener("click", () => { sorted = !sorted; render(); });
  render();
  return card;
}

function drawBars(rows, metric) {
  const rowH = 24, labW = 118, W = 460, plotW = W - labW - 64;
  const H = rows.length * rowH + 8;
  const max = niceMax(Math.max(...rows.map(r => r.v).filter(v => v != null)));
  const svg = svgel("svg", {class: "chart", viewBox: `0 0 ${W} ${H}`, role: "img",
    "aria-label": metric.label});
  rows.forEach(({e, v}, i) => {
    const y = 4 + i * rowH;
    const name = svgel("text", {x: labW - 8, y: y + 15.5, "text-anchor": "end",
      fill: css("--ink-2")});
    name.textContent = e.id;
    svg.appendChild(name);
    // baseline tick
    svg.appendChild(svgel("rect", {x: labW, y: y + 2, width: 1, height: rowH - 6,
      fill: css("--axis")}));
    if (v == null) {
      const na = svgel("text", {x: labW + 8, y: y + 15.5, fill: css("--muted")});
      na.textContent = "—";
      svg.appendChild(na);
      return;
    }
    const w = Math.max(2, plotW * v / max), bh = 16, r = Math.min(4, w);
    // square at baseline, 4px rounded data-end
    const p = `M${labW},${y + 3} h${w - r} a${r},${r} 0 0 1 ${r},${r} v${bh - 2 * r}
      a${r},${r} 0 0 1 ${-r},${r} h${-(w - r)} z`;
    const bar = svgel("path", {d: p, fill: color(e)});
    svg.appendChild(bar);
    const val = svgel("text", {x: labW + w + 6, y: y + 15.5, fill: css("--ink")});
    val.textContent = fmt(v);
    svg.appendChild(val);
    // full-row hover target
    const hit = svgel("rect", {x: 0, y: y, width: W, height: rowH, fill: "transparent"});
    hit.addEventListener("mousemove", ev => showTT(
      `<div class="row">${key(e)}${e.id}
       <span class="v">${fmt(v)} ${metric.unit}</span></div>`, ev.clientX, ev.clientY));
    hit.addEventListener("mouseleave", hideTT);
    svg.appendChild(hit);
  });
  return svg;
}

// Line chart with hover crosshair. series: [{name, color, points:[{x,y}]}]
function lineChart(series, xLabels, unit, height) {
  const W = 720, H = height || 300, L = 52, R = 16, T = 12, B = 30;
  const pw = W - L - R, ph = H - T - B;
  const allY = series.flatMap(s => s.points.map(p => p.y)).filter(v => v != null);
  const maxY = niceMax(Math.max(...allY, 0));
  const nx = xLabels.length;
  const X = i => L + (nx === 1 ? pw / 2 : pw * i / (nx - 1));
  const Y = v => T + ph * (1 - v / maxY);
  const svg = svgel("svg", {class: "chart", viewBox: `0 0 ${W} ${H}`});
  for (let g = 0; g <= 4; g++) {  // hairline solid grid
    const y = T + ph * g / 4;
    svg.appendChild(svgel("line", {x1: L, x2: W - R, y1: y, y2: y,
      stroke: css("--grid"), "stroke-width": 1}));
    const t = svgel("text", {x: L - 8, y: y + 4, "text-anchor": "end",
      fill: css("--muted"), style: "font-variant-numeric:tabular-nums"});
    t.textContent = fmt(maxY * (1 - g / 4));
    svg.appendChild(t);
  }
  const tickStep = Math.max(1, Math.ceil(nx / 10));
  xLabels.forEach((lb, i) => {
    if (i % tickStep && i !== nx - 1) return;
    const t = svgel("text", {x: X(i), y: H - 8, "text-anchor": "middle",
      fill: css("--muted")});
    t.textContent = lb;
    svg.appendChild(t);
  });
  svg.appendChild(svgel("line", {x1: L, x2: W - R, y1: T + ph, y2: T + ph,
    stroke: css("--axis"), "stroke-width": 1}));
  series.forEach(s => {
    const pts = s.points.filter(p => p.y != null);
    if (!pts.length) return;
    const d = pts.map((p, j) => `${j ? "L" : "M"}${X(p.x)},${Y(p.y)}`).join("");
    const attrs = {d, fill: "none", stroke: s.color,
      "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round"};
    if (s.dash) attrs["stroke-dasharray"] = s.dash;
    svg.appendChild(svgel("path", attrs));
    const end = pts[pts.length - 1];  // end marker with surface ring
    svg.appendChild(svgel("circle", {cx: X(end.x), cy: Y(end.y), r: 4,
      fill: s.color, stroke: css("--surface"), "stroke-width": 2}));
  });
  const cross = svgel("line", {y1: T, y2: T + ph, stroke: css("--axis"),
    "stroke-width": 1, visibility: "hidden"});
  svg.appendChild(cross);
  const hit = svgel("rect", {x: L, y: T, width: pw, height: ph, fill: "transparent"});
  hit.addEventListener("mousemove", ev => {
    const box = svg.getBoundingClientRect();
    const mx = (ev.clientX - box.left) / box.width * W;
    const i = Math.max(0, Math.min(nx - 1,
      Math.round(nx === 1 ? 0 : (mx - L) / pw * (nx - 1))));
    cross.setAttribute("x1", X(i)); cross.setAttribute("x2", X(i));
    cross.setAttribute("visibility", "visible");
    const rows = series.map(s => {
      const p = s.points.find(q => q.x === i);
      return p && p.y != null
        ? `<div class="row">${s.keyHtml || ""}${s.name}
           <span class="v">${fmt(p.y)}</span></div>` : "";
    }).join("");
    showTT(`<b>${xLabels[i]}</b>${unit ? ` <span class="unit">${unit}</span>` : ""}${rows}`,
      ev.clientX, ev.clientY);
  });
  hit.addEventListener("mouseleave", () => { hideTT(); cross.setAttribute("visibility", "hidden"); });
  svg.appendChild(hit);
  return svg;
}

function legend(parent) {
  const lg = el("div", {class: "legend"});
  ents.forEach((e, i) =>
    lg.appendChild(el("span", {}, `${key(e)}${e.id}`)));
  parent.appendChild(lg);
}

const app = document.getElementById("app");
const dt = (latest.date || "").replace("T", " ").replace("Z", " UTC");
app.appendChild(el("h1", {}, "modern-fs-benchmark"));
app.appendChild(el("p", {class: "sub"},
  `Multi-device CoW filesystems under workloads classic benchmarks skip —
   latest run ${dt}, kernel ${latest.kernel}, ${DATA.runs.length} run(s) recorded
   · <a href="${DATA.repo}">repository</a>`));
app.appendChild(el("p", {class: "note"},
  "CI runs use loop devices on shared ephemeral VMs (one VM per filesystem): compare shapes and ratios, not absolute MB/s. Each job records a host-calibration anchor — see the table."));
legend(app);

app.appendChild(el("h2", {}, "Latest run"));
app.appendChild(el("p", {class: "note"}, "One card per metric, sorted best-first \u2014 the per-card button switches to grouped matrix order. Every value also appears in the table below."));
const grid = el("div", {class: "grid"});
DATA.metrics.forEach(m => { const c = barCard(m); if (c) grid.appendChild(c); });
app.appendChild(grid);

app.appendChild(el("h2", {}, "Snapshot aging"));
app.appendChild(el("p", {class: "note"},
  "Random-overwrite bandwidth (MB/s) per iteration while snapshots accumulate — flat is good, falling is CoW fragmentation cost."));
const agingCard = el("div", {class: "card"});
const iters = Math.max(...ents.map(e => ((latest.results[e.id] || {}).aging_mbps || []).length));
if (iters > 0) {
  const xl = Array.from({length: iters}, (_, i) => `iter ${i + 1}`);
  agingCard.appendChild(lineChart(
    ents.map(e => ({name: e.id, color: color(e), dash: dash(e), keyHtml: key(e),
      points: ((latest.results[e.id] || {}).aging_mbps || []).map((v, j) => ({x: j, y: v}))})),
    xl, "MB/s"));
}
app.appendChild(agingCard);

app.appendChild(el("h2", {}, "Trends across runs"));
if (DATA.runs.length < 2) {
  app.appendChild(el("p", {class: "note"},
    "Recorded once — trend lines appear as more runs accumulate (weekly cron + every push)."));
} else {
  app.appendChild(el("p", {class: "note"}, "One card per metric, one point per run."));
}
if (DATA.runs.length >= 2) {
  const tgrid = el("div", {class: "grid"});
  const xl = DATA.runs.map(r => (r.date || "").slice(5, 10) || r.id);
  DATA.metrics.forEach(m => {
    const series = ents.map(e => ({name: e.id, color: color(e), dash: dash(e), keyHtml: key(e),
      points: DATA.runs.map((r, j) => ({x: j, y: (r.results[e.id] || {})[m.key]}))}));
    if (!series.some(s => s.points.some(p => p.y != null))) return;
    const card = el("div", {class: "card"});
    card.appendChild(el("h3", {}, `${m.label} <span class="unit">${m.unit}</span>`));
    card.appendChild(lineChart(series, xl, m.unit, 220));
    tgrid.appendChild(card);
  });
  app.appendChild(tgrid);
}

app.appendChild(el("h2", {}, "Table view"));
app.appendChild(el("p", {class: "note"}, "Latest run, all metrics — click a column header to sort. calib = host-disk anchor measured before the filesystem exists (VM noise indicator)."));
const wrap = el("div", {class: "card wide"});
const tbl = el("table");
const cols = [
  {label: "filesystem", str: true, get: (e, r, c) => e.id},
  ...DATA.metrics.map(m => ({label: m.label, unit: m.unit, get: (e, r, c) => r[m.key]})),
  {label: "scrub errors found", get: (e, r, c) => r.scrub_found},
  {label: "scrub repaired", get: (e, r, c) => r.scrub_repaired},
  {label: "data intact after corruption", str: true,
   get: (e, r, c) => r.data_intact == null ? null : (r.data_intact ? "yes" : "NO")},
  {label: "calib seq", unit: "MB/s", get: (e, r, c) => c.seqwrite_mbps},
  {label: "calib rand", unit: "IOPS", get: (e, r, c) => c.randwrite_iops},
  {label: "tools / module version", str: true, get: (e, r, c) => r.version},
];
let sortCol = null, sortDir = 1;  // null = matrix order
function renderTable() {
  tbl.innerHTML = "";
  const head = el("tr");
  cols.forEach((col, ci) => {
    const arrow = sortCol === ci ? (sortDir > 0 ? " ▲" : " ▼") : "";
    const th = el("th", {style: "cursor:pointer;user-select:none",
      "aria-sort": sortCol === ci ? (sortDir > 0 ? "ascending" : "descending") : "none"},
      `${col.label}${arrow}${col.unit ? `<br><span class="unit">${col.unit}</span>` : ""}`);
    th.addEventListener("click", () => {
      if (sortCol === ci) sortDir = -sortDir;
      else { sortCol = ci; sortDir = col.str ? 1 : -1; }  // numbers: biggest first
      renderTable();
    });
    head.appendChild(th);
  });
  tbl.appendChild(head);
  const rows = ents.map(e => {
    const r = latest.results[e.id] || {}, c = r.calibration || {};
    return {e, vals: cols.map(col => col.get(e, r, c))};
  });
  if (sortCol != null) rows.sort((a, b) => {
    const x = a.vals[sortCol], y = b.vals[sortCol];
    if (x == null && y == null) return 0;
    if (x == null) return 1;  // nulls last, either direction
    if (y == null) return -1;
    return (typeof x === "string" ? x.localeCompare(y) : x - y) * sortDir;
  });
  rows.forEach(({e, vals}) => {
    tbl.appendChild(el("tr", {},
      `<td><span style="display:inline-flex;align-items:center;gap:7px">${key(e)}${e.id}</span></td>` +
      vals.slice(1, cols.length - 1).map(v => `<td>${fmt(v)}</td>`).join("") +
      `<td style="text-align:left">${vals[cols.length - 1] || "—"}</td>`));
  });
}
renderTable();
wrap.appendChild(tbl);
app.appendChild(wrap);

app.appendChild(el("footer", {},
  `Generated by <a href="${DATA.repo}">modern-fs-benchmark</a>. Methodology, caveats,
   and how to run it on real hardware are in the README. Ideas for workloads and
   tuning variants welcome — open an issue.`));
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
