"""The dashboard's look: one stylesheet, the window shell and the few pieces every page is built from.

Quiet on purpose, in the manner of a Mac app: system type, a translucent sidebar, grouped lists on
a soft grey (black in Dark Mode), hairlines instead of boxes, and the accent spent on what matters
(the current week, the latest bar, the selected row). It follows the system's light or dark
appearance; there is no switch of its own. Charts are inline SVG: one series each, the title says
what it is, a sentence above says what it shows, and hovering a mark names its value.
"""
import datetime as dt
import math
from html import escape

from .i18n import fd, t, zh

CSS = """
:root { color-scheme: light dark;
  --bg:#f5f5f7; --surface:#fff; --raised:#fff; --fill:rgba(120,120,128,.12); --fill2:rgba(120,120,128,.07);
  --ink:#1d1d1f; --ink2:#6e6e73; --line:rgba(0,0,0,.09); --bar:#d1d1d6;
  --accent:#0b7a90; --accent-soft:rgba(11,122,144,.12); --on-accent:#fff; --warn:#b25000;
  --sidebar:rgba(236,236,240,.72); --shadow:0 0 0 .5px rgba(0,0,0,.07), 0 1px 3px rgba(0,0,0,.04); }
@media (prefers-color-scheme: dark) { :root {
  --bg:#000; --surface:#1c1c1e; --raised:#2c2c2e; --fill:rgba(120,120,128,.24); --fill2:rgba(120,120,128,.14);
  --ink:#f5f5f7; --ink2:#98989d; --line:rgba(255,255,255,.1); --bar:#48484a;
  --accent:#40c8e0; --accent-soft:rgba(64,200,224,.16); --on-accent:#000; --warn:#ff9f0a;
  --sidebar:rgba(28,28,30,.72); --shadow:0 0 0 .5px rgba(255,255,255,.08); } }
* { box-sizing:border-box; }
html { -webkit-text-size-adjust:100%; }
body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
  -webkit-font-smoothing:antialiased; font-feature-settings:"kern"; }
a { color:var(--accent); text-decoration:none; }
a:hover { text-decoration:underline; }
:focus-visible { outline:2px solid var(--accent); outline-offset:2px; border-radius:6px; }
.num, td, .stat b { font-variant-numeric:tabular-nums; }

/* Window: sidebar and content */
.side { position:fixed; inset:0 auto 0 0; width:228px; padding:18px 10px; background:var(--sidebar);
  backdrop-filter:saturate(180%) blur(30px); -webkit-backdrop-filter:saturate(180%) blur(30px); border-right:.5px solid var(--line); overflow-y:auto; }
.brand { display:flex; align-items:center; gap:10px; padding:4px 10px 2px; }
.brand-mark { width:26px; height:26px; border-radius:7px; background:var(--accent); display:grid; place-items:center; color:var(--on-accent); }
.brand b { font-size:15px; letter-spacing:-.01em; }
.sync { padding:2px 10px 14px 46px; font-size:12px; color:var(--ink2); }
.nav-h { font-size:11px; font-weight:600; color:var(--ink2); padding:14px 10px 4px; }
.side nav a { display:flex; align-items:center; gap:9px; height:30px; padding:0 10px; border-radius:7px; color:var(--ink); font-size:13px; }
.side nav a:hover { background:var(--fill2); text-decoration:none; }
.side nav a.on { background:var(--accent-soft); font-weight:600; }
.side nav svg { color:var(--accent); flex:none; }
.content { margin-left:228px; min-height:100vh; }
.page { max-width:1060px; margin:0 auto; padding:40px 48px 96px; }
.head { display:flex; align-items:flex-end; gap:16px; margin-bottom:28px; }
.head h1 { font:700 30px/1.15 -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; letter-spacing:-.022em; margin:0; }
.head p { margin:6px 0 0; color:var(--ink2); font-size:14px; }
.head > div:first-child { flex:1; min-width:0; } .head .act { display:flex; flex-wrap:wrap; justify-content:flex-end; gap:8px; align-items:center; }
.back { display:inline-block; font-size:13px; margin-bottom:10px; }
@media (max-width: 860px) {
  .side { position:sticky; top:0; inset:auto; width:auto; height:auto; z-index:5; display:flex; align-items:center; gap:4px; padding:10px 12px;
    border-right:0; border-bottom:.5px solid var(--line); overflow-x:auto; }
  .sync, .nav-h { display:none; } .brand { padding:0 8px 0 0; } .brand b { display:none; }
  .side nav { display:contents; } .side nav a { white-space:nowrap; flex:none; }
  .content { margin-left:0; } .page { padding:24px 16px 64px; } .head { flex-wrap:wrap; } .head h1 { font-size:26px; } }

/* Sections and surfaces */
.sec { margin-top:36px; } .sec:first-child { margin-top:0; }
.sec-h { display:flex; align-items:baseline; gap:12px; margin:0 4px 10px; }
.sec-h h2 { font-size:17px; font-weight:600; letter-spacing:-.01em; margin:0; }
.sec-h span { color:var(--ink2); font-size:13px; } .sec-h a { margin-left:auto; font-size:13px; }
.lede { color:var(--ink2); font-size:13px; margin:-4px 4px 12px; }
.card { background:var(--surface); border-radius:12px; box-shadow:var(--shadow); padding:18px 20px; min-width:0; }
/* Two columns when each gets at least 400px, else one: follows the content width, not the window. */
.grid2 { display:grid; grid-template-columns:repeat(auto-fit, minmax(min(400px, 100%), 1fr)); gap:20px 24px; margin-top:36px; }
.grid2 > .sec { margin-top:0; } .sec .grid2 { margin-top:0; }
.note { color:var(--ink2); font-size:12px; margin:10px 4px 0; }
.muted { color:var(--ink2); } .warn { color:var(--warn); }
.empty { color:var(--ink2); padding:28px 20px; text-align:center; }

/* Grouped list */
.group { background:var(--surface); border-radius:12px; box-shadow:var(--shadow); overflow:hidden; }
.row { display:flex; align-items:center; gap:14px; padding:11px 16px; min-height:46px; color:var(--ink); position:relative; }
.row + .row::before { content:""; position:absolute; top:0; left:16px; right:0; border-top:.5px solid var(--line); }
a.row:hover { background:var(--fill2); text-decoration:none; }
.row .main { flex:1; min-width:0; } .row .t { font-weight:500; } .row .s { color:var(--ink2); font-size:12.5px; margin-top:1px; }
.row .end { color:var(--ink2); font-size:13px; text-align:right; max-width:50%; }
.row .chev { color:var(--ink2); opacity:.6; }
.date { width:44px; text-align:center; flex:none; } .date b { display:block; font-size:19px; font-weight:600; line-height:1.1; }
.date span { font-size:11px; color:var(--ink2); text-transform:uppercase; letter-spacing:.03em; }
@media (max-width: 600px) { .row { flex-wrap:wrap; row-gap:2px; padding-right:36px; } .row .end { flex-basis:100%; max-width:none; text-align:left; }
  .row .date ~ .end { padding-left:58px; } .row .chev { position:absolute; right:14px; top:50%; transform:translateY(-50%); } }
.badge { display:inline-block; font-size:11px; font-weight:600; padding:1px 7px; border-radius:999px; background:var(--accent-soft); color:var(--accent); margin-left:6px; vertical-align:1px; }

/* Numbers in a row */
.stats { display:grid; grid-template-columns:repeat(auto-fit, minmax(140px, 1fr)); background:var(--surface); border-radius:12px; box-shadow:var(--shadow); }
.stat { padding:16px 18px; position:relative; }
.stat + .stat::before { content:""; position:absolute; left:0; top:16px; bottom:16px; border-left:.5px solid var(--line); }
.stat .l { font-size:12px; color:var(--ink2); } .stat b { display:block; font-size:24px; font-weight:600; letter-spacing:-.015em; margin-top:4px; }
.stat b small { font-size:14px; font-weight:500; color:var(--ink2); margin-left:3px; letter-spacing:0; } .stat .f { font-size:12px; color:var(--ink2); margin-top:2px; }

/* This week: the days as rings, like the phone's Today */
.week { display:grid; grid-template-columns:repeat(7, 1fr); gap:6px; text-align:center; }
.week .wd { font-size:11px; color:var(--ink2); font-weight:600; }
.ring { width:40px; height:40px; margin:6px auto 6px; border-radius:50%; display:grid; place-items:center; font-size:15px; font-weight:600;
  border:2px solid var(--fill); color:var(--ink2); }
.ring.done { border-color:var(--accent); color:var(--ink); } .ring.today { color:var(--ink); background:var(--fill2); }
.ring.future { border-style:dashed; opacity:.7; }
.week .pl { font-size:11.5px; color:var(--ink2); line-height:1.3; min-height:15px; }

/* Tables */
table { width:100%; border-collapse:collapse; font-size:13px; }
th { text-align:left; font-weight:500; color:var(--ink2); font-size:12px; padding:0 10px 8px; }
td { padding:9px 10px; border-top:.5px solid var(--line); vertical-align:baseline; }
th:first-child, td:first-child { padding-left:0; } th:last-child, td:last-child { padding-right:0; }
.r { text-align:right; white-space:nowrap; }
tr.dim td { color:var(--ink2); } tr.off td { color:var(--ink2); text-decoration:line-through; text-decoration-color:var(--line); }
.scroll { overflow-x:auto; }

/* Muscles against their range */
.meter { display:grid; grid-template-columns:118px 1fr 92px; align-items:center; gap:12px; padding:5px 0; font-size:13px; }
.track { position:relative; height:8px; border-radius:4px; background:var(--fill2); }
.band { position:absolute; top:0; bottom:0; border-radius:4px; background:var(--accent-soft); }
.fill { position:absolute; left:0; top:2px; bottom:2px; border-radius:2px; background:var(--accent); }
.fill.below { background:var(--ink2); opacity:.55; } .fill.above { background:var(--warn); }
.meter .v { text-align:right; color:var(--ink2); font-size:12.5px; } .meter .v b { color:var(--ink); font-weight:600; }

/* Controls */
.btn, button { font:600 13px/1 -apple-system, BlinkMacSystemFont, sans-serif; background:var(--accent); color:var(--on-accent); border:0;
  border-radius:8px; padding:8px 14px; cursor:pointer; display:inline-flex; align-items:center; gap:6px; text-decoration:none; }
.btn:hover, button:hover { filter:brightness(1.06); text-decoration:none; }
.btn.plain, button.plain { background:var(--fill); color:var(--ink); font-weight:500; }
button.small, .btn.small { padding:5px 10px; font-size:12px; }
button.danger { background:var(--fill); color:var(--warn); }
form { display:inline; }
input[type=text], input[type=search], input[type=url], input[type=date], input:not([type]) { font:inherit; color:var(--ink); background:var(--surface);
  border:.5px solid var(--line); box-shadow:inset 0 0 0 .5px var(--line); border-radius:8px; padding:7px 11px; min-width:0; }
input:focus { outline:none; box-shadow:0 0 0 3px var(--accent-soft), inset 0 0 0 1px var(--accent); }
.seg { display:inline-flex; background:var(--fill); border-radius:8px; padding:2px; gap:2px; }
.seg button { background:none; color:var(--ink); font-weight:400; } .seg button.on { background:var(--raised); box-shadow:0 1px 2px rgba(0,0,0,.12); font-weight:600; }
.seg a, .seg button { white-space:nowrap; padding:5px 12px; border-radius:6px; color:var(--ink); font-size:13px; }
.seg a:hover { text-decoration:none; background:var(--fill2); } .seg a.on { background:var(--raised); box-shadow:0 1px 2px rgba(0,0,0,.12); font-weight:600; }
label.check { display:inline-flex; gap:6px; align-items:center; margin-right:14px; font-size:13px; }
pre, code { font:12px/1.5 ui-monospace, "SF Mono", Menlo, monospace; } pre { background:var(--fill2); padding:14px; border-radius:10px; overflow-x:auto; margin:0; }
.code { font:600 38px/1 ui-monospace, "SF Mono", monospace; letter-spacing:.14em; color:var(--accent); margin:6px 0 10px; }
.banner { background:var(--accent-soft); border-radius:12px; padding:14px 18px; margin-bottom:24px; }

/* Charts */
svg text { fill:var(--ink2); font:11px -apple-system, BlinkMacSystemFont, sans-serif; }
svg .grid { stroke:var(--line); } svg .bar { fill:var(--bar); } svg .bar.hi { fill:var(--accent); }
svg .ln { stroke:var(--accent); fill:none; stroke-width:2; stroke-linejoin:round; stroke-linecap:round; }
svg .goal { stroke:var(--ink2); stroke-dasharray:4 4; }
svg .dot { fill:var(--accent); stroke:var(--surface); stroke-width:2; }
/* Motion charts: the three acceleration axes take the reference palette's first three slots, the magnitude the ink */
svg .s1 { stroke:#2a78d6; } svg .s2 { stroke:#eb6834; } svg .s3 { stroke:#1baf7a; } .key .s1 { background:#2a78d6; } .key .s2 { background:#eb6834; } .key .s3 { background:#1baf7a; }
@media (prefers-color-scheme: dark) { svg .s1 { stroke:#3987e5; } svg .s2 { stroke:#d95926; } svg .s3 { stroke:#199e70; } .key .s1 { background:#3987e5; } .key .s2 { background:#d95926; } .key .s3 { background:#199e70; } }
svg .tr { fill:none; stroke-width:1; stroke-linejoin:round; opacity:.85; } svg .mag { fill:none; stroke:var(--ink); stroke-width:1.6; stroke-linejoin:round; }
svg .tick { stroke:var(--ink2); stroke-dasharray:2 3; } svg .ref { stroke:var(--warn); stroke-dasharray:4 3; }
svg .stem { stroke:var(--bar); stroke-width:2; } svg .pt { fill:var(--accent); stroke:var(--surface); stroke-width:1.5; } svg .pt.flag { fill:var(--warn); }
.card h3.ch { margin:0 0 8px; font-size:13px; font-weight:600; } .card + .card { margin-top:12px; } .grid2 > .card + .card { margin-top:0; }
ul.list { margin:0; padding-left:18px; } ul.list li { margin:4px 0; }
.key { display:flex; flex-wrap:wrap; gap:4px 14px; font-size:12px; color:var(--ink2); margin:0 0 6px; }
.key i { display:inline-block; width:12px; height:3px; border-radius:2px; margin-right:6px; vertical-align:middle; } .key .mag { background:var(--ink); }
.key .pt { width:8px; height:8px; border-radius:50%; background:var(--accent); } .key .pt.flag { background:var(--warn); }
.key .tick { height:0; border-top:1px dashed var(--ink2); } .key .ref { height:0; border-top:1px dashed var(--warn); }
.heat { display:flex; gap:3px; width:max-content; } .heat i, .legend i { display:block; width:11px; height:11px; border-radius:3px; background:var(--fill); margin-bottom:3px; }
:is(.heat, .legend) i.l1 { background:var(--accent); opacity:.3; } :is(.heat, .legend) i.l2 { background:var(--accent); opacity:.55; }
:is(.heat, .legend) i.l3 { background:var(--accent); opacity:.8; } :is(.heat, .legend) i.l4 { background:var(--accent); }
.legend { display:flex; align-items:center; gap:4px; font-size:11px; color:var(--ink2); margin-top:8px; } .legend i { margin:0; }

@media print {
  :root { --bg:#fff; --surface:#fff; --shadow:none; --ink:#000; --ink2:#555; --line:rgba(0,0,0,.15); --accent:#0b7a90; --accent-soft:rgba(11,122,144,.12); --bar:#c7c7cc; }
  .side, .noprint { display:none !important; } .content { margin:0; } .page { padding:0; max-width:none; }
  .card, .group, .stats { box-shadow:0 0 0 .5px rgba(0,0,0,.2); } .stats, svg, tr, .row { break-inside:avoid; }
  .sec-h, .lede { break-after:avoid; } .grid2 { display:block; } .grid2 > .sec { margin-top:28px; } }
@media (prefers-reduced-transparency: reduce) { .side { background:var(--bg); backdrop-filter:none; -webkit-backdrop-filter:none; } }
"""

# SF Symbol-like line glyphs, 16 pt, drawn here so nothing loads from elsewhere.
ICONS = {
    "summary": '<rect x="2.5" y="2.5" width="4.5" height="4.5" rx="1.2"/><rect x="9" y="2.5" width="4.5" height="4.5" rx="1.2"/><rect x="2.5" y="9" width="4.5" height="4.5" rx="1.2"/><rect x="9" y="9" width="4.5" height="4.5" rx="1.2"/>',
    "history": '<path d="M2.6 8a5.4 5.4 0 1 0 1.6-3.8"/><path d="M2.4 2.6v2.6h2.6"/><path d="M8 5v3.2l2.1 1.3"/>',
    "plan": '<rect x="2.3" y="3.2" width="11.4" height="10.3" rx="2"/><path d="M2.3 6.4h11.4M5.4 1.8v2.6M10.6 1.8v2.6"/>',
    "exercises": '<path d="M1.8 8h12.4M4 5.2v5.6M12 5.2v5.6M2.4 6.4v3.2M13.6 6.4v3.2"/>',
    "body": '<circle cx="8" cy="3.3" r="1.6"/><path d="M3.2 6.2 8 7l4.8-.8M8 7v3.2l-2.2 4M8 10.2l2.2 4"/>',
    "stats": '<path d="M3 13.5V8.5M6.3 13.5V4.5M9.7 13.5v-6M13 13.5V2.5"/>',
    "report": '<path d="M4 1.8h5.2L12.5 5v9.2H4z"/><path d="M9 1.8V5h3.5M6 8.3h4.5M6 10.8h4.5"/>',
    "reps": '<rect x="4.3" y="3.6" width="7.4" height="8.8" rx="2.2"/><path d="M6 1.5h4M6 14.5h4M6.4 8h1l.7-1.5.9 3 .7-1.5h.9"/>',
    "motion": '<path d="M1.5 8h2l1.5-4.5 2.5 9 2.5-7 1.5 2.5h3"/>',
    "data": '<ellipse cx="8" cy="3.8" rx="5" ry="1.8"/><path d="M3 3.8v8.4c0 1 2.2 1.8 5 1.8s5-.8 5-1.8V3.8M3 8c0 1 2.2 1.8 5 1.8s5-.8 5-1.8"/>',
    "connect": '<path d="M6.6 9.4a2.6 2.6 0 0 0 3.7 0l2.2-2.2a2.6 2.6 0 0 0-3.7-3.7l-.9.9"/><path d="M9.4 6.6a2.6 2.6 0 0 0-3.7 0L3.5 8.8a2.6 2.6 0 0 0 3.7 3.7l.9-.9"/>',
    "chevron": '<path d="M6 3.5 10.5 8 6 12.5"/>',
    "print": '<path d="M4.5 6V2.5h7V6M4.5 11.5H2.5v-5h11v5h-2M4.5 9.5h7v4h-7z"/>',
    "settings": '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1"/>',
    "brand": '<path d="M2 8h12M4.2 5v6M11.8 5v6M2.6 6.3v3.4M13.4 6.3v3.4"/>',
}

NAV = [("Training", [("Summary", "/", "summary"), ("History", "/history", "history"), ("Plan", "/plan", "plan"), ("Exercises", "/exercises", "exercises")]),
       ("Progress", [("Body", "/body", "body"), ("Stats", "/stats", "stats"), ("Report", "/report", "report")]),
       ("Hexplate", [("Rep counter", "/reps", "reps"), ("Motion data", "/motion", "motion"), ("Sync & backup", "/data", "data"), ("Connect", "/connect", "connect"),
                     ("Settings", "/settings", "settings")])]


def icon(name, size=16, width=1.6):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="{width}" '
            f'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{ICONS[name]}</svg>')


def shell(active, title, body, sync):
    nav = "".join(f'<div class="nav-h">{t(g)}</div>' + "".join(
        f'<a href="{h}" class="{"on" if k == active else ""}"{" aria-current=page" if k == active else ""}>{icon(i)}{t(k)}</a>' for k, h, i in items)
        for g, items in NAV)
    return f"""<!doctype html><html lang="{"zh-Hant" if zh() else "en"}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark"><title>{escape(title)} · Hexplate</title><style>{CSS}</style></head>
<body><aside class="side"><div class="brand"><span class="brand-mark">{icon("brand", 16, 1.8)}</span><b>Hexplate</b></div>
<div class="sync">{escape(sync)}</div><nav aria-label="{t("Sections")}">{nav}</nav></aside>
<div class="content"><main class="page">{body}</main></div>
<script>document.querySelector(".side a.on")?.scrollIntoView({{block: "nearest", inline: "center"}})</script></body></html>"""


def head(title, sub="", act="", back=None):
    b = f'<a class="back noprint" href="{back[1]}">‹ {escape(back[0])}</a>' if back else ""
    return f'{b}<header class="head"><div><h1>{escape(title)}</h1>{f"<p>{sub}</p>" if sub else ""}</div>{f"<div class=act>{act}</div>" if act else ""}</header>'


def section(title, body, sub="", link=None, lede=""):
    a = f'<a href="{link[1]}">{escape(link[0])}</a>' if link else ""
    return (f'<section class="sec"><div class="sec-h"><h2>{escape(title)}</h2>{f"<span>{sub}</span>" if sub else ""}{a}</div>'
            f'{f"<p class=lede>{lede}</p>" if lede else ""}{body}</section>')


def stats(items):
    """[(label, value, unit, foot)] as one strip of numbers."""
    return '<div class="stats">' + "".join(
        f'<div class="stat"><div class="l">{escape(l)}</div><b>{v}{f"<small>{escape(u)}</small>" if u else ""}</b>'
        f'{f"<div class=f>{f}</div>" if f else ""}</div>' for l, v, u, f in items) + "</div>"


def group(rows, empty="Nothing here yet."):
    return f'<div class="group">{"".join(rows) or f"<div class=empty>{escape(t(empty))}</div>"}</div>'


def row(title, sub="", end="", href=None, lead=""):
    tag, attr = ("a", f' href="{href}"') if href else ("div", "")
    chev = f'<span class="chev">{icon("chevron", 13, 2)}</span>' if href else ""
    return (f'<{tag} class="row"{attr}>{lead}<div class="main"><div class="t">{title}</div>{f"<div class=s>{sub}</div>" if sub else ""}</div>'
            f'{f"<div class=end>{end}</div>" if end else ""}{chev}</{tag}>')


def date_lead(d: dt.date):
    return f'<div class="date"><span>{fd(d, "a")}</span><b>{d.day}</b></div>'


def seg(options, current):
    """A segmented control of links: [(label, href, key)]."""
    return '<div class="seg" role="group">' + "".join(
        f'<a href="{h}" class="{"on" if k == current else ""}"{" aria-current=true" if k == current else ""}>{escape(l)}</a>' for l, h, k in options) + "</div>"


def fmt(n, d=0):
    return f"{n:,.{d}f}"


def kg(n):
    """A weight without trailing zeros: 97.5, 100."""
    return fmt(n, 2).rstrip("0").rstrip(".")


def compact(v):
    return f"{fmt(v / 1000, 1)}k" if v >= 10000 else fmt(v)


def nice_max(v):
    if v <= 0:
        return 1
    p = 10 ** (len(str(int(v))) - 1)
    for m in (1, 2, 2.5, 5, 10):
        if v <= m * p:
            return m * p
    return 10 * p


# MARK: charts

def bars(points, height=170, unit="kg", label="Volume", hi=None):
    """[(label, value, tooltip)]: thin rounded bars on a recessive grid; `hi` (default the last)
    is the one in the accent colour."""
    if not points:
        return f'<div class="empty">{t("No data yet.")}</div>'
    w, h, left, bottom = 760, height, 40, 22
    top = nice_max(max(v for _, v, _ in points))
    n = len(points)
    slot = (w - left) / n
    bw = max(4, min(28, slot * .58))
    hi = n - 1 if hi is None else hi
    out = []
    for f in (0, .5, 1):
        y = h - bottom - (h - bottom - 8) * f
        out.append(f'<line class="grid" x1="{left}" x2="{w}" y1="{y:.1f}" y2="{y:.1f}"/><text x="{left - 8}" y="{y + 4:.1f}" text-anchor="end">{compact(top * f)}</text>')
    step = max(1, round(n / 12))
    for i, (lab, v, tip) in enumerate(points):
        cx = left + slot * i + slot / 2
        bh = (h - bottom - 8) * v / top
        y = h - bottom - bh
        r = min(4, bh / 2, bw / 2)
        shape = (f'<path class="bar{" hi" if i == hi else ""}" d="M{cx - bw / 2:.1f},{h - bottom} V{y + r:.1f} Q{cx - bw / 2:.1f},{y:.1f} {cx - bw / 2 + r:.1f},{y:.1f} '
                 f'H{cx + bw / 2 - r:.1f} Q{cx + bw / 2:.1f},{y:.1f} {cx + bw / 2:.1f},{y + r:.1f} V{h - bottom}Z"/>') if bh > 0 else ""
        lab_t = f'<text x="{cx:.1f}" y="{h - 6}" text-anchor="middle">{escape(lab)}</text>' if i % step == 0 or i == n - 1 else ""
        out.append(f'<g><title>{escape(tip)}</title><rect x="{left + slot * i:.1f}" y="0" width="{slot:.1f}" height="{h - bottom}" fill="transparent"/>{shape}{lab_t}</g>')
    return f'<svg viewBox="0 0 {w} {h}" width="100%" role="img" aria-label="{escape(label)}">{"".join(out)}</svg>'


def line(points, height=200, label="Trend", goal=None, fmt_v=lambda v: fmt(v, 1), spark=False):
    """[(date, value)]: a 2 px line over time, the latest point marked; `goal` adds a dashed line."""
    if len(points) < 2:
        return f'<div class="empty">{t("One entry so far." if points else "No data yet.")}</div>'
    w, h = (240, 44) if spark else (760, height)
    left, bottom, top_pad = (0, 0, 6) if spark else (44, 22, 10)
    vals = [v for _, v in points] + ([goal] if goal else [])
    lo, hi = min(vals), max(vals)
    pad = (hi - lo) * .12 or 1
    lo, hi = lo - pad, hi + pad
    t0, t1 = points[0][0].toordinal(), points[-1][0].toordinal()
    span_t = (t1 - t0) or 1
    X = lambda d: left + (d.toordinal() - t0) / span_t * (w - left - 6)
    Y = lambda v: top_pad + (h - bottom - top_pad) * (1 - (v - lo) / (hi - lo))
    out = []
    if not spark:
        for f in (0, .5, 1):
            v = lo + (hi - lo) * f
            out.append(f'<line class="grid" x1="{left}" x2="{w}" y1="{Y(v):.1f}" y2="{Y(v):.1f}"/><text x="{left - 8}" y="{Y(v) + 4:.1f}" text-anchor="end">{fmt_v(v)}</text>')
        out.append(f'<text x="{left}" y="{h - 5}">{fd(points[0][0], "dy")}</text><text x="{w - 6}" y="{h - 5}" text-anchor="end">{fd(points[-1][0], "dy")}</text>')
    if goal:
        out.append(f'<line class="goal" x1="{left}" x2="{w - 6}" y1="{Y(goal):.1f}" y2="{Y(goal):.1f}"><title>{t("Goal {v}", v=fmt_v(goal))}</title></line>')
    path = " ".join(f"{'M' if i == 0 else 'L'}{X(d):.1f},{Y(v):.1f}" for i, (d, v) in enumerate(points))
    out.append(f'<path class="ln" d="{path}"/>')
    if not spark:
        out += [f'<circle cx="{X(d):.1f}" cy="{Y(v):.1f}" r="8" fill="transparent"><title>{fd(d, "dy")}: {fmt_v(v)}</title></circle>' for d, v in points]
    d, v = points[-1]
    out.append(f'<circle class="dot" cx="{X(d):.1f}" cy="{Y(v):.1f}" r="{3.5 if spark else 4.5}"/>')
    return f'<svg viewBox="-4 -2 {w + 8} {h + 4}" width="100%" role="img" aria-label="{escape(label)}">{"".join(out)}</svg>'


def meter(name, sets, lo, hi, status, scale=None):
    """A muscle's sets against its range: the band is the range, the bar what was done."""
    scale = scale or max(hi * 1.25, sets, 1)
    word = t({"below": "under range", "in": "in range", "above": "over range"}[status])
    tip = t("{name}: {sets} sets, aim {lo}–{hi} ({word})", name=name, sets=fmt(sets, 1 if sets % 1 else 0), lo=lo, hi=hi, word=word)
    return (f'<div class="meter" title="{escape(tip)}"><span>{escape(name)}</span>'
            f'<span class="track"><span class="band" style="left:{lo / scale * 100:.1f}%;width:{(hi - lo) / scale * 100:.1f}%"></span>'
            f'<span class="fill {status}" style="width:{min(sets / scale, 1) * 100:.1f}%"></span></span>'
            f'<span class="v"><b>{fmt(sets, 1 if sets % 1 else 0)}</b> / {lo}–{hi}</span></div>')


def heat(days: dict, end: dt.date, weeks=53, ws=1, unit="kg"):
    """A year of training days, a column per week (the profile's first weekday on top), shaded by volume."""
    start = end - dt.timedelta(days=(((end.weekday() + 1) % 7 - ws) % 7) + 7 * (weeks - 1))
    vals = sorted(v for v in days.values() if v > 0)
    q = lambda p: vals[min(len(vals) - 1, int(p * len(vals)))] if vals else 0
    t1, t2, t3 = q(.25), q(.5), q(.75)
    cols = []
    for k in range(weeks):
        cells = []
        for j in range(7):
            d = start + dt.timedelta(days=7 * k + j)
            if d > end:
                cells.append('<i style="visibility:hidden"></i>')
                continue
            v = days.get(d.isoformat())
            lvl = "" if v is None else " l1" if not v else " l4" if v >= t3 else " l3" if v >= t2 else " l2" if v >= t1 else " l1"
            cells.append(f'<i class="{lvl.strip()}" title="{fd(d, "wdy")}{f": {fmt(v)} {unit}" if v else ": " + t("rest") if v is None else ""}"></i>')
        cols.append(f'<div>{"".join(cells)}</div>')
    legend = f'<div class="legend">{t("Less")} <i></i><i class="l1"></i><i class="l2"></i><i class="l3"></i><i class="l4"></i> {t("More")}</div>'
    # rtl on the scroller only: a narrow window opens on the latest weeks; the grid itself stays left to right.
    return f'<div class="scroll" style="direction:rtl"><div class="heat" style="direction:ltr" role="img" aria-label="{t("Training days, last {n} weeks", n=weeks)}">{"".join(cols)}</div></div>{legend}'


# MARK: motion charts (the Motion page)

def per_set(points, ref, label, log=False, lo=None):
    """[(set label, value, tooltip, flagged)]: one stem and dot per set, a dashed line at the threshold `ref`;
    flagged sets' dots take the warning colour. `log` puts the values on a log scale (gaps)."""
    if not points:
        return f'<div class="empty">{t("No data yet.")}</div>'
    w, h, left, bottom, top_pad = 380, 150, 40, 22, 8
    vals = [p[1] for p in points] + [ref]
    if log:
        f0 = math.floor(math.log10(max(min(vals), 1e-3))); f1 = math.ceil(math.log10(max(vals) * 1.05))
        f1 = f1 if f1 > f0 else f0 + 1
        Y = lambda v: top_pad + (h - bottom - top_pad) * (1 - (math.log10(max(v, 10 ** f0)) - f0) / (f1 - f0))
        marks = [10 ** e for e in range(f0, f1 + 1)]
    else:
        a = lo if lo is not None else 0
        b = nice_max(max(vals) * 1.05) if lo is None else max(vals) + (max(vals) - a) * .08
        b = b if b > a else a + 1
        Y = lambda v: top_pad + (h - bottom - top_pad) * (1 - (v - a) / (b - a))
        marks = [a, a + (b - a) / 2, b]
    out = [f'<line class="grid" x1="{left}" x2="{w}" y1="{Y(m):.1f}" y2="{Y(m):.1f}"/><text x="{left - 6}" y="{Y(m) + 4:.1f}" text-anchor="end">{round(m, 2):g}</text>' for m in marks]
    out.append(f'<line class="ref" x1="{left}" x2="{w}" y1="{Y(ref):.1f}" y2="{Y(ref):.1f}"/>')
    n = len(points); slot = (w - left) / n; base = h - bottom
    for i, (lab, v, tip, bad) in enumerate(points):
        cx = left + slot * (i + .5)
        out.append(f'<g><title>{escape(tip)}</title><rect x="{left + slot * i:.1f}" y="0" width="{slot:.1f}" height="{base}" fill="transparent"/>'
                   f'<line class="stem" x1="{cx:.1f}" x2="{cx:.1f}" y1="{base}" y2="{Y(v):.1f}"/><circle class="pt{" flag" if bad else ""}" cx="{cx:.1f}" cy="{Y(v):.1f}" r="4"/>'
                   f'{f"<text x={cx:.1f} y={h - 6} text-anchor=middle>{escape(lab)}</text>" if n <= 24 or i % 2 == 0 else ""}</g>')
    return f'<svg viewBox="-2 0 {w + 4} {h}" width="100%" role="img" aria-label="{escape(label)}">{"".join(out)}</svg>'


def traces(cols, mag, ticks, label, keep=600):
    """One set's user acceleration: x, y, z (g) as thin lines, the smoothed magnitude in ink, a dotted
    tick at each rep the watch counted live. Thinned to about `keep` points a line."""
    ts = cols["t"]
    if len(ts) < 2:
        return f'<div class="empty">{t("No data yet.")}</div>'
    step = max(1, len(ts) // keep)
    idx = range(0, len(ts), step)
    w, h, left, bottom, top_pad = 760, 170, 40, 22, 8
    series = [cols["ax"], cols["ay"], cols["az"], mag]
    lo = min(min(s[i] for i in idx) for s in series); hi = max(max(s[i] for i in idx) for s in series)
    pad = (hi - lo) * .06 or .1; lo, hi = lo - pad, hi + pad
    t0, t1 = ts[0], ts[-1]
    X = lambda x: left + (x - t0) / ((t1 - t0) or 1) * (w - left - 4)
    Y = lambda v: top_pad + (h - bottom - top_pad) * (1 - (v - lo) / (hi - lo))
    out = []
    for m in (lo, (lo + hi) / 2, hi):
        out.append(f'<line class="grid" x1="{left}" x2="{w}" y1="{Y(m):.1f}" y2="{Y(m):.1f}"/><text x="{left - 6}" y="{Y(m) + 4:.1f}" text-anchor="end">{m:.1f}</text>')
    for k in range(0, int(t1 - t0) + 1, 5 if t1 - t0 <= 60 else 10):
        out.append(f'<text x="{X(t0 + k):.1f}" y="{h - 6}" text-anchor="middle">{k}s</text>')
    for x in ticks:
        if t0 <= x <= t1:
            out.append(f'<line class="tick" x1="{X(x):.1f}" x2="{X(x):.1f}" y1="{top_pad}" y2="{h - bottom}"/>')
    for cls, s in zip(("tr s1", "tr s2", "tr s3", "mag"), series):
        out.append(f'<path class="{cls}" d="' + " ".join(f"{'M' if j == 0 else 'L'}{X(ts[i]):.1f},{Y(s[i]):.1f}" for j, i in enumerate(idx)) + '"/>')
    return f'<svg viewBox="-2 0 {w + 4} {h}" width="100%" role="img" aria-label="{escape(label)}">{"".join(out)}</svg>'


def scatter(points, xlabel, ylabel, label):
    """[(x, y, tooltip)] with the y = x line: points on it are exact."""
    if not points:
        return f'<div class="empty">{t("No data yet.")}</div>'
    w, h, left, bottom, top_pad = 380, 260, 40, 34, 8
    m = max(max(x, y) for x, y, _ in points) * 1.1 or 1
    X = lambda v: left + v / m * (w - left - 8)
    Y = lambda v: top_pad + (h - bottom - top_pad) * (1 - v / m)
    out = []
    for k in (0, m / 2, m):
        out.append(f'<line class="grid" x1="{left}" x2="{w}" y1="{Y(k):.1f}" y2="{Y(k):.1f}"/><text x="{left - 6}" y="{Y(k) + 4:.1f}" text-anchor="end">{k:.0f}</text>'
                   f'<text x="{X(k):.1f}" y="{h - bottom + 14}" text-anchor="middle">{k:.0f}</text>')
    out.append(f'<line class="goal" x1="{X(0):.1f}" y1="{Y(0):.1f}" x2="{X(m):.1f}" y2="{Y(m):.1f}"/>')
    out.append(f'<text x="{(left + w) / 2:.1f}" y="{h - 4}" text-anchor="middle">{escape(xlabel)}</text>'
               f'<text x="12" y="{(h - bottom) / 2:.1f}" text-anchor="middle" transform="rotate(-90 12 {(h - bottom) / 2:.1f})">{escape(ylabel)}</text>')
    out += [f'<circle class="pt" cx="{X(x):.1f}" cy="{Y(y):.1f}" r="5"><title>{escape(tip)}</title></circle>' for x, y, tip in points]
    return f'<svg viewBox="-2 0 {w + 4} {h}" width="100%" role="img" aria-label="{escape(label)}">{"".join(out)}</svg>'


def key(items):
    """A chart legend: [(css class, label)]."""
    return '<div class="key">' + "".join(f'<span><i class="{c}"></i>{escape(l)}</span>' for c, l in items) + "</div>"
