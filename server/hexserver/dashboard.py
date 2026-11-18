"""The dashboard: server-rendered pages, charts drawn as inline SVG (no JavaScript, no CDN).

Only answers on this Mac (localhost): the API is reachable on your Wi-Fi for the phone, the pages
with your data are not.
"""
import datetime as dt
import json
from html import escape
from pathlib import Path

from fastapi import Request
from fastapi.responses import HTMLResponse, PlainTextResponse

CATALOGUE = Path(__file__).resolve().parents[2] / "app/HexplateCore/Sources/HexplateCore/Resources/exercises.json"

CSS = """
:root { --bg:#000; --card:#1c1c1e; --line:#2c2c2e; --ink:#fff; --ink2:#8e8e93; --accent:#40c8e0; --on-accent:#000; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
header { display:flex; align-items:center; gap:24px; padding:20px 32px; border-bottom:1px solid var(--line); position:sticky; top:0; background:rgba(0,0,0,.85); backdrop-filter:blur(20px); }
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
  header .sync { margin-left:0; width:100%; } main { gap:12px; } .s3 { grid-column:span 12; } }
h2 { font-size:13px; font-weight:600; color:var(--ink2); text-transform:uppercase; letter-spacing:.04em; margin:0 0 10px; }
.big { font-size:34px; font-weight:700; letter-spacing:-.02em; font-variant-numeric:tabular-nums; }
.unit { font-size:15px; color:var(--ink2); font-weight:500; margin-left:4px; }
.sub { color:var(--ink2); font-size:13px; }
table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }
td, th { padding:10px 8px; text-align:left; border-top:1px solid var(--line); }
th { color:var(--ink2); font-weight:500; font-size:13px; border-top:none; }
td.n, th.n { text-align:right; }
.pr { color:var(--accent); font-weight:600; font-size:12px; }
svg text { fill:var(--ink2); font-size:11px; }
.lift { display:flex; flex-direction:column; gap:2px; }
.lift b { font-size:15px; min-height:2.8em; } .lift .v { font-size:26px; font-weight:700; font-variant-numeric:tabular-nums; }
.lift svg { margin-top:8px; }
"""


def _num(n, d=0):
    return f"{n:,.{d}f}"


def _day(ms):
    return dt.datetime.fromtimestamp(ms / 1000)


def install(app, store):
    names = {e["id"]: e["n"] for e in json.loads(CATALOGUE.read_text())["exercises"]} if CATALOGUE.exists() else {}

    def name_of(ex_id, state):
        custom = {str(c.get("id")): c.get("name") or c.get("n") for c in (state or {}).get("customEx") or [] if isinstance(c, dict)}
        n = custom.get(ex_id) or names.get(ex_id) or ex_id
        return " ".join(w[:1].upper() + w[1:] for w in n.split(" "))

    def page(title, tab, body):
        rev = store.db.execute("SELECT rev, received_at FROM documents ORDER BY rev DESC LIMIT 1").fetchone()
        sync = f"Last sync {dt.datetime.fromtimestamp(rev[1]):%d %b %H:%M} · rev {rev[0]}" if rev else "No data yet"
        tabs = "".join(f'<a href="{h}" class="{"on" if t == tab else ""}">{t}</a>' for t, h in
                       [("Overview", "/"), ("Progress", "/progress"), ("Rep counter", "/reps"), ("Data", "/data")])
        return HTMLResponse(f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{title} · Hexplate</title>
<style>{CSS}</style></head><body><header><h1>Hexplate</h1><nav>{tabs}</nav><div class="sync">{sync}</div></header>
<main>{body}</main></body></html>""")

    def local_only(req: Request):
        return req.client is None or req.client.host in ("127.0.0.1", "::1", "testclient")

    def bars(weeks):
        """Weekly volume: one series, so no legend; the title names it. Hover: native tooltip."""
        w, h, pad, gap = 760, 180, 26, 6
        top = max((v for _, v in weeks), default=0) or 1
        bw = (w - gap * (len(weeks) - 1)) / len(weeks)
        out = []
        for i, (start, v) in enumerate(weeks):
            x, bh = i * (bw + gap), (h - pad) * v / top
            y = h - pad - bh
            # Rounded data end, square base (a path: top corners only).
            r = min(4, bh / 2, bw / 2)
            d = f"M{x:.1f},{h - pad} V{y + r:.1f} Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f} H{x + bw - r:.1f} Q{x + bw:.1f},{y:.1f} {x + bw:.1f},{y + r:.1f} V{h - pad}Z" if bh > 0 else ""
            label = f"Week of {start:%d %b}: {_num(v)} kg"
            out.append(f'<g><title>{label}</title><rect x="{x:.1f}" y="0" width="{bw:.1f}" height="{h - pad}" fill="transparent"/>'
                       f'{f"<path d={chr(34)}{d}{chr(34)} fill={chr(34)}var(--accent){chr(34)}/>" if d else ""}'
                       f'<text x="{x + bw / 2:.1f}" y="{h - 8}" text-anchor="middle">{start:%-d/%-m}</text></g>')
        return (f'<svg viewBox="0 0 {w} {h}" width="100%" role="img" aria-label="Weekly volume, last {len(weeks)} weeks">'
                f'<line x1="0" x2="{w}" y1="{h - pad}" y2="{h - pad}" stroke="var(--line)"/>{"".join(out)}</svg>')

    def spark(points):
        """Best estimated 1RM per session: a 2px line, the last point marked."""
        w, h = 260, 54
        if len(points) < 2:
            return '<div class="sub">One session so far</div>'
        lo, hi = min(p[1] for p in points), max(p[1] for p in points)
        span = (hi - lo) or 1
        xy = [(i * w / (len(points) - 1), h - 6 - (v - lo) / span * (h - 12)) for i, (_, v) in enumerate(points)]
        path = " ".join(f"{'M' if i == 0 else 'L'}{x:.1f},{y:.1f}" for i, (x, y) in enumerate(xy))
        tips = "".join(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="8" fill="transparent"><title>{d:%d %b}: {_num(v, 1)} kg</title></circle>'
                       for (x, y), (d, v) in zip(xy, points))
        lx, ly = xy[-1]
        return (f'<svg viewBox="-4 0 {w + 8} {h}" width="100%" role="img" aria-label="Estimated 1RM per session">'
                f'<path d="{path}" fill="none" stroke="var(--accent)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>'
                f'<circle cx="{lx:.1f}" cy="{ly:.1f}" r="4" fill="var(--accent)" stroke="var(--card)" stroke-width="2"/>{tips}</svg>')

    @app.get("/", response_class=HTMLResponse)
    async def overview(req: Request):
        if not local_only(req):
            return PlainTextResponse("The dashboard only opens on this Mac.", status_code=403)
        db = store.db
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
        motion = db.execute("SELECT COUNT(*), COUNT(DISTINCT exercise), MAX(recorded_at) FROM motion_files WHERE kind IS NOT 'watchlog'").fetchone()

        rows = []
        prs = {w.get("id"): len(w.get("prs") or []) for w in (state or {}).get("workouts") or [] if isinstance(w, dict)}
        for wid, date, name, start, end, vol in db.execute(
                "SELECT id, date, name, start_ms, end_ms, volume FROM workouts ORDER BY date DESC, start_ms DESC LIMIT 6"):
            sets = db.execute("SELECT COUNT(*) FROM sets WHERE workout_id = ? AND done AND NOT warmup", (wid,)).fetchone()[0]
            mins = round((end - start) / 60000) if start and end and end > start else None
            pr = f' <span class="pr">{prs[wid]} PR</span>' if prs.get(wid) else ""
            rows.append(f"<tr><td>{dt.date.fromisoformat(date):%a %-d %b}</td><td>{escape(name or '')}{pr}</td>"
                        f"<td class=n>{f'{mins} min' if mins else '–'}</td><td class=n>{sets}</td><td class=n>{_num(vol or 0)} kg</td></tr>")

        # The four lifts trained most in the last eight weeks, best Epley 1RM per session.
        since = (today - dt.timedelta(weeks=8)).isoformat()
        lifts = []
        for ex, in db.execute("""SELECT s.exercise_id FROM sets s JOIN workouts w ON w.id = s.workout_id
                                 WHERE s.done AND NOT s.warmup AND s.weight > 0 AND s.reps > 0 AND w.date >= ?
                                 GROUP BY s.exercise_id ORDER BY COUNT(*) DESC LIMIT 4""", (since,)):
            pts = db.execute("""SELECT w.date, MAX(s.weight * (1 + s.reps / 30.0)) FROM sets s JOIN workouts w ON w.id = s.workout_id
                                WHERE s.exercise_id = ? AND s.done AND NOT s.warmup AND s.weight > 0 AND s.reps > 0
                                GROUP BY w.id ORDER BY w.date""", (ex,)).fetchall()
            pts = [(dt.date.fromisoformat(d), v) for d, v in pts]
            change = pts[-1][1] - pts[0][1]
            lifts.append(f"""<div class="card s3 lift"><b>{escape(name_of(ex, state))}</b>
<div class="v">{_num(pts[-1][1], 1)}<span class="unit">kg</span></div>
<div class="sub">Estimated 1RM · {'+' if change >= 0 else '−'}{_num(abs(change), 1)} kg since {pts[0][0]:%-d %b}</div>{spark(pts)}</div>""")

        body = f"""
<div class="card s3"><h2>This week</h2><div class="big">{week[0]}<span class="unit">workouts</span></div><div class="sub">{week[1]} working sets</div></div>
<div class="card s3"><h2>Volume this week</h2><div class="big">{_num(week_vol)}<span class="unit">kg</span></div><div class="sub">4-week average {_num(avg4)} kg</div></div>
<div class="card s3"><h2>Body weight</h2><div class="big">{_num(bw[0], 1) if bw else '–'}<span class="unit">kg</span></div><div class="sub">{f'{dt.date.fromisoformat(bw[1]):%-d %b}' if bw else 'No weigh-ins'}</div></div>
<div class="card s3"><h2>Rep counter</h2><div class="big">{motion[0]}<span class="unit">sets recorded</span></div><div class="sub">{motion[1]} exercises · last {f'{dt.datetime.strptime(motion[2], "%Y%m%d-%H%M%S"):%-d %b}' if motion[2] else '–'}</div></div>
<div class="card"><h2>Weekly volume</h2>{bars(weeks)}</div>
{''.join(lifts)}
<div class="card"><h2>Recent workouts</h2><table><thead><tr><th>Date</th><th>Workout</th><th class=n>Time</th><th class=n>Sets</th><th class=n>Volume</th></tr></thead>
<tbody>{''.join(rows) or '<tr><td colspan=5 class=sub>No workouts yet</td></tr>'}</tbody></table></div>"""
        return page("Overview", "Overview", body)
