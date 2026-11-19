"""The dashboard: server-rendered pages, charts drawn as inline SVG (no JavaScript library, no CDN).

Only answers on this Mac (localhost): the API is reachable on your Wi-Fi for the phone, the pages
with your data are not. Forms that change something also need the browser to say they came from
these pages (Sec-Fetch-Site / Origin), so another website open on this Mac cannot post to them.
"""
import datetime as dt
import json
import socket
import subprocess
from html import escape
from pathlib import Path
from urllib.parse import parse_qs

from fastapi import Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, Response

from .queries import WORK, name_of
from .queries import sessions as _sessions
from .webhooks import EVENT_LABELS, EVENTS
TABS = [("Overview", "/"), ("Progress", "/progress"), ("Rep counter", "/reps"), ("Data", "/data"), ("Connect", "/connect")]

CSS = """
:root { --bg:#000; --card:#1c1c1e; --line:#2c2c2e; --ink:#fff; --ink2:#8e8e93; --accent:#40c8e0; --on-accent:#000; --warn:#ff9f0a; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
header { display:flex; align-items:center; gap:24px; padding:20px 32px; border-bottom:1px solid var(--line); position:sticky; top:0; z-index:1; background:rgba(0,0,0,.85); backdrop-filter:blur(20px); }
header h1 { font-size:20px; margin:0; letter-spacing:-.01em; }
nav { display:flex; gap:4px; }
nav a { color:var(--ink2); text-decoration:none; padding:6px 14px; border-radius:999px; }
nav a.on { background:var(--accent); color:var(--on-accent); font-weight:600; }
header .sync { margin-left:auto; color:var(--ink2); font-size:13px; }
main { max-width:1180px; margin:0 auto; padding:28px 32px 64px; display:grid; gap:16px; grid-template-columns:repeat(12, 1fr); }
.card { background:var(--card); border-radius:18px; padding:18px 20px; grid-column:span 12; min-width:0; }
.s3 { grid-column:span 3; } .s4 { grid-column:span 4; } .s6 { grid-column:span 6; } .s8 { grid-column:span 8; }
@media (max-width: 900px) { .s3 { grid-column:span 6; } .s4, .s6, .s8 { grid-column:span 12; } main, header { padding-left:16px; padding-right:16px; } }
@media (max-width: 600px) { header { flex-wrap:wrap; gap:10px; padding-top:12px; padding-bottom:12px; } nav { overflow-x:auto; max-width:100%; } nav a { white-space:nowrap; }
  header .sync { margin-left:0; width:100%; } main { gap:12px; } .s3 { grid-column:span 12; } .card { overflow-x:auto; } }
h2 { font-size:13px; font-weight:600; color:var(--ink2); text-transform:uppercase; letter-spacing:.04em; margin:0 0 10px; }
h3 { font-size:22px; margin:0 0 4px; letter-spacing:-.01em; }
.big { font-size:34px; font-weight:700; letter-spacing:-.02em; font-variant-numeric:tabular-nums; }
.unit { font-size:15px; color:var(--ink2); font-weight:500; margin-left:4px; }
.sub { color:var(--ink2); font-size:13px; }
p.sub { margin:12px 0 0; }
table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }
td, th { padding:10px 8px; text-align:left; border-top:1px solid var(--line); }
th { color:var(--ink2); font-weight:500; font-size:13px; border-top:none; }
td.n, th.n { text-align:right; white-space:nowrap; }
.pr { color:var(--accent); font-weight:600; font-size:12px; }
svg text { fill:var(--ink2); font-size:11px; }
a.lift { color:inherit; text-decoration:none; }
.lift { display:flex; flex-direction:column; gap:2px; }
.lift b { font-size:15px; min-height:2.8em; } .lift .v { font-size:26px; font-weight:700; font-variant-numeric:tabular-nums; }
.lift svg { margin-top:8px; }
.list { display:flex; flex-direction:column; gap:2px; max-height:640px; overflow-y:auto; }
.list a { display:flex; justify-content:space-between; gap:8px; padding:9px 10px; border-radius:10px; color:var(--ink); text-decoration:none; }
.list a:hover { background:var(--line); } .list a.on { background:var(--accent); color:var(--on-accent); font-weight:600; }
.list a.on .sub { color:var(--on-accent); }
button, .btn { font:inherit; font-weight:600; background:var(--accent); color:var(--on-accent); border:0; border-radius:999px; padding:8px 16px; cursor:pointer; text-decoration:none; display:inline-block; }
button.quiet, .btn.quiet { background:var(--line); color:var(--ink); font-weight:500; padding:5px 12px; font-size:13px; }
form { display:inline; }
input:not([type=hidden]):not([type=checkbox]) { background:var(--bg); color:var(--ink); border:1px solid var(--line); border-radius:10px; padding:9px 12px; font:inherit; max-width:560px; }
pre, code { font-family:ui-monospace,Menlo,monospace; font-size:12px; } pre { background:var(--bg); border:1px solid var(--line); padding:12px; border-radius:10px; }
.code { font:700 40px/1 ui-monospace, "SF Mono", monospace; letter-spacing:.12em; color:var(--accent); margin:8px 0; }
.warn { color:var(--warn); }
"""

def local_name():
    """The name the phone finds this Mac by on the Wi-Fi (Bonjour, `<name>.local`): macOS keeps it
    apart from the host name, which can be anything ("Mac")."""
    try:
        return subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True, timeout=2).stdout.strip() or socket.gethostname()
    except OSError:
        return socket.gethostname().removesuffix(".local")


def wifi_address():
    """This Mac's address on the local network (no packet is sent: a UDP connect only picks the route)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.168.0.1", 9))
            ip = s.getsockname()[0]
        return ip if not ip.startswith("127.") else None
    except OSError:
        return None


def _num(n, d=0):
    return f"{n:,.{d}f}"


def _kg(n):
    return _num(n, 2).rstrip("0").rstrip(".")


def install(app, store):
    db = store.db

    @app.middleware("http")
    async def guard(req: Request, call_next):
        if not req.url.path.startswith("/api/"):
            if req.client and req.client.host not in ("127.0.0.1", "::1", "testclient"):
                return PlainTextResponse("The dashboard only opens on this Mac.", status_code=403)
            if req.method == "POST":
                site = req.headers.get("sec-fetch-site")
                same = site in ("same-origin", "none") if site else req.headers.get("origin") == f"{req.url.scheme}://{req.url.netloc}"
                if not same:
                    return PlainTextResponse("Refused: this form did not come from the dashboard.", status_code=403)
        return await call_next(req)

    def page(tab, body):
        rev = db.execute("SELECT rev, received_at FROM documents ORDER BY rev DESC LIMIT 1").fetchone()
        sync = f"Last sync {dt.datetime.fromtimestamp(rev[1]):%-d %b %H:%M} · rev {rev[0]}" if rev else "No data yet"
        tabs = "".join(f'<a href="{h}" class="{"on" if t == tab else ""}">{t}</a>' for t, h in TABS)
        return HTMLResponse(f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{tab} · Hexplate</title>
<style>{CSS}</style></head><body><header><h1>Hexplate</h1><nav>{tabs}</nav><div class="sync">{sync}</div></header>
<main>{body}</main></body></html>""")

    # MARK: charts (one series each: no legend, the card title names it; hover = native tooltip)

    def bars(weeks):
        w, h, pad, gap = 760, 180, 26, 6
        top = max((v for _, v in weeks), default=0) or 1
        bw = (w - gap * (len(weeks) - 1)) / len(weeks)
        out = []
        for i, (start, v) in enumerate(weeks):
            x, bh = i * (bw + gap), (h - pad) * v / top
            y = h - pad - bh
            r = min(4, bh / 2, bw / 2)   # rounded data end, square base
            bar = (f'<path d="M{x:.1f},{h - pad} V{y + r:.1f} Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f} H{x + bw - r:.1f} '
                   f'Q{x + bw:.1f},{y:.1f} {x + bw:.1f},{y + r:.1f} V{h - pad}Z" fill="var(--accent)"/>') if bh > 0 else ""
            out.append(f'<g><title>Week of {start:%-d %b}: {_num(v)} kg</title>'
                       f'<rect x="{x:.1f}" y="0" width="{bw:.1f}" height="{h - pad}" fill="transparent"/>{bar}'
                       f'<text x="{x + bw / 2:.1f}" y="{h - 8}" text-anchor="middle">{start:%-d/%-m}</text></g>')
        return (f'<svg viewBox="0 0 {w} {h}" width="100%" role="img" aria-label="Weekly volume, last {len(weeks)} weeks">'
                f'<line x1="0" x2="{w}" y1="{h - pad}" y2="{h - pad}" stroke="var(--line)"/>{"".join(out)}</svg>')

    def line(points, w=260, h=54, axes=False):
        """Estimated 1RM per session: a 2px line, the last point marked; `axes` adds the y range
        and the first and last dates."""
        if len(points) < 2:
            return '<div class="sub">One session so far</div>'
        left, bottom = (44, 22) if axes else (0, 0)
        lo, hi = min(p[1] for p in points), max(p[1] for p in points)
        span = (hi - lo) or 1
        ph = h - bottom - 12
        xy = [(left + i * (w - left) / (len(points) - 1), 6 + ph - (v - lo) / span * ph) for i, (_, v) in enumerate(points)]
        path = " ".join(f"{'M' if i == 0 else 'L'}{x:.1f},{y:.1f}" for i, (x, y) in enumerate(xy))
        tips = "".join(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="9" fill="transparent"><title>{d:%-d %b}: {_num(v, 1)} kg</title></circle>'
                       for (x, y), (d, v) in zip(xy, points))
        grid = ""
        if axes:
            for v, y in ((hi, 6), (lo, 6 + ph)):
                grid += (f'<line x1="{left}" x2="{w}" y1="{y}" y2="{y}" stroke="var(--line)"/>'
                         f'<text x="{left - 8}" y="{y + 4}" text-anchor="end">{_num(v, 1 if hi < 20 else 0)}</text>')
            grid += (f'<text x="{left}" y="{h - 4}">{points[0][0]:%-d %b}</text>'
                     f'<text x="{w}" y="{h - 4}" text-anchor="end">{points[-1][0]:%-d %b}</text>')
        lx, ly = xy[-1]
        return (f'<svg viewBox="-4 0 {w + 8} {h}" width="100%" role="img" aria-label="Estimated 1RM per session">{grid}'
                f'<path d="{path}" fill="none" stroke="var(--accent)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>'
                f'<circle cx="{lx:.1f}" cy="{ly:.1f}" r="4" fill="var(--accent)" stroke="var(--card)" stroke-width="2"/>{tips}</svg>')

    def sessions(ex):
        return _sessions(db, ex)

    # MARK: Overview

    @app.get("/", response_class=HTMLResponse)
    async def overview():
        state = store.current()[1]
        today = dt.date.today()
        monday = today - dt.timedelta(days=today.weekday())
        week = db.execute("""SELECT COUNT(DISTINCT w.id), COALESCE(SUM(s.done AND NOT s.warmup), 0) FROM workouts w
                             LEFT JOIN sets s ON s.workout_id = w.id WHERE w.date >= ?""", (monday.isoformat(),)).fetchone()
        week_vol = db.execute("SELECT COALESCE(SUM(volume), 0) FROM workouts WHERE date >= ?", (monday.isoformat(),)).fetchone()[0]
        weeks = []
        for k in range(11, -1, -1):
            start = monday - dt.timedelta(weeks=k)
            v = db.execute("SELECT COALESCE(SUM(volume), 0) FROM workouts WHERE date >= ? AND date < ?",
                           (start.isoformat(), (start + dt.timedelta(days=7)).isoformat())).fetchone()[0]
            weeks.append((start, v))
        avg4 = sum(v for _, v in weeks[-5:-1]) / 4
        while len(weeks) > 4 and weeks[0][1] == 0:   # no empty weeks before the first workout
            weeks.pop(0)
        bw = db.execute("SELECT weight, date FROM bodyweight ORDER BY date DESC, time DESC LIMIT 1").fetchone()
        motion = db.execute("SELECT COUNT(*), COUNT(DISTINCT exercise), MAX(recorded_at) FROM motion_files WHERE kind IS NULL").fetchone()

        rows = []
        prs = {w.get("id"): len(w.get("prs") or []) for w in (state or {}).get("workouts") or [] if isinstance(w, dict)}
        for wid, date, name, start, end, vol in db.execute(
                "SELECT id, date, name, start_ms, end_ms, volume FROM workouts ORDER BY date DESC, start_ms DESC LIMIT 6"):
            sets = db.execute("SELECT COUNT(*) FROM sets WHERE workout_id = ? AND done AND NOT warmup", (wid,)).fetchone()[0]
            mins = round((end - start) / 60000) if start and end and end > start else None
            pr = f' <span class="pr">{prs[wid]} PR</span>' if prs.get(wid) else ""
            rows.append(f"<tr><td>{dt.date.fromisoformat(date):%a %-d %b}</td><td>{escape(name or '')}{pr}</td>"
                        f"<td class=n>{f'{mins} min' if mins else '–'}</td><td class=n>{sets}</td><td class=n>{_num(vol or 0)} kg</td></tr>")

        since = (today - dt.timedelta(weeks=8)).isoformat()
        lifts = []
        for ex, in db.execute(f"""SELECT s.exercise_id FROM sets s JOIN workouts w ON w.id = s.workout_id
                                  WHERE {WORK} AND w.date >= ? GROUP BY s.exercise_id ORDER BY COUNT(*) DESC LIMIT 4""", (since,)).fetchall():
            pts = [(d, e) for d, e, *_ in sessions(ex)]
            change = pts[-1][1] - pts[0][1]
            lifts.append(f"""<a class="card s3 lift" href="/progress?ex={escape(ex)}"><b>{escape(name_of(ex, state))}</b>
<div class="v">{_num(pts[-1][1], 1)}<span class="unit">kg</span></div>
<div class="sub">Estimated 1RM · {'+' if change >= 0 else '−'}{_num(abs(change), 1)} kg since {pts[0][0]:%-d %b}</div>{line(pts)}</a>""")

        last = dt.datetime.strptime(motion[2], "%Y%m%d-%H%M%S") if motion[2] else None
        body = f"""
<div class="card s3"><h2>This week</h2><div class="big">{week[0]}<span class="unit">workouts</span></div><div class="sub">{week[1]} working sets</div></div>
<div class="card s3"><h2>Volume this week</h2><div class="big">{_num(week_vol)}<span class="unit">kg</span></div><div class="sub">4-week average {_num(avg4)} kg</div></div>
<div class="card s3"><h2>Body weight</h2><div class="big">{_num(bw[0], 1) if bw else '–'}<span class="unit">kg</span></div><div class="sub">{f'{dt.date.fromisoformat(bw[1]):%-d %b}' if bw else 'No weigh-ins'}</div></div>
<div class="card s3"><h2>Rep counter</h2><div class="big">{motion[0]}<span class="unit">sets recorded</span></div><div class="sub">{motion[1]} exercises · last {f'{last:%-d %b}' if last else '–'}</div></div>
<div class="card"><h2>Weekly volume</h2>{bars(weeks)}</div>
{''.join(lifts)}
<div class="card"><h2>Recent workouts</h2><table><thead><tr><th>Date</th><th>Workout</th><th class=n>Time</th><th class=n>Sets</th><th class=n>Volume</th></tr></thead>
<tbody>{''.join(rows) or '<tr><td colspan=5 class=sub>No workouts yet</td></tr>'}</tbody></table></div>"""
        return page("Overview", body)

    # MARK: Progress

    @app.get("/progress", response_class=HTMLResponse)
    async def progress(ex: str | None = None):
        state = store.current()[1]
        trained = db.execute(f"""SELECT s.exercise_id, COUNT(DISTINCT w.id) FROM sets s JOIN workouts w ON w.id = s.workout_id
                                 WHERE {WORK} GROUP BY s.exercise_id ORDER BY MAX(w.date) DESC, COUNT(*) DESC""").fetchall()
        if not trained:
            return page("Progress", '<div class="card sub">No workouts yet</div>')
        ex = ex if ex in {i for i, _ in trained} else trained[0][0]
        items = "".join(f'<a href="/progress?ex={escape(i)}" class="{"on" if i == ex else ""}"><span>{escape(name_of(i, state))}</span>'
                        f'<span class="sub">{n}×</span></a>' for i, n in trained)
        rows = sessions(ex)
        best = max(rows, key=lambda r: r[1])
        table = "".join(f"<tr><td>{d:%a %-d %b}</td><td>{_kg(weight)} kg × {_num(reps)}</td><td class=n>{_num(e, 1)}</td>"
                        f"<td class=n>{n}</td><td class=n>{_num(v)} kg</td></tr>" for d, e, weight, reps, n, v in reversed(rows))
        body = f"""
<div class="card s4"><h2>Exercises</h2><div class="list">{items}</div></div>
<div class="card s8"><h3>{escape(name_of(ex, state))}</h3>
<div class="sub">Best estimated 1RM {_num(best[1], 1)} kg on {best[0]:%-d %b} · {len(rows)} sessions</div>
<div style="margin:18px 0 8px"><h2>Estimated 1RM per session (kg)</h2>{line([(d, e) for d, e, *_ in rows], w=720, h=220, axes=True)}</div>
<table><thead><tr><th>Date</th><th>Best set</th><th class=n>e1RM</th><th class=n>Sets</th><th class=n>Volume</th></tr></thead><tbody>{table}</tbody></table>
<p class="sub">Estimated 1RM uses the Epley formula, weight × (1 + reps / 30), on done working sets.</p></div>"""
        return page("Progress", body)

    # MARK: Rep counter

    @app.get("/reps", response_class=HTMLResponse)
    async def reps():
        state = store.current()[1]
        files = [f for f in store.motion_meta() if isinstance(f.get("end"), (int, float))]
        # Accuracy only where the lifter confirmed the count on the watch (`checked`).
        rated = lambda f: f.get("checked") is True and isinstance(f.get("auto"), int) and isinstance(f.get("reps"), int)
        score = lambda fs: (sum(f["auto"] == f["reps"] for f in fs), sum(abs(f["auto"] - f["reps"]) for f in fs) / len(fs) if fs else None)
        checked = [f for f in files if rated(f)]
        exact, mae = score(checked)
        per = {}
        for f in files:
            per.setdefault(str(f.get("exId")), []).append(f)
        ex_rows = []
        for ex, fs in sorted(per.items(), key=lambda kv: -len(kv[1])):
            r = [f for f in fs if rated(f)]
            e, m = score(r)
            ex_rows.append(f"<tr><td>{escape(name_of(ex, state))}</td><td class=n>{len(fs)}</td><td class=n>{len(r)}</td>"
                           f"<td class=n>{f'{e}/{len(r)}' if r else '–'}</td><td class=n>{_num(m, 2) if m is not None else '–'}</td></tr>")
        recent = []
        for f in files[:15]:
            off = f["auto"] - f["reps"] if rated(f) else None
            off_text = "" if off is None else ("0" if off == 0 else f'<span class="warn">{off:+d}</span>')
            weight = f"{_kg(f['w'])} kg" if isinstance(f.get("w"), (int, float)) else "–"
            recent.append(f"<tr><td>{dt.datetime.fromtimestamp(f['end'] / 1000):%-d %b %H:%M}</td><td>{escape(name_of(str(f.get('exId')), state))}</td>"
                          f"<td class=n>{weight}</td><td class=n>{f.get('auto', '–')}</td><td class=n>{f.get('reps', '–')}</td><td class=n>{off_text}</td></tr>")
        body = f"""
<div class="card s3"><h2>Sets recorded</h2><div class="big">{len(files)}</div><div class="sub">{len(per)} exercises</div></div>
<div class="card s3"><h2>Confirmed counts</h2><div class="big">{len(checked)}</div><div class="sub">sets checked on the watch</div></div>
<div class="card s3"><h2>Exact</h2><div class="big">{round(100 * exact / len(checked)) if checked else '–'}<span class="unit">%</span></div><div class="sub">{exact} of {len(checked)} counted right</div></div>
<div class="card s3"><h2>Mean error</h2><div class="big">{_num(mae, 2) if mae is not None else '–'}<span class="unit">reps</span></div><div class="sub">live count vs confirmed</div></div>
<div class="card"><h2>By exercise</h2><table><thead><tr><th>Exercise</th><th class=n>Sets</th><th class=n>Checked</th><th class=n>Exact</th><th class=n>Error</th></tr></thead>
<tbody>{''.join(ex_rows) or '<tr><td colspan=5 class=sub>No motion files yet</td></tr>'}</tbody></table></div>
<div class="card"><h2>Latest sets</h2><table><thead><tr><th>When</th><th>Exercise</th><th class=n>Weight</th><th class=n>Live</th><th class=n>Final</th><th class=n>Off</th></tr></thead>
<tbody>{''.join(recent)}</tbody></table>
<p class="sub">Live = the watch's own count; Final = the count after you corrected it on the watch. The full check against the phone's log is analysis/motion_check.py.</p></div>"""
        return page("Rep counter", body)

    # MARK: Data

    def data_page(req: Request, code: str | None = None):
        address = f"http://{local_name()}.local:{req.url.port or 8765}"
        ip = wifi_address()
        fallback = f' If the phone cannot reach it, try <b style="color:var(--ink)">http://{ip}:{req.url.port or 8765}</b>.' if ip else ""
        pair = (f'<div class="code">{code}</div><div class="sub">Works once, for 5 minutes. On the phone: Settings › Server, '
                f'address <b style="color:var(--ink)">{escape(address)}</b>, then this code.{fallback}</div>') if code else \
               '<form method="post" action="/data/pair"><button>New pairing code</button></form>'
        phones = "".join(f"""<tr><td>Paired {dt.datetime.fromtimestamp(at):%-d %b %Y %H:%M}</td><td class=n>
<form method="post" action="/data/revoke" onsubmit="return confirm('Unpair this phone? It stops syncing until it is paired again.')">
<input type="hidden" name="h" value="{h}"><button class="quiet">Unpair</button></form></td></tr>""" for h, at in store.tokens())
        versions = "".join(f"""<tr><td>rev {rev}</td><td>{dt.datetime.fromtimestamp(at):%a %-d %b %H:%M}</td><td class=n>{n or 0}</td>
<td class=n>{_num(size / 1024)} KB</td><td class=n><a class="btn quiet" href="/data/rev/{rev}.json" download>Download</a>
<form method="post" action="/data/restore" onsubmit="return confirm('Make rev {rev} the current copy? The phone takes it on its next sync and merges in anything it changed since. No version is deleted.')">
<input type="hidden" name="rev" value="{rev}"><button class="quiet">Restore</button></form></td></tr>"""
                           for rev, at, n, size in store.versions())
        body = f"""
<div class="card s6"><h2>Pair a phone</h2>{pair}</div>
<div class="card s6"><h2>Paired phones</h2><table><tbody>{phones or '<tr><td class=sub>No phone paired yet</td></tr>'}</tbody></table></div>
<div class="card"><h2>Versions</h2><div style="margin-bottom:12px"><a class="btn" href="/data/latest.json" download>Download latest backup (JSON)</a></div>
<table><thead><tr><th>Version</th><th>Received</th><th class=n>Workouts</th><th class=n>Size</th><th class=n></th></tr></thead>
<tbody>{versions or '<tr><td colspan=5 class=sub>No data yet</td></tr>'}</tbody></table>
<p class="sub">Every copy the phone sends is kept (the latest 30 are listed). The JSON is the openGym format the app imports.</p></div>"""
        return page("Data", body)

    async def form(req: Request):
        return {k: v[0] for k, v in parse_qs((await req.body()).decode()).items()}

    def back():
        return Response(status_code=303, headers={"Location": "/data"})

    def download(state, name):
        if state is None:
            return PlainTextResponse("No such version.", status_code=404)
        return JSONResponse(state, headers={"Content-Disposition": f'attachment; filename="{name}"'})

    @app.get("/data", response_class=HTMLResponse)
    async def data(req: Request):
        return data_page(req)

    @app.post("/data/pair", response_class=HTMLResponse)
    async def pair(req: Request):
        return data_page(req, store.new_pair_code())

    @app.post("/data/revoke")
    async def revoke(req: Request):
        store.revoke((await form(req)).get("h", ""))
        return back()

    @app.post("/data/restore")
    async def restore(req: Request):
        rev = (await form(req)).get("rev", "")
        if not rev.isdigit() or not store.restore(int(rev)):
            return PlainTextResponse("No such version.", status_code=404)
        return back()

    @app.get("/data/latest.json")
    async def latest():
        return download(store.current()[1], f"hexplate-{dt.date.today()}.json")

    @app.get("/data/rev/{rev}.json")
    async def version(rev: int):
        return download(store.document(rev), f"hexplate-rev{rev}.json")

    # MARK: Connect (webhooks and the MCP server)

    hooks = app.state.webhooks

    def connect_page(note=""):
        rows = "".join(f"""<tr><td><b>{escape(h["label"] or "")}</b><div class="sub">{escape(_mask(h["url"]))}</div></td>
<td>{", ".join(EVENT_LABELS[e] for e in h["events"])}</td>
<td>{"Paused" if h["paused"] else ("–" if h["last_ok"] is None else ("OK" if h["last_ok"] else "Failed"))}
<div class="sub">{escape(h["last_msg"] or "")}{f" · {dt.datetime.fromtimestamp(h['last_at']):%-d %b %H:%M}" if h["last_at"] else ""}</div></td>
<td class=n><form method="post" action="/connect/test"><input type="hidden" name="id" value="{h["id"]}"><button class="quiet">Send test</button></form>
<form method="post" action="/connect/pause"><input type="hidden" name="id" value="{h["id"]}"><input type="hidden" name="paused" value="{0 if h["paused"] else 1}">
<button class="quiet">{"Resume" if h["paused"] else "Pause"}</button></form>
<form method="post" action="/connect/remove" onsubmit="return confirm('Delete this webhook? Its URL and secret are forgotten.')">
<input type="hidden" name="id" value="{h["id"]}"><button class="quiet">Delete</button></form></td></tr>""" for h in hooks.all())
        boxes = "".join(f'<label style="margin-right:14px"><input type="checkbox" name="events" value="{e}"{" checked" if e == "workout.finished" else ""}> {EVENT_LABELS[e]}</label>' for e in EVENTS)
        here = Path(__file__).resolve().parents[1]
        mcp = json.dumps({"mcpServers": {"hexplate": {"command": str(here / ".venv/bin/python"), "args": ["-m", "hexserver", "mcp"],
                                                       "env": {"PYTHONPATH": str(here)}}}}, indent=2)
        body = f"""{note}
<div class="card"><h2>Webhooks</h2>
<p class="sub">A signed JSON message to Home Assistant, n8n, Node-RED or ntfy when you finish a workout, set a record or weigh in.
Sent when the phone syncs, for what happened in the last seven days.</p>
<table><thead><tr><th>Webhook</th><th>Events</th><th>Last delivery</th><th class=n></th></tr></thead>
<tbody>{rows or '<tr><td colspan=4 class=sub>No webhooks yet</td></tr>'}</tbody></table>
<form method="post" action="/connect/add" style="margin-top:16px;display:grid;gap:10px">
<input name="label" placeholder="Name (optional)" maxlength="60">
<input name="url" placeholder="https://… (the URL your tool gave you)" required>
<div>{boxes}</div><div><button>Add webhook</button></div></form>
<p class="sub">Each message carries <code>X-Hexplate-Signature: t=&lt;seconds&gt;,v1=&lt;HMAC-SHA256 of "t.body"&gt;</code>,
keyed with the secret shown once when you add the webhook.</p></div>
<div class="card"><h2>MCP server (AI assistants)</h2>
<p class="sub">Lets Claude Desktop or Claude Code read your training log, read-only: summary, routines, an exercise's history and any SQL question.
For Claude Desktop, add this to <code>~/Library/Application Support/Claude/claude_desktop_config.json</code> and restart it. Claude Code in this repo picks it up from <code>.mcp.json</code>.</p>
<pre style="overflow-x:auto">{escape(mcp)}</pre></div>"""
        return page("Connect", body)

    async def fields(req: Request):
        return parse_qs((await req.body()).decode())

    def to_connect():
        return Response(status_code=303, headers={"Location": "/connect"})

    @app.get("/connect", response_class=HTMLResponse)
    async def connect():
        return connect_page()

    @app.post("/connect/add", response_class=HTMLResponse)
    async def connect_add(req: Request):
        f = await fields(req)
        try:
            _, secret = hooks.add(f.get("url", [""])[0], f.get("label", [""])[0], f.get("events", []))
        except ValueError as e:
            return connect_page(f'<div class="card"><b>Not added:</b> {escape(str(e))}</div>')
        return connect_page(f'''<div class="card"><h2>Webhook added</h2><p>Its signing secret, shown only now. Copy it into your tool:</p>
<div class="code" style="font-size:18px;word-break:break-all">{escape(secret)}</div></div>''')

    @app.post("/connect/test", response_class=HTMLResponse)
    async def connect_test(req: Request):
        ok, msg = hooks.send_test((await fields(req)).get("id", [""])[0])
        return connect_page(f'<div class="card"><b>{"Test sent." if ok else "Test failed."}</b> {escape(msg)}</div>')

    @app.post("/connect/pause")
    async def connect_pause(req: Request):
        f = await fields(req)
        hooks.pause(f.get("id", [""])[0], f.get("paused", ["0"])[0] == "1")
        return to_connect()

    @app.post("/connect/remove")
    async def connect_remove(req: Request):
        hooks.remove((await fields(req)).get("id", [""])[0])
        return to_connect()


def _mask(url):
    """Enough of the URL to recognise it, not enough to call it (Home Assistant keeps a secret in the path)."""
    from urllib.parse import urlsplit
    u = urlsplit(url)
    return f"{u.scheme}://{u.netloc}" + ("/…" + u.path[-4:] if len(u.path) > 1 else "")
