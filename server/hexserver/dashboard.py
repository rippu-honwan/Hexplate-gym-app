"""The dashboard: server-rendered pages read from the latest document the phone sent, styled by ui.py
(no JavaScript library, no CDN). Read-only for training data: the log is edited on the phone, which
owns the merge; here you look, print and back up.

Only answers on this Mac (localhost): the API is reachable on your Wi-Fi for the phone, the pages
with your data are not. Forms that change something also need the browser to say they came from
these pages (Sec-Fetch-Site / Origin), so another website open on this Mac cannot post to them.
"""
import calendar
import csv
import datetime as dt
import io
import json
import socket
import subprocess
from html import escape
from pathlib import Path
from urllib.parse import parse_qs, quote

from fastapi import Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse, Response

from . import stats as S
from .queries import name_of
from .ui import bars, compact, date_lead, fmt, group, head, heat, icon, kg, line, meter, row, section, seg, shell, stats


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


def _mask(url):
    """Enough of the URL to recognise it, not enough to call it (Home Assistant keeps a secret in the path)."""
    from urllib.parse import urlsplit
    u = urlsplit(url)
    return f"{u.scheme}://{u.netloc}" + ("/…" + u.path[-4:] if len(u.path) > 1 else "")


# MARK: small readers shared by the pages

def D(iso):
    return dt.date.fromisoformat(iso)


def week_target(state):
    """The week's goal: `weekTarget` (rotation), else the days the weekly plan fills.
    ponytail: ignores day overrides and the queue (Schedule.workoutsLeft); fine for a summary."""
    n = S.num((state or {}).get("weekTarget"))
    if n and 1 <= int(n + .5) <= 7:
        return int(n + .5)
    days = sum(1 for v in ((state or {}).get("week") or {}).values() if v)
    return days or None


def prs_of(w):
    return [str(p if not isinstance(p, dict) else p.get("id") or p.get("ex")) for p in (w.get("prs") or [])]


def work_volume(ws):
    return sum(S.volume(w) for w in ws)


def by_week(ws, state, weeks, today):
    """[(week start, volume, workouts)] for the last `weeks` weeks, oldest first."""
    ws_ = S.week_start(state)
    this = D(S.week_key(today.isoformat(), ws_))
    out = []
    for k in range(weeks - 1, -1, -1):
        start = this - dt.timedelta(weeks=k)
        inweek = [w for w in ws if S.week_key(S.day(w), ws_) == start.isoformat()]
        out.append((start, work_volume(inweek), len(inweek)))
    return out


def names(w, state, n=3):
    ex = [S.ex_name(e.get("id"), state, e) for e in S.entries(w) if any(S.done_units(s) for s in S.sets(e))]
    more = f", +{len(ex) - n} more" if len(ex) > n else ""
    return escape(", ".join(ex[:n])) + more


def duration(m):
    return "–" if m is None else f"{m} min" if m < 60 else f"{m // 60} h {m % 60:02d} min"


def workout_row(w, state, u):
    m, n, pr = S.minutes(w), S.work_sets(w), len(prs_of(w))
    badge = f'<span class="badge">{pr} PR</span>' if pr else ""
    end = " · ".join(x for x in (duration(m) if m else "", f"{n} sets", f"{fmt(S.volume(w))} {u}" if S.volume(w) else "") if x)
    return row(f"{escape(w.get('name') or 'Workout')}{badge}", names(w, state), end, f"/history/{quote(str(w.get('id')))}", date_lead(D(S.day(w))))


def range_of(kind, today):
    """The report's days, both ends included (Report.range): 7d, 4w, or 3m back to the day after
    the same date three months ago."""
    if kind == "7d":
        return today - dt.timedelta(days=6), today
    if kind == "3m":
        y, m = divmod(today.month - 1 - 3, 12)
        y, m = today.year + y, m + 1
        return dt.date(y, m, min(today.day, calendar.monthrange(y, m)[1])) + dt.timedelta(days=1), today
    return today - dt.timedelta(days=27), today


def in_range(ws, a, b):
    return [w for w in ws if a.isoformat() <= S.day(w) <= b.isoformat()]


def delta(now, before, unit="", d=0):
    if not before:
        return ""
    ch = now - before
    pct = ch / before * 100
    sign = "+" if ch >= 0 else "−"
    return f'{sign}{fmt(abs(ch), d)}{unit} ({sign}{fmt(abs(pct))}%) vs before'


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

    def page(active, body, title=None):
        rev = db.execute("SELECT rev, received_at FROM documents ORDER BY rev DESC LIMIT 1").fetchone()
        sync = f"Synced {dt.datetime.fromtimestamp(rev[1]):%-d %b, %H:%M}" if rev else "Not synced yet"
        return HTMLResponse(shell(active, title or active, body, sync))

    def doc():
        return store.current()[1] or {}

    def no_data(active, title):
        return page(active, head(title) + group([], "No workouts yet. Pair your phone in Sync & backup and they appear here."))

    # MARK: Summary

    @app.get("/", response_class=HTMLResponse)
    async def summary():
        state, today = doc(), dt.date.today()
        ws = S.workouts(state)
        if not ws:
            return no_data("Summary", "Summary")
        u, wst = S.unit(state), S.week_start(state)
        start = D(S.week_key(today.isoformat(), wst))
        this = [w for w in ws if S.week_key(S.day(w), wst) == start.isoformat()]
        plan, target = S.plan_by_weekday(state), week_target(state)

        rings = []
        for i in range(7):
            d = start + dt.timedelta(days=i)
            done = [w for w in this if S.day(w) == d.isoformat()]
            planned = plan.get((d.weekday() + 1) % 7) or []
            cls = "done" if done else "today" if d == today else "future" if d > today else ""
            label = escape(done[0].get("name") or "Workout") if done else f'<span class="muted">{escape(", ".join(planned))}</span>' if planned and d >= today else ""
            ring = f'<div class="ring {cls}"{" aria-current=date" if d == today else ""}>{d.day}</div>'
            if done:
                ring = f'<a href="/history/{quote(str(done[0].get("id")))}">{ring}</a>'
            rings.append(f'<div><div class="wd">{d:%a}</div>{ring}<div class="pl">{label}</div></div>')

        weeks = by_week(ws, state, 12, today)
        avg4 = sum(v for _, v, _ in weeks[-5:-1]) / 4
        while len(weeks) > 4 and weeks[0][1] == 0 and weeks[0][2] == 0:
            weeks.pop(0)
        vol = work_volume(this)
        streak = S.weeks_in_a_row(state, today)
        strip = stats([
            ("Workouts", f"{len(this)}", f"of {target}" if target else "", "this week"),
            ("Working sets", fmt(sum(S.work_sets(w) for w in this)), "", "this week"),
            ("Volume", compact(vol), u, f"4-week average {compact(avg4)} {u}"),
            ("Weeks in a row", str(streak), "", "with a workout")])

        muscles = S.weekly_muscle_sets(state, today.isoformat())
        in_range_n = sum(m["status"] == "in" for m in muscles)
        recent = group([workout_row(w, state, u) for w in ws[:5]])

        recs = []
        for w in ws:
            for ex in prs_of(w):
                b = next((S.best_set(e) for e in S.entries(w) if str(e.get("id")) == ex), None)
                recs.append(row(escape(S.ex_name(ex, state)), f"{D(S.day(w)):%-d %b}",
                                f"{kg(b[1])} {u} × {fmt(b[2])}" if b else "", f"/exercises/{quote(ex)}"))
                if len(recs) == 5:
                    break
            if len(recs) == 5:
                break

        bw = S.weigh_ins(state)
        body_card = (f'<div class="card"><div class="stat" style="padding:0"><div class="l">Latest {D(bw[-1][0]):%-d %b}</div>'
                     f'<b>{fmt(bw[-1][1], 1)}<small>{u}</small></b></div>{line([(D(d), v) for d, v in bw[-30:]], spark=True, label="Body weight")}</div>'
                     if bw else group([], "No weigh-ins yet."))

        body = (head("Summary", f"{today:%A, %-d %B}")
                + section("This week", f'<div class="card"><div class="week">{"".join(rings)}</div></div>',
                          sub=f"Week of {start:%-d %b}")
                + f'<div class="sec">{strip}</div>'
                + section("Weekly volume", f'<div class="card">{bars([(f"{s:%-d/%-m}", v, f"Week of {s:%-d %b}: {fmt(v)} {u}, {n} workouts") for s, v, n in weeks], unit=u, label="Weekly volume")}</div>',
                          sub=f"last {len(weeks)} weeks", link=("Stats", "/stats"),
                          lede=f"This week {fmt(vol)} {u} so far; the 4 weeks before averaged {fmt(avg4)} {u}.")
                + '<div class="grid2">'
                + section("Muscle sets", '<div class="card">' + "".join(meter(m["name"], m["sets"], m["lo"], m["hi"], m["status"]) for m in muscles) + "</div>",
                          sub="this week", lede=f"{in_range_n} of {len(muscles)} muscles in their weekly range. The shaded band is the range.")
                + section("Recent workouts", recent, link=("History", "/history"))
                + "</div><div class=grid2>"
                + section("Latest records", group(recs, "No records yet."), link=("Exercises", "/exercises"))
                + section("Body weight", body_card, link=("Body", "/body"))
                + "</div>")
        return page("Summary", body)

    # MARK: History

    @app.get("/history", response_class=HTMLResponse)
    async def history(q: str = ""):
        state = doc()
        ws = S.workouts(state)
        if not ws:
            return no_data("History", "History")
        u, needle = S.unit(state), q.strip().lower()
        if needle:
            ws = [w for w in ws if needle in (w.get("name") or "").lower()
                  or any(needle in S.ex_name(e.get("id"), state, e).lower() for e in S.entries(w))]
        months = {}
        for w in ws:
            months.setdefault(S.day(w)[:7], []).append(w)
        search = (f'<form method="get" action="/history" class="noprint" role="search"><input type="search" name="q" value="{escape(q)}" '
                  f'placeholder="Exercise or workout" aria-label="Search workouts" style="width:240px"></form>')
        body = head("History", f"{len(ws)} workout{'s' * (len(ws) != 1)}" + (f" with “{escape(q)}”" if needle else ""), search)
        for m, mws in months.items():
            body += section(f"{D(m + '-01'):%B %Y}", group([workout_row(w, state, u) for w in mws]),
                            sub=f"{len(mws)} workout{'s' * (len(mws) != 1)} · {fmt(work_volume(mws))} {u}")
        if not months:
            body += group([], "No workout matches.")
        return page("History", body)

    @app.get("/history/{wid}", response_class=HTMLResponse)
    async def workout(wid: str):
        state = doc()
        w = next((w for w in S.workouts(state) if str(w.get("id")) == wid), None)
        if not w:
            return page("History", head("Not found", back=("History", "/history")) + group([], "No workout with that id."))
        u, prs = S.unit(state), prs_of(w)
        s, e = S.num(w.get("start")), S.num(w.get("end"))
        when = f"{D(S.day(w)):%A, %-d %B %Y}"
        if s and e:
            when += f" · {dt.datetime.fromtimestamp(s / 1000):%H:%M}–{dt.datetime.fromtimestamp(e / 1000):%H:%M}"
        gym = (w.get("gym") or {}).get("name") if isinstance(w.get("gym"), dict) else None
        strip = [("Duration", duration(S.minutes(w)), "", ""), ("Working sets", str(S.work_sets(w)), "", ""),
                 ("Volume", fmt(S.volume(w)), u, ""), ("Records", str(len(prs)), "", "")]
        if S.num(w.get("bw")):
            strip.append(("Body weight", fmt(w["bw"], 1), u, ""))
        body = head(w.get("name") or "Workout", escape(when + (f" · {gym}" if gym else "")), back=("History", "/history")) + stats(strip)
        if w.get("note"):
            body += section("Note", f'<div class="card">{escape(str(w["note"]))}</div>')
        for ent in S.entries(w):
            ex = str(ent.get("id"))
            rows, n = [], 0
            for x in S.sets(ent):
                warm = S.is_warmup(x)
                n += 0 if warm else 1
                label = "W" if warm else str(n)
                side = [(k, x["sides"][k]) for k in ("L", "R")] if S.is_side(x) else [("", x)]
                for k, y in side:
                    done = y.get("done") is True
                    hr = x.get("hr") if isinstance(x.get("hr"), dict) else {}
                    rows.append(f'<tr class="{"dim" if warm else "" if done else "off"}"><td>{label}{f" · {k}" if k else ""}</td>'
                                f'<td class=r>{kg(y["w"]) + " " + u if S.num(y.get("w")) is not None else "–"}</td>'
                                f'<td class=r>{fmt(y["r"]) if S.num(y.get("r")) is not None else "–"}</td>'
                                f'<td class=r>{fmt(y["rir"]) if S.num(y.get("rir")) is not None else ""}</td>'
                                f'<td class=r>{fmt(hr["avg"]) if S.num(hr.get("avg")) else ""}</td></tr>')
            b = S.best_set(ent)
            sub = f"best {kg(b[1])} {u} × {fmt(b[2])} · e1RM {fmt(b[0], 1)}" if b else ""
            badge = '<span class="badge">PR</span>' if ex in prs else ""
            note = (ent.get("target") or {}).get("note") if isinstance(ent.get("target"), dict) else None
            table = (f'<div class="card">{f"<p class=lede style=margin:0 0 10px>{escape(note)}</p>" if note else ""}<div class="scroll"><table>'
                     f'<thead><tr><th>Set</th><th class=r>Weight</th><th class=r>Reps</th><th class=r>RIR</th><th class=r>Heart rate</th></tr></thead>'
                     f'<tbody>{"".join(rows)}</tbody></table></div></div>')
            body += (f'<section class="sec"><div class="sec-h"><h2><a href="/exercises/{quote(ex)}" style="color:inherit">{escape(S.ex_name(ex, state, ent))}</a>{badge}</h2>'
                     f'<span>{sub}</span></div>{table}</section>')
        body += '<p class="note">Warm-ups are dimmed, sets not ticked are struck through. Edit a workout on the phone.</p>'
        return page("History", body, w.get("name") or "Workout")

    # MARK: Plan

    @app.get("/plan", response_class=HTMLResponse)
    async def plan():
        state = doc()
        rs = S.routines(state)
        if not rs:
            return page("Plan", head("Plan") + group([], "No routines yet. Make one on the phone."))
        u, by_day, wst = S.unit(state), S.plan_by_weekday(state), S.week_start(state)
        order = [(wst + i) % 7 for i in range(7)]
        today = (dt.date.today().weekday() + 1) % 7
        week = group([row(calendar.day_name[(d - 1) % 7] + (' <span class="badge">Today</span>' if d == today else ""),
                          end=escape(", ".join(by_day.get(d) or [])) or '<span class="muted">Rest</span>') for d in order])
        target = week_target(state)
        mode = "rotation" if (state.get("scheduleMode") == "rotation") else "weekly plan"
        body = head("Plan", f"{len(rs)} routine{'s' * (len(rs) != 1)} · {mode}" + (f" · {target} workouts a week" if target else ""))
        body += section("Week", week, lede="The routines your weekly plan puts on each day. Change the plan on the phone.")
        for r in rs:
            rows = []
            for x in r.get("ex") or []:
                if not isinstance(x, dict):
                    continue
                reps = (f'{fmt(x["repsMin"])}–{fmt(x["repsMax"])}' if S.num(x.get("repsMin")) and S.num(x.get("repsMax"))
                        else fmt(x["reps"]) if S.num(x.get("reps")) else f'{fmt(x["sec"])} s' if S.num(x.get("sec")) else "–")
                rest = int(S.num(x.get("restSec")) or 0)
                note = f'<div class="muted" style="font-size:12px">{escape(str(x["note"]))}</div>' if x.get("note") else ""
                rows.append(f'<tr><td>{escape(S.ex_name(x.get("id"), state))}{note}</td>'
                            f'<td class=r>{fmt(x["sets"]) if S.num(x.get("sets")) else "–"} × {reps}</td>'
                            f'<td class=r>{kg(x["weight"]) + " " + u if S.num(x.get("weight")) else "–"}</td>'
                            f'<td class=r>{f"{rest // 60}:{rest % 60:02d}" if rest else "–"}</td></tr>')
            sets_n = sum(S.num(x.get("sets")) or 0 for x in r.get("ex") or [] if isinstance(x, dict))
            days = [calendar.day_abbr[(d - 1) % 7] for d in order if (r.get("name") or "Workout") in (by_day.get(d) or [])]
            body += section(r.get("name") or "Workout", f'<div class="card"><div class="scroll"><table><thead><tr><th>Exercise</th><th class=r>Sets × reps</th>'
                            f'<th class=r>Weight</th><th class=r>Rest</th></tr></thead><tbody>{"".join(rows)}</tbody></table></div></div>',
                            sub=f"{len(rows)} exercises · {fmt(sets_n)} sets" + (f" · {', '.join(days)}" if days else ""))
        return page("Plan", body)

    # MARK: Exercises

    @app.get("/progress")
    async def progress(ex: str | None = None):
        return RedirectResponse(f"/exercises/{quote(ex)}" if ex else "/exercises", status_code=301)

    @app.get("/exercises", response_class=HTMLResponse)
    async def exercises(q: str = ""):
        state = doc()
        trained = S.trained_exercises(state)
        if not trained:
            return no_data("Exercises", "Exercises")
        u, needle = S.unit(state), q.strip().lower()
        rows = []
        for i, n, last in trained:
            nm = S.ex_name(i, state)
            if needle and needle not in nm.lower():
                continue
            ses = S.exercise_sessions(state, i)
            best = max((s["est"] for s in ses if s["est"]), default=None)
            rows.append(row(escape(nm), f"{n} session{'s' * (n != 1)} · last {D(last):%-d %b}",
                            f"e1RM {fmt(best, 1)} {u}" if best else "", f"/exercises/{quote(i)}"))
        search = (f'<form method="get" action="/exercises" role="search"><input type="search" name="q" value="{escape(q)}" '
                  f'placeholder="Find an exercise" aria-label="Find an exercise" style="width:220px"></form>')
        body = head("Exercises", f"{len(trained)} trained, most recent first", search) + group(rows, "No exercise matches.")
        return page("Exercises", body)

    @app.get("/exercises/{ex}", response_class=HTMLResponse)
    async def exercise(ex: str):
        state = doc()
        ses = S.exercise_sessions(state, ex)
        nm = S.ex_name(ex, state)
        if not ses:
            return page("Exercises", head(nm, back=("Exercises", "/exercises")) + group([], "No working sets logged for this exercise."), nm)
        u = S.unit(state)
        mw = sorted(S.muscle_weights(ex, state).items(), key=lambda kv: -kv[1])
        muscles = ", ".join(S.muscle_name(k) for k, v in mw if v >= .5) or ", ".join(S.muscle_name(k) for k, _ in mw[:2])
        est = [s for s in ses if s["est"]]
        best = max(est, key=lambda s: s["est"]) if est else None
        heaviest = max((s for s in ses if s["w"]), key=lambda s: s["w"], default=None)
        strip = [("Best e1RM", fmt(best["est"], 1) if best else "–", u if best else "", f"{D(best['d']):%-d %b %Y}" if best else ""),
                 ("Heaviest set", f"{kg(heaviest['w'])}" if heaviest else "–", f"{u} × {fmt(heaviest['r'])}" if heaviest else "", f"{D(heaviest['d']):%-d %b %Y}" if heaviest else ""),
                 ("Sessions", str(len(ses)), "", f"since {D(ses[0]['d']):%-d %b %Y}"),
                 ("Last time", f"{D(ses[-1]['d']):%-d %b}", "", f"{ses[-1]['sets']} sets · {fmt(ses[-1]['volume'])} {u}")]
        pts = [(D(s["d"]), s["est"]) for s in est]
        change = (f"From {fmt(pts[0][1], 1)} to {fmt(pts[-1][1], 1)} {u} over {len(pts)} sessions." if len(pts) > 1 else "")
        rows = "".join(f'<tr><td><a href="/history/{quote(str(s["id"]))}">{D(s["d"]):%a %-d %b %Y}</a>{"<span class=badge>PR</span>" if s["pr"] else ""}</td>'
                       f'<td class=r>{kg(s["w"]) + " " + u + " × " + fmt(s["r"]) if s["w"] else "–"}</td><td class=r>{fmt(s["est"], 1) if s["est"] else "–"}</td>'
                       f'<td class=r>{s["sets"]}</td><td class=r>{fmt(s["volume"])} {u}</td></tr>' for s in reversed(ses))
        body = (head(nm, escape(muscles), back=("Exercises", "/exercises")) + stats(strip)
                + section("Estimated 1RM per session", f'<div class="card">{line(pts, label="Estimated 1RM per session", fmt_v=lambda v: fmt(v, 1 if v < 20 else 0))}</div>',
                          sub=u, lede=change)
                + section("Sessions", f'<div class="card"><div class="scroll"><table><thead><tr><th>Date</th><th class=r>Best set</th><th class=r>e1RM</th>'
                          f'<th class=r>Sets</th><th class=r>Volume</th></tr></thead><tbody>{rows}</tbody></table></div></div>')
                + '<p class="note">Estimated 1RM uses the Epley formula, weight × (1 + reps / 30), on ticked working sets.</p>')
        return page("Exercises", body, nm)

    # MARK: Body

    @app.get("/body", response_class=HTMLResponse)
    async def body_page(range: str = "3m"):
        state, today = doc(), dt.date.today()
        u, bw, ms = S.unit(state), S.weigh_ins(state), S.measurements(state)
        if not bw and not ms:
            return page("Body", head("Body") + group([], "No weigh-ins or measurements yet. Log them on the phone."))
        out = head("Body", f"{len(bw)} weigh-in{'s' * (len(bw) != 1)} · {len(ms)} measurement{'s' * (len(ms) != 1)}")
        if bw:
            def ago(days):
                cut = (today - dt.timedelta(days=days)).isoformat()
                old = [v for d, v in bw if d <= cut]
                return f"{'+' if bw[-1][1] - old[-1] >= 0 else '−'}{fmt(abs(bw[-1][1] - old[-1]), 1)}" if old else "–"
            goal = S.num(state.get("targetW"))
            strip = [("Latest", fmt(bw[-1][1], 1), u, f"{D(bw[-1][0]):%-d %b %Y}"), ("30 days", ago(30), u, "change"),
                     ("90 days", ago(90), u, "change")]
            if goal and goal > 0:
                strip.append(("Goal", fmt(goal, 1), u, f"{fmt(abs(bw[-1][1] - goal), 1)} {u} to go"))
            days = {"3m": 92, "1y": 366}.get(range)
            pts = [(D(d), v) for d, v in bw if not days or d >= (today - dt.timedelta(days=days)).isoformat()]
            ctl = seg([("3 months", "/body?range=3m", "3m"), ("1 year", "/body?range=1y", "1y"), ("All", "/body?range=all", "all")], range if range in ("1y", "all") else "3m")
            out += stats(strip) + section("Body weight", f'<div class="card">{line(pts, label="Body weight", goal=goal if goal and goal > 0 else None)}</div>',
                                          sub=u, link=None, lede=(f"{len(pts)} weigh-ins in this range." + (" The dashed line is your goal." if goal else "")))
            out = out.replace(f'<h2>Body weight</h2><span>{u}</span>', f'<h2>Body weight</h2><span>{u}</span><span style="margin-left:auto">{ctl}</span>', 1)
            rows = "".join(f"<tr><td>{D(d):%a %-d %b %Y}</td><td class=r>{fmt(v, 1)} {u}</td></tr>" for d, v in reversed(bw[-20:]))
            weigh = f'<div class="card"><table><thead><tr><th>Date</th><th class=r>Weight</th></tr></thead><tbody>{rows}</tbody></table></div>'
        else:
            weigh = group([], "No weigh-ins yet.")
        if ms:
            series = {}
            for d, vals in ms:
                for k, (v, unit_) in vals.items():
                    series.setdefault(k, []).append((d, v, unit_))
            rows = "".join(f'<tr><td>{escape(k)}</td><td class=r>{fmt(s[-1][1], 1)} {escape(s[-1][2])}</td><td class=r>{D(s[-1][0]):%-d %b}</td>'
                           f'<td class=r>{"" if len(s) < 2 else ("+" if s[-1][1] >= s[0][1] else "−") + fmt(abs(s[-1][1] - s[0][1]), 1)}</td></tr>'
                           for k, s in series.items())
            meas = (f'<div class="card"><div class="scroll"><table><thead><tr><th>Measure</th><th class=r>Latest</th><th class=r>Date</th>'
                    f'<th class=r>Since first</th></tr></thead><tbody>{rows}</tbody></table></div></div>')
        else:
            meas = group([], "No measurements yet.")
        out += '<div class="grid2">' + section("Measurements", meas) + section("Weigh-ins", weigh, sub="latest 20") + "</div>"
        return page("Body", out)

    # MARK: Stats

    @app.get("/stats", response_class=HTMLResponse)
    async def stats_page(range: str = "3m"):
        state, today = doc(), dt.date.today()
        ws = S.workouts(state)
        if not ws:
            return no_data("Stats", "Stats")
        range = range if range in ("4w", "3m", "1y") else "3m"
        weeks_n = {"4w": 4, "3m": 13, "1y": 52}[range]
        u, wst = S.unit(state), S.week_start(state)
        first = D(S.week_key(today.isoformat(), wst)) - dt.timedelta(weeks=weeks_n - 1)
        rws = in_range(ws, first, today)
        mins = [m for m in (S.minutes(w) for w in rws) if m]
        strip = stats([("Workouts", str(len(rws)), "", f"{fmt(len(rws) / weeks_n, 1)} a week"),
                       ("Volume", compact(work_volume(rws)), u, f"{compact(work_volume(rws) / weeks_n)} {u} a week"),
                       ("Working sets", fmt(sum(S.work_sets(w) for w in rws)), "", ""),
                       ("Time trained", f"{sum(mins) // 60}", "h", f"{duration(round(sum(mins) / len(mins)))} a workout" if mins else "")])
        ctl = seg([("4 weeks", "/stats?range=4w", "4w"), ("3 months", "/stats?range=3m", "3m"), ("1 year", "/stats?range=1y", "1y")], range)
        weeks = by_week(ws, state, weeks_n, today)
        busiest = max(weeks, key=lambda t: t[1])
        days = {}
        for w in ws:
            days[S.day(w)] = days.get(S.day(w), 0) + S.volume(w)
        load = S.load_of(rws, state)
        balance = ""
        for slug, fallback in S.DEFAULT_TARGETS:
            lo, hi = S.target_of(state, slug, fallback)
            n = S.js_round1(load.get(slug, 0) / weeks_n)
            balance += meter(S.muscle_name(slug), n, lo, hi, "below" if n < lo else "above" if n > hi else "in")
        top = {}
        for w in rws:
            for e in S.entries(w):
                n = sum(S.done_units(s) for s in S.sets(e) if not S.is_warmup(s))
                if n:
                    top[str(e.get("id"))] = top.get(str(e.get("id")), 0) + n
        tops = sorted(top.items(), key=lambda kv: -kv[1])[:8]
        top_rows = group([row(escape(S.ex_name(i, state)), end=f"{n} sets", href=f"/exercises/{quote(i)}") for i, n in tops], "No sets in this range.")
        body = (head("Stats", f"{first:%-d %b %Y} – {today:%-d %b %Y}", ctl) + strip
                + section("Consistency", f'<div class="card">{heat(days, today, 53, wst)}</div>', sub="last 12 months",
                          lede=f"{len([d for d in days if d >= (today - dt.timedelta(days=364)).isoformat()])} training days in the last year; darker days moved more weight.")
                + section("Weekly volume", f'<div class="card">{bars([(f"{s:%-d/%-m}", v, f"Week of {s:%-d %b}: {fmt(v)} {u}, {n} workouts") for s, v, n in weeks], unit=u, label="Weekly volume", hi=weeks.index(busiest))}</div>',
                          sub=u, lede=f"The busiest week, highlighted, was {busiest[0]:%-d %b} with {fmt(busiest[1])} {u}.")
                + '<div class="grid2">'
                + section("Muscle balance", f'<div class="card">{balance}</div>', sub="average sets a week",
                          lede="Working sets per muscle, averaged over the range, against each weekly range.")
                + section("Most trained", top_rows, sub="by working sets")
                + "</div>")
        return page("Stats", body)

    # MARK: Report

    @app.get("/report", response_class=HTMLResponse)
    async def report(range: str = "4w"):
        state, today = doc(), dt.date.today()
        ws = S.workouts(state)
        if not ws:
            return no_data("Report", "Report")
        range = range if range in ("7d", "4w", "3m") else "4w"
        a, b = range_of(range, today)
        n_days = (b - a).days + 1
        pa, pb = a - dt.timedelta(days=n_days), a - dt.timedelta(days=1)
        rws, pws = in_range(ws, a, b), in_range(ws, pa, pb)
        u = S.unit(state)
        mins, pmins = sum(S.minutes(w) or 0 for w in rws), sum(S.minutes(w) or 0 for w in pws)
        sets_, psets = sum(S.work_sets(w) for w in rws), sum(S.work_sets(w) for w in pws)
        strip = stats([("Workouts", str(len(rws)), "", delta(len(rws), len(pws))),
                       ("Volume", compact(work_volume(rws)), u, delta(work_volume(rws), work_volume(pws))),
                       ("Working sets", fmt(sets_), "", delta(sets_, psets)),
                       ("Time", duration(mins) if mins else "–", "", delta(mins, pmins, " min"))])
        ctl = seg([("7 days", "/report?range=7d", "7d"), ("4 weeks", "/report?range=4w", "4w"), ("3 months", "/report?range=3m", "3m")], range)
        act = f'<span class="noprint">{ctl}</span><button class="noprint" onclick="print()">{icon("print", 14)} Print</button>'
        recs = []
        for w in reversed(rws):
            for ex in prs_of(w):
                bs = next((S.best_set(e) for e in S.entries(w) if str(e.get("id")) == ex), None)
                recs.append(f'<tr><td>{escape(S.ex_name(ex, state))}</td><td class=r>{f"{kg(bs[1])} {u} × {fmt(bs[2])}" if bs else ""}</td>'
                            f'<td class=r>{f"{fmt(bs[0], 1)}" if bs else ""}</td><td class=r>{D(S.day(w)):%-d %b}</td></tr>')
        load = S.load_of(rws, state)
        muscles = sorted(((S.muscle_name(k), v) for k, v in load.items() if v >= .5), key=lambda kv: -kv[1])[:10]
        mrows = "".join(f"<tr><td>{escape(k)}</td><td class=r>{fmt(S.js_round1(v), 1)}</td></tr>" for k, v in muscles)
        bw = [(d, v) for d, v in S.weigh_ins(state) if a.isoformat() <= d <= b.isoformat()]
        wrows = "".join(f'<tr><td><a href="/history/{quote(str(w.get("id")))}">{D(S.day(w)):%a %-d %b}</a></td><td>{escape(w.get("name") or "Workout")}'
                        f'<div class=muted style=font-size:12px>{names(w, state, 6)}</div></td><td class=r>{duration(S.minutes(w)) if S.minutes(w) else "–"}</td>'
                        f'<td class=r>{S.work_sets(w)}</td><td class=r>{fmt(S.volume(w))} {u}</td></tr>' for w in reversed(rws))
        body = (head("Training report", f"{a:%-d %b %Y} – {b:%-d %b %Y} · {n_days} days, compared with the {n_days} days before", act) + strip
                + '<div class="grid2">'
                + section("Records", f'<div class="card">{"<table><thead><tr><th>Exercise</th><th class=r>Set</th><th class=r>e1RM</th><th class=r>Date</th></tr></thead><tbody>" + "".join(recs) + "</tbody></table>" if recs else "<div class=muted>No records in this range.</div>"}</div>',
                          sub=f"{len(recs)} new")
                + section("Muscles worked", f'<div class="card">{"<table><thead><tr><th>Muscle</th><th class=r>Sets</th></tr></thead><tbody>" + mrows + "</tbody></table>" if mrows else "<div class=muted>No working sets.</div>"}</div>',
                          sub="effective working sets")
                + "</div>"
                + (section("Body weight", f'<div class="card">{line([(D(d), v) for d, v in bw], height=150, label="Body weight")}</div>',
                           sub=f"{fmt(bw[0][1], 1)} → {fmt(bw[-1][1], 1)} {u}") if bw else "")
                + section("Every workout", f'<div class="card"><div class="scroll"><table><thead><tr><th>Date</th><th>Workout</th><th class=r>Time</th>'
                          f'<th class=r>Sets</th><th class=r>Volume</th></tr></thead><tbody>{wrows or "<tr><td colspan=5 class=muted>No workouts in this range.</td></tr>"}</tbody></table></div></div>')
                + f'<p class="note">Made by Hexplate on {today:%-d %B %Y}. The phone makes the same report as a PDF (Settings › Report).</p>')
        return page("Report", body, "Training report")

    # MARK: Rep counter

    @app.get("/reps", response_class=HTMLResponse)
    async def reps():
        state = doc()
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
            ex_rows.append(f"<tr><td>{escape(name_of(ex, state))}</td><td class=r>{len(fs)}</td><td class=r>{len(r)}</td>"
                           f"<td class=r>{f'{e}/{len(r)}' if r else '–'}</td><td class=r>{fmt(m, 2) if m is not None else '–'}</td></tr>")
        recent = []
        for f in files[:15]:
            off = f["auto"] - f["reps"] if rated(f) else None
            off_text = "" if off is None else ("0" if off == 0 else f'<span class="warn">{off:+d}</span>')
            weight = f"{kg(f['w'])} kg" if isinstance(f.get("w"), (int, float)) else "–"
            recent.append(f"<tr><td>{dt.datetime.fromtimestamp(f['end'] / 1000):%-d %b %H:%M}</td><td>{escape(name_of(str(f.get('exId')), state))}</td>"
                          f"<td class=r>{weight}</td><td class=r>{f.get('auto', '–')}</td><td class=r>{f.get('reps', '–')}</td><td class=r>{off_text}</td></tr>")
        strip = stats([("Sets recorded", str(len(files)), "", f"{len(per)} exercises"),
                       ("Confirmed", str(len(checked)), "", "counts checked on the watch"),
                       ("Exact", str(round(100 * exact / len(checked))) if checked else "–", "%", f"{exact} of {len(checked)} counted right"),
                       ("Mean error", fmt(mae, 2) if mae is not None else "–", "reps", "live count vs confirmed")])
        body = (head("Rep counter", "How well the watch counts your reps") + strip
                + section("By exercise", f'<div class="card"><div class="scroll"><table><thead><tr><th>Exercise</th><th class=r>Sets</th><th class=r>Checked</th>'
                          f'<th class=r>Exact</th><th class=r>Error</th></tr></thead><tbody>{"".join(ex_rows) or "<tr><td colspan=5 class=muted>No motion files yet.</td></tr>"}</tbody></table></div></div>')
                + section("Latest sets", f'<div class="card"><div class="scroll"><table><thead><tr><th>When</th><th>Exercise</th><th class=r>Weight</th><th class=r>Live</th>'
                          f'<th class=r>Final</th><th class=r>Off</th></tr></thead><tbody>{"".join(recent) or "<tr><td colspan=6 class=muted>No sets yet.</td></tr>"}</tbody></table></div></div>')
                + '<p class="note">Live is the watch\'s own count; Final is the count after you corrected it on the watch. The full check against the phone\'s log is analysis/motion_check.py.</p>')
        return page("Rep counter", body)

    # MARK: Sync & backup

    def data_page(req: Request, code: str | None = None):
        address = f"http://{local_name()}.local:{req.url.port or 8765}"
        ip = wifi_address()
        fallback = f" If the phone cannot reach it, try <b>http://{ip}:{req.url.port or 8765}</b>." if ip else ""
        pair = (f'<div class="code">{code}</div><div class="muted">Works once, for 5 minutes. On the phone: Settings › Server, '
                f'address <b style="color:var(--ink)">{escape(address)}</b>, then this code.{fallback}</div>') if code else \
               ('<p class="muted" style="margin:0 0 14px">A code lets one phone sync with this Mac. It works once, for 5 minutes.</p>'
                '<form method="post" action="/data/pair"><button>New pairing code</button></form>')
        phones = [row(f"Phone {i + 1}", f"Paired {dt.datetime.fromtimestamp(at):%-d %b %Y, %H:%M}",
                      f"""<form method="post" action="/data/revoke" onsubmit="return confirm('Unpair this phone? It stops syncing until it is paired again.')">
<input type="hidden" name="h" value="{h}"><button class="plain small">Unpair</button></form>""") for i, (h, at) in enumerate(store.tokens())]
        versions = "".join(f"""<tr><td>rev {rev}</td><td>{dt.datetime.fromtimestamp(at):%a %-d %b, %H:%M}</td><td class=r>{n or 0}</td>
<td class=r>{fmt(size / 1024)} KB</td><td class=r><a class="btn plain small" href="/data/rev/{rev}.json" download>Download</a>
<form method="post" action="/data/restore" onsubmit="return confirm('Make rev {rev} the current copy? The phone takes it on its next sync and merges in anything it changed since. No version is deleted.')">
<input type="hidden" name="rev" value="{rev}"><button class="plain small">Restore</button></form></td></tr>"""
                           for rev, at, n, size in store.versions())
        act = '<a class="btn plain" href="/data/sets.csv" download>Sets (CSV)</a><a class="btn" href="/data/latest.json" download>Download backup</a>'
        body = (head("Sync & backup", "Pair phones, keep every version, download your data", act)
                + '<div class="grid2">' + section("Pair a phone", f'<div class="card">{pair}</div>')
                + section("Paired phones", group(phones, "No phone paired yet.")) + "</div>"
                + section("Versions", f'<div class="card"><div class="scroll"><table><thead><tr><th>Version</th><th>Received</th><th class=r>Workouts</th><th class=r>Size</th>'
                          f'<th class=r></th></tr></thead><tbody>{versions or "<tr><td colspan=5 class=muted>No data yet.</td></tr>"}</tbody></table></div></div>',
                          sub="latest 30",
                          lede="Every copy the phone sends is kept. The backup is the openGym JSON the app imports; the CSV has one row per set, for a spreadsheet."))
        return page("Sync & backup", body)

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

    @app.get("/data/sets.csv")
    async def sets_csv():
        state = doc()
        buf = io.StringIO()
        out = csv.writer(buf)
        out.writerow(["date", "workout", "exercise_id", "exercise", "set", "warmup", "done", "weight", "reps", "rir", "hr_avg", "unit"])
        u = S.unit(state)
        for w in reversed(S.workouts(state)):
            for e in S.entries(w):
                for i, x in enumerate(S.sets(e), 1):
                    hr = x.get("hr") if isinstance(x.get("hr"), dict) else {}
                    out.writerow([S.day(w), w.get("name") or "", e.get("id"), S.ex_name(e.get("id"), state, e), i, int(S.is_warmup(x)),
                                  int(x.get("done") is True), x.get("w", ""), x.get("r", ""), x.get("rir", ""), hr.get("avg", ""), u])
        return Response(buf.getvalue(), media_type="text/csv",
                        headers={"Content-Disposition": f'attachment; filename="hexplate-sets-{dt.date.today()}.csv"'})

    # MARK: Connect (webhooks and the MCP server)

    from .webhooks import EVENT_LABELS, EVENTS
    hooks = app.state.webhooks

    def connect_page(note=""):
        def status(h):
            word = "Paused" if h["paused"] else ("Not sent yet" if h["last_ok"] is None else ("Delivered" if h["last_ok"] else "Failed"))
            when = f" · {dt.datetime.fromtimestamp(h['last_at']):%-d %b, %H:%M}" if h["last_at"] else ""
            return f'<span class="{"warn" if h["last_ok"] is False and not h["paused"] else ""}">{word}</span>{when}' + (f" · {escape(h['last_msg'])}" if h["last_msg"] else "")
        rows = [row(f'{escape(h["label"] or "Webhook")}', f'{escape(_mask(h["url"]))} · {", ".join(EVENT_LABELS[e] for e in h["events"])}<br>{status(h)}',
                    f"""<form method="post" action="/connect/test"><input type="hidden" name="id" value="{h["id"]}"><button class="plain small">Send test</button></form>
<form method="post" action="/connect/pause"><input type="hidden" name="id" value="{h["id"]}"><input type="hidden" name="paused" value="{0 if h["paused"] else 1}">
<button class="plain small">{"Resume" if h["paused"] else "Pause"}</button></form>
<form method="post" action="/connect/remove" onsubmit="return confirm('Delete this webhook? Its URL and secret are forgotten.')">
<input type="hidden" name="id" value="{h["id"]}"><button class="danger small">Delete</button></form>""") for h in hooks.all()]
        boxes = "".join(f'<label class="check"><input type="checkbox" name="events" value="{e}"{" checked" if e == "workout.finished" else ""}> {EVENT_LABELS[e]}</label>' for e in EVENTS)
        here = Path(__file__).resolve().parents[1]
        mcp = json.dumps({"mcpServers": {"hexplate": {"command": str(here / ".venv/bin/python"), "args": ["-m", "hexserver", "mcp"],
                                                       "env": {"PYTHONPATH": str(here)}}}}, indent=2)
        add = f"""<div class="card"><form method="post" action="/connect/add" style="display:grid;gap:12px">
<div style="display:grid;grid-template-columns:1fr 2fr;gap:10px"><input name="label" placeholder="Name (optional)" maxlength="60" aria-label="Name">
<input name="url" type="url" placeholder="https://… (the URL your tool gave you)" required aria-label="URL"></div>
<div>{boxes}</div><div><button>Add webhook</button></div></form></div>"""
        body = (note + head("Connect", "Send your training to other tools")
                + section("Webhooks", group(rows, "No webhooks yet."),
                          lede="A signed JSON message to Home Assistant, n8n, Node-RED or ntfy when you finish a workout, set a record or weigh in. Sent when the phone syncs, for what happened in the last seven days.")
                + section("Add a webhook", add)
                + '<p class="note">Each message carries <code>X-Hexplate-Signature: t=&lt;seconds&gt;,v1=&lt;HMAC-SHA256 of "t.body"&gt;</code>, keyed with the secret shown once when you add the webhook.</p>'
                + section("MCP server", f"<pre>{escape(mcp)}</pre>", sub="for AI assistants",
                          lede="Lets Claude Desktop or Claude Code read your training log, read-only: summary, routines, an exercise's history and any SQL question. "
                               "For Claude Desktop, add this to <code>~/Library/Application Support/Claude/claude_desktop_config.json</code> and restart it; "
                               "Claude Code in this repo picks it up from <code>.mcp.json</code>."))
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
            return connect_page(f'<div class="banner"><b>Not added.</b> {escape(str(e))}</div>')
        return connect_page(f'''<div class="banner"><b>Webhook added.</b> Its signing secret, shown only now. Copy it into your tool:
<div class="code" style="font-size:16px;word-break:break-all;margin-top:8px">{escape(secret)}</div></div>''')

    @app.post("/connect/test", response_class=HTMLResponse)
    async def connect_test(req: Request):
        ok, msg = hooks.send_test((await fields(req)).get("id", [""])[0])
        return connect_page(f'<div class="banner"><b>{"Test sent." if ok else "Test failed."}</b> {escape(msg)}</div>')

    @app.post("/connect/pause")
    async def connect_pause(req: Request):
        f = await fields(req)
        hooks.pause(f.get("id", [""])[0], f.get("paused", ["0"])[0] == "1")
        return to_connect()

    @app.post("/connect/remove")
    async def connect_remove(req: Request):
        hooks.remove((await fields(req)).get("id", [""])[0])
        return to_connect()
