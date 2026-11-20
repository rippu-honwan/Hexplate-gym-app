"""The dashboard: server-rendered pages read from the latest document the phone sent, styled by ui.py
and worded by i18n.py (no JavaScript library, no CDN). Read-only for training data: the log is
edited on the phone, which owns the merge; here you look, print and back up.

Only answers on this Mac (localhost): the API is reachable on your Wi-Fi for the phone, the pages
with your data are not. Forms that change something also need the browser to say they came from
these pages (Sec-Fetch-Site / Origin), so another website open on this Mac cannot post to them.
"""
import calendar
import csv
import datetime as dt
import io
import json
import math
import re
import socket
import subprocess
from html import escape
from pathlib import Path
from urllib.parse import parse_qs, quote

from fastapi import Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse, Response

from . import motion as M
from . import schedule as P
from . import stats as S
from .i18n import LANG, fd, t, tm, tn
from .ui import bars, compact, date_lead, fmt, group, head, heat, icon, key, kg, line, meter, per_set, row, scatter, section, seg, shell, stats, traces


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
    more = ", " + t("+{n} more", n=len(ex) - n) if len(ex) > n else ""
    return escape(", ".join(ex[:n])) + more


def duration(m):
    return "–" if m is None else t("{n} min", n=m) if m < 60 else t("{h} h {m} min", h=m // 60, m=f"{m % 60:02d}")


def routine_names(state, ids):
    by_id = {r["id"]: r.get("name") or t("Workout") for r in S.routines(state)}
    return [by_id[i] for i in ids if i in by_id]


def workout_row(w, state, u):
    m, n, pr = S.minutes(w), S.work_sets(w), len(prs_of(w))
    badge = f'<span class="badge">{t("{n} PR", n=pr)}</span>' if pr else ""
    end = " · ".join(x for x in (duration(m) if m else "", tn(n, "{n} set", "{n} sets"), f"{fmt(S.volume(w))} {u}" if S.volume(w) else "") if x)
    return row(f"{escape(w.get('name') or t('Workout'))}{badge}", names(w, state), end, f"/history/{quote(str(w.get('id')))}", date_lead(D(S.day(w))))


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
    sign = "+" if ch >= 0 else "−"
    return f'{sign}{fmt(abs(ch), d)}{unit} ({sign}{fmt(abs(ch / before * 100))}%) {t("vs before")}'


def table(head_cells, rows, empty=""):
    """A plain table in a card: head cells ending in '>' are right-aligned."""
    th = "".join(f'<th class=r>{h[:-1]}</th>' if h.endswith(">") else f"<th>{h}</th>" for h in head_cells)
    body = "".join(rows) or f'<tr><td colspan={len(head_cells)} class=muted>{empty}</td></tr>'
    return f'<div class="card"><div class="scroll"><table><thead><tr>{th}</tr></thead><tbody>{body}</tbody></table></div></div>'


def install(app, store):
    db = store.db
    backup = app.state.backup

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
            # Your choice in Settings, else the browser's first language.
            lang = store.setting("lang") or ("zh" if req.headers.get("accept-language", "").lower().startswith("zh") else "en")
            LANG.set(lang)
        return await call_next(req)

    def page(active, body, title=None):
        rev = db.execute("SELECT rev, received_at FROM documents ORDER BY rev DESC LIMIT 1").fetchone()
        sync = t("Synced {when}", when=fd(dt.datetime.fromtimestamp(rev[1]), "dt")) if rev else t("Not synced yet")
        return HTMLResponse(shell(active, title or t(active), body, sync))

    def doc():
        return store.current()[1] or {}

    def no_data(active):
        return page(active, head(t(active)) + group([], "No workouts yet. Pair your phone in Sync & backup and they appear here."))

    # MARK: Summary

    @app.get("/", response_class=HTMLResponse)
    async def summary():
        state, today = doc(), dt.date.today()
        ws = S.workouts(state)
        if not ws:
            return no_data("Summary")
        u, wst, iso = S.unit(state), S.week_start(state), today.isoformat()
        start = D(S.week_key(iso, wst))
        this = [w for w in ws if S.week_key(S.day(w), wst) == start.isoformat()]

        rings = []
        for i in range(7):
            d = start + dt.timedelta(days=i)
            done = [w for w in this if S.day(w) == d.isoformat()]
            planned = routine_names(state, P.routine_ids(state, d.isoformat(), iso)) if d >= today else []
            cls = "done" if done else "today" if d == today else "future" if d > today else ""
            label = escape(done[0].get("name") or t("Workout")) if done else f'<span class="muted">{escape(", ".join(planned))}</span>' if planned else ""
            ring = f'<div class="ring {cls}"{" aria-current=date" if d == today else ""}>{d.day}</div>'
            if done:
                ring = f'<a href="/history/{quote(str(done[0].get("id")))}">{ring}</a>'
            rings.append(f'<div><div class="wd">{fd(d, "a")}</div>{ring}<div class="pl">{label}</div></div>')

        weeks = by_week(ws, state, 12, today)
        avg4 = sum(v for _, v, _ in weeks[-5:-1]) / 4
        while len(weeks) > 4 and weeks[0][1] == 0 and weeks[0][2] == 0:
            weeks.pop(0)
        vol = work_volume(this)
        left, streak = P.workouts_left(state, iso), P.streak(state, iso)
        freeze = tn(streak["freezes"], "{n} freeze banked", "{n} freezes banked") if streak["freezes"] else t("best {n}", n=streak["best"])
        strip = stats([
            (t("Workouts"), str(left["done"] if left else len(this)), t("of {n}", n=left["of"]) if left else "", t("this week")),
            (t("Working sets"), fmt(sum(S.work_sets(w) for w in this)), "", t("this week")),
            (t("Volume"), compact(vol), u, t("4-week average {v}", v=f"{compact(avg4)} {u}")),
            (t("Weeks in a row"), str(streak["current"]), "", freeze)])

        muscles = S.weekly_muscle_sets(state, iso)
        in_n = sum(m["status"] == "in" for m in muscles)
        recs = []
        for w in ws:
            for ex in prs_of(w):
                b = next((S.best_set(e) for e in S.entries(w) if str(e.get("id")) == ex), None)
                recs.append(row(escape(S.ex_name(ex, state)), fd(D(S.day(w))), f"{kg(b[1])} {u} × {fmt(b[2])}" if b else "", f"/exercises/{quote(ex)}"))
            if len(recs) >= 5:
                break
        bw = S.weigh_ins(state)
        body_card = (f'<div class="card"><div class="stat" style="padding:0"><div class="l">{t("Latest {d}", d=fd(D(bw[-1][0])))}</div>'
                     f'<b>{fmt(bw[-1][1], 1)}<small>{u}</small></b></div>{line([(D(d), v) for d, v in bw[-30:]], spark=True, label=t("Body weight"))}</div>'
                     if bw else group([], "No weigh-ins yet."))
        vbars = bars([(fd(s, "dm"), v, t("Week of {d}: {v}, {n} workouts", d=fd(s), v=f"{fmt(v)} {u}", n=n)) for s, v, n in weeks], label=t("Weekly volume"))

        body = (head(t("Summary"), fd(today, "long"))
                + section(t("This week"), f'<div class="card"><div class="week">{"".join(rings)}</div></div>', sub=t("Week of {d}", d=fd(start)))
                + f'<div class="sec">{strip}</div>'
                + section(t("Weekly volume"), f'<div class="card">{vbars}</div>', sub=t("last {n} weeks", n=len(weeks)), link=(t("Stats"), "/stats"),
                          lede=t("This week {v} so far; the 4 weeks before averaged {a}.", v=f"{fmt(vol)} {u}", a=f"{fmt(avg4)} {u}"))
                + '<div class="grid2">'
                + section(t("Muscle sets"), '<div class="card">' + "".join(meter(m["name"], m["sets"], m["lo"], m["hi"], m["status"]) for m in muscles) + "</div>",
                          sub=t("this week"), lede=t("{n} of {m} muscles in their weekly range. The shaded band is the range.", n=in_n, m=len(muscles)))
                + section(t("Recent workouts"), group([workout_row(w, state, u) for w in ws[:5]]), link=(t("History"), "/history"))
                + "</div><div class=grid2>"
                + section(t("Latest records"), group(recs[:5], "No records yet."), link=(t("Exercises"), "/exercises"))
                + section(t("Body weight"), body_card, link=(t("Body"), "/body"))
                + "</div>")
        return page("Summary", body)

    # MARK: History

    @app.get("/history", response_class=HTMLResponse)
    async def history(q: str = ""):
        state = doc()
        ws = S.workouts(state)
        if not ws:
            return no_data("History")
        u, needle = S.unit(state), q.strip().lower()
        if needle:
            ws = [w for w in ws if needle in (w.get("name") or "").lower()
                  or any(needle in S.ex_name(e.get("id"), state, e).lower() or needle in S.name_of(e.get("id"), state).lower() for e in S.entries(w))]
        months = {}
        for w in ws:
            months.setdefault(S.day(w)[:7], []).append(w)
        search = (f'<form method="get" action="/history" class="noprint" role="search"><input type="search" name="q" value="{escape(q)}" '
                  f'placeholder="{t("Exercise or workout")}" aria-label="{t("Search workouts")}" style="width:240px"></form>')
        body = head(t("History"), tn(len(ws), "{n} workout", "{n} workouts") + (t(" with “{q}”", q=escape(q)) if needle else ""), search)
        for m, mws in months.items():
            body += section(fd(D(m + "-01"), "month"), group([workout_row(w, state, u) for w in mws]),
                            sub=f'{tn(len(mws), "{n} workout", "{n} workouts")} · {fmt(work_volume(mws))} {u}')
        if not months:
            body += group([], "No workout matches.")
        return page("History", body)

    @app.get("/history/{wid}", response_class=HTMLResponse)
    async def workout(wid: str):
        state = doc()
        w = next((w for w in S.workouts(state) if str(w.get("id")) == wid), None)
        if not w:
            return page("History", head(t("Not found"), back=(t("History"), "/history")) + group([], "No workout with that id."))
        u, prs = S.unit(state), prs_of(w)
        s, e = S.num(w.get("start")), S.num(w.get("end"))
        when = fd(D(S.day(w)), "longy")
        if s and e:
            when += f" · {dt.datetime.fromtimestamp(s / 1000):%H:%M}–{dt.datetime.fromtimestamp(e / 1000):%H:%M}"
        gym = (w.get("gym") or {}).get("name") if isinstance(w.get("gym"), dict) else None
        strip = [(t("Duration"), duration(S.minutes(w)), "", ""), (t("Working sets"), str(S.work_sets(w)), "", ""),
                 (t("Volume"), fmt(S.volume(w)), u, ""), (t("Records"), str(len(prs)), "", "")]
        if S.num(w.get("bw")):
            strip.append((t("Body weight"), fmt(w["bw"], 1), u, ""))
        name = w.get("name") or t("Workout")
        act = f'<a class="btn plain" href="/motion/{quote(wid)}">{icon("motion", 14)} {t("Motion data")}</a>' if motion_of(state).get(wid) else ""
        body = head(name, escape(when + (f" · {gym}" if gym else "")), act, back=(t("History"), "/history")) + stats(strip)
        if w.get("note"):
            body += section(t("Note"), f'<div class="card">{escape(str(w["note"]))}</div>')
        for ent in S.entries(w):
            ex = str(ent.get("id"))
            rows, n = [], 0
            for x in S.sets(ent):
                warm = S.is_warmup(x)
                n += 0 if warm else 1
                label = "W" if warm else str(n)
                side = [(k, x["sides"][k]) for k in ("L", "R")] if S.is_side(x) else [("", x)]
                for k, y in side:
                    hr = x.get("hr") if isinstance(x.get("hr"), dict) else {}
                    rows.append(f'<tr class="{"dim" if warm else "" if y.get("done") is True else "off"}"><td>{label}{f" · {k}" if k else ""}</td>'
                                f'<td class=r>{kg(y["w"]) + " " + u if S.num(y.get("w")) is not None else "–"}</td>'
                                f'<td class=r>{fmt(y["r"]) if S.num(y.get("r")) is not None else "–"}</td>'
                                f'<td class=r>{fmt(y["rir"]) if S.num(y.get("rir")) is not None else ""}</td>'
                                f'<td class=r>{fmt(hr["avg"]) if S.num(hr.get("avg")) else ""}</td></tr>')
            b = S.best_set(ent)
            sub = t("best {w} × {r} · e1RM {e}", w=f"{kg(b[1])} {u}", r=fmt(b[2]), e=fmt(b[0], 1)) if b else ""
            badge = f'<span class="badge">{t("PR")}</span>' if ex in prs else ""
            note = (ent.get("target") or {}).get("note") if isinstance(ent.get("target"), dict) else None
            tbl = table([t("Set"), t("Weight") + ">", t("Reps") + ">", t("RIR") + ">", t("Heart rate") + ">"], rows)
            if note:
                tbl = tbl.replace('<div class="card">', f'<div class="card"><p class="lede" style="margin:0 0 10px">{escape(note)}</p>', 1)
            body += (f'<section class="sec"><div class="sec-h"><h2><a href="/exercises/{quote(ex)}" style="color:inherit">{escape(S.ex_name(ex, state, ent))}</a>{badge}</h2>'
                     f'<span>{sub}</span></div>{tbl}</section>')
        body += f'<p class="note">{t("Warm-ups are dimmed, sets not ticked are struck through. Edit a workout on the phone.")}</p>'
        return page("History", body, name)

    # MARK: Plan

    @app.get("/plan", response_class=HTMLResponse)
    async def plan():
        state, today = doc(), dt.date.today()
        rs = S.routines(state)
        if not rs:
            return page("Plan", head(t("Plan")) + group([], "No routines yet. Make one on the phone."))
        u, wst, iso = S.unit(state), S.week_start(state), today.isoformat()
        start = D(S.week_key(iso, wst))
        days = []
        for i in range(7):
            d = start + dt.timedelta(days=i)
            got = [w.get("name") or t("Workout") for w in S.workouts(state) if S.day(w) == d.isoformat()]
            ids = P.routine_ids(state, d.isoformat(), iso)
            badge = f' <span class="badge">{t("Today")}</span>' if d == today else ""
            end = (escape(", ".join(got)) + " ✓") if got else escape(", ".join(routine_names(state, ids))) or f'<span class="muted">{t("Rest")}</span>'
            days.append(row(fd(d, "A") + badge, fd(d), end))
        left = P.workouts_left(state, iso)
        mode = P.schedule_mode(state)
        sub = " · ".join(x for x in (tn(len(rs), "{n} routine", "{n} routines"), t(mode if mode == "rotation" else "weekly plan"),
                                     t("{n} workouts a week", n=left["of"]) if left else "") if x)
        body = head(t("Plan"), sub) + section(t("This week"), group(days), sub=t("Week of {d}", d=fd(start)),
                                               lede=t("What each day of this week holds, as the phone plans it. Change the plan on the phone."))
        rot = state.get("rotation") if isinstance(state.get("rotation"), dict) else {}
        seq = [x for x in (rot.get("sequence") or []) if isinstance(x, str)]
        if mode == "rotation" and seq:
            steps = [t("Rest") if x == P.REST else escape((routine_names(state, [x]) or [x])[0]) for x in seq]
            body += section(t("Rotation"), f'<div class="card">{" → ".join(steps)}</div>', lede=t("The loop the rotation works through, in order."))
        order = [(wst + i) % 7 for i in range(7)]
        week = state.get("week") if isinstance(state.get("week"), dict) else {}
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
            on = [fd(start + dt.timedelta(days=i), "a") for i, wd in enumerate(order)
                  if r["id"] in ([week.get(str(wd))] if isinstance(week.get(str(wd)), str) else week.get(str(wd)) or [])]
            body += section(r.get("name") or t("Workout"), table([t("Exercise"), t("Sets × reps") + ">", t("Weight") + ">", t("Rest") + ">"], rows),
                            sub=t("{n} exercises · {s} sets", n=len(rows), s=fmt(sets_n)) + (f" · {', '.join(on)}" if on else ""))
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
            return no_data("Exercises")
        u, needle = S.unit(state), q.strip().lower()
        rows = []
        for i, n, last in trained:
            nm = S.ex_name(i, state)
            if needle and needle not in nm.lower() and needle not in S.name_of(i, state).lower():
                continue
            best = max((s["est"] for s in S.exercise_sessions(state, i) if s["est"]), default=None)
            rows.append(row(escape(nm), tn(n, "{n} session · last {d}", "{n} sessions · last {d}", d=fd(D(last))),
                            f"{t('e1RM')} {fmt(best, 1)} {u}" if best else "", f"/exercises/{quote(i)}"))
        search = (f'<form method="get" action="/exercises" role="search"><input type="search" name="q" value="{escape(q)}" '
                  f'placeholder="{t("Find an exercise")}" aria-label="{t("Find an exercise")}" style="width:220px"></form>')
        return page("Exercises", head(t("Exercises"), t("{n} trained, most recent first", n=len(trained)), search) + group(rows, "No exercise matches."))

    @app.get("/exercises/{ex}", response_class=HTMLResponse)
    async def exercise(ex: str):
        state = doc()
        ses = S.exercise_sessions(state, ex)
        nm = S.ex_name(ex, state)
        back = (t("Exercises"), "/exercises")
        if not ses:
            return page("Exercises", head(nm, back=back) + group([], "No working sets logged for this exercise."), nm)
        u = S.unit(state)
        mw = sorted(S.muscle_weights(ex, state).items(), key=lambda kv: -kv[1])
        muscles = ", ".join(S.muscle_name(k) for k, v in mw if v >= .5) or ", ".join(S.muscle_name(k) for k, _ in mw[:2])
        est = [s for s in ses if s["est"]]
        best = max(est, key=lambda s: s["est"]) if est else None
        heavy = max((s for s in ses if s["w"]), key=lambda s: s["w"], default=None)
        strip = [(t("Best e1RM"), fmt(best["est"], 1) if best else "–", u if best else "", fd(D(best["d"]), "dy") if best else ""),
                 (t("Heaviest set"), kg(heavy["w"]) if heavy else "–", f"{u} × {fmt(heavy['r'])}" if heavy else "", fd(D(heavy["d"]), "dy") if heavy else ""),
                 (t("Sessions"), str(len(ses)), "", t("since {d}", d=fd(D(ses[0]["d"]), "dy"))),
                 (t("Last time"), fd(D(ses[-1]["d"])), "", f'{tn(ses[-1]["sets"], "{n} set", "{n} sets")} · {fmt(ses[-1]["volume"])} {u}')]
        pts = [(D(s["d"]), s["est"]) for s in est]
        change = t("From {a} to {b} {u} over {n} sessions.", a=fmt(pts[0][1], 1), b=fmt(pts[-1][1], 1), u=u, n=len(pts)) if len(pts) > 1 else ""
        rows = [f'<tr><td><a href="/history/{quote(str(s["id"]))}">{fd(D(s["d"]), "wdy")}</a>{"<span class=badge>" + t("PR") + "</span>" if s["pr"] else ""}</td>'
                f'<td class=r>{kg(s["w"]) + " " + u + " × " + fmt(s["r"]) if s["w"] else "–"}</td><td class=r>{fmt(s["est"], 1) if s["est"] else "–"}</td>'
                f'<td class=r>{s["sets"]}</td><td class=r>{fmt(s["volume"])} {u}</td></tr>' for s in reversed(ses)]
        body = (head(nm, escape(muscles), back=back) + stats(strip)
                + section(t("Estimated 1RM per session"), f'<div class="card">{line(pts, label=t("Estimated 1RM per session"), fmt_v=lambda v: fmt(v, 1 if v < 20 else 0))}</div>',
                          sub=u, lede=change)
                + section(t("Sessions"), table([t("Date"), t("Best set") + ">", t("e1RM") + ">", t("Sets") + ">", t("Volume") + ">"], rows))
                + f'<p class="note">{t("Estimated 1RM uses the Epley formula, weight × (1 + reps / 30), on ticked working sets.")}</p>')
        return page("Exercises", body, nm)

    # MARK: Body

    @app.get("/body", response_class=HTMLResponse)
    async def body_page(range: str = "3m"):
        state, today = doc(), dt.date.today()
        u, bw, ms = S.unit(state), S.weigh_ins(state), S.measurements(state)
        if not bw and not ms:
            return page("Body", head(t("Body")) + group([], "No weigh-ins or measurements yet. Log them on the phone."))
        out = head(t("Body"), f'{tn(len(bw), "{n} weigh-in", "{n} weigh-ins")} · {tn(len(ms), "{n} measurement", "{n} measurements")}')
        if bw:
            def ago(days):
                cut = (today - dt.timedelta(days=days)).isoformat()
                old = [v for d, v in bw if d <= cut]
                return f"{'+' if bw[-1][1] - old[-1] >= 0 else '−'}{fmt(abs(bw[-1][1] - old[-1]), 1)}" if old else "–"
            goal = S.num(state.get("targetW"))
            goal = goal if goal and goal > 0 else None
            strip = [(t("Latest"), fmt(bw[-1][1], 1), u, fd(D(bw[-1][0]), "dy")), (t("30 days"), ago(30), u, t("change")), (t("90 days"), ago(90), u, t("change"))]
            if goal:
                strip.append((t("Goal"), fmt(goal, 1), u, t("{v} to go", v=f"{fmt(abs(bw[-1][1] - goal), 1)} {u}")))
            range = range if range in ("1y", "all") else "3m"
            span = {"3m": 92, "1y": 366}.get(range)
            pts = [(D(d), v) for d, v in bw if not span or d >= (today - dt.timedelta(days=span)).isoformat()]
            ctl = seg([(t("3 months"), "/body?range=3m", "3m"), (t("1 year"), "/body?range=1y", "1y"), (t("All"), "/body?range=all", "all")], range)
            out += stats(strip) + section(t("Body weight"), f'<div class="card">{line(pts, label=t("Body weight"), goal=goal)}</div>',
                                          sub=f'{u}</span><span style="margin-left:auto">{ctl}',
                                          lede=t("{n} weigh-ins in this range.", n=len(pts)) + (t(" The dashed line is your goal.") if goal else ""))
            weigh = table([t("Date"), t("Weight") + ">"], [f"<tr><td>{fd(D(d), 'wdy')}</td><td class=r>{fmt(v, 1)} {u}</td></tr>" for d, v in reversed(bw[-20:])])
        else:
            weigh = group([], "No weigh-ins yet.")
        if ms:
            series = {}
            for d, vals in ms:
                for k, (v, unit_) in vals.items():
                    series.setdefault(k, []).append((d, v, unit_))
            rows = [f'<tr><td>{escape(tm(k))}</td><td class=r>{fmt(s[-1][1], 1)} {escape(s[-1][2])}</td><td class=r>{fd(D(s[-1][0]))}</td>'
                    f'<td class=r>{"" if len(s) < 2 else ("+" if s[-1][1] >= s[0][1] else "−") + fmt(abs(s[-1][1] - s[0][1]), 1)}</td></tr>' for k, s in series.items()]
            meas = table([t("Measure"), t("Latest") + ">", t("Date") + ">", t("Since first") + ">"], rows)
        else:
            meas = group([], "No measurements yet.")
        out += '<div class="grid2">' + section(t("Measurements"), meas) + section(t("Weigh-ins"), weigh, sub=t("latest 20")) + "</div>"
        return page("Body", out)

    # MARK: Stats

    @app.get("/stats", response_class=HTMLResponse)
    async def stats_page(range: str = "3m"):
        state, today = doc(), dt.date.today()
        ws = S.workouts(state)
        if not ws:
            return no_data("Stats")
        range = range if range in ("4w", "3m", "1y") else "3m"
        weeks_n = {"4w": 4, "3m": 13, "1y": 52}[range]
        u, wst = S.unit(state), S.week_start(state)
        first = D(S.week_key(today.isoformat(), wst)) - dt.timedelta(weeks=weeks_n - 1)
        rws = in_range(ws, first, today)
        mins = [m for m in (S.minutes(w) for w in rws) if m]
        strip = stats([(t("Workouts"), str(len(rws)), "", t("{v} a week", v=fmt(len(rws) / weeks_n, 1))),
                       (t("Volume"), compact(work_volume(rws)), u, t("{v} a week", v=f"{compact(work_volume(rws) / weeks_n)} {u}")),
                       (t("Working sets"), fmt(sum(S.work_sets(w) for w in rws)), "", ""),
                       (t("Time trained"), f"{sum(mins) // 60}", t("h"), t("{v} a workout", v=duration(round(sum(mins) / len(mins)))) if mins else "")])
        ctl = seg([(t("4 weeks"), "/stats?range=4w", "4w"), (t("3 months"), "/stats?range=3m", "3m"), (t("1 year"), "/stats?range=1y", "1y")], range)
        weeks = by_week(ws, state, weeks_n, today)
        busiest = max(weeks, key=lambda x: x[1])
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
        top_rows = group([row(escape(S.ex_name(i, state)), end=tn(n, "{n} set", "{n} sets"), href=f"/exercises/{quote(i)}") for i, n in tops], "No sets in this range.")
        trained_days = len([d for d in days if d >= (today - dt.timedelta(days=364)).isoformat()])
        vbars = bars([(fd(s, "dm"), v, t("Week of {d}: {v}, {n} workouts", d=fd(s), v=f"{fmt(v)} {u}", n=n)) for s, v, n in weeks],
                     label=t("Weekly volume"), hi=weeks.index(busiest))
        body = (head(t("Stats"), f"{fd(first, 'dy')} – {fd(today, 'dy')}", ctl) + strip
                + section(t("Consistency"), f'<div class="card">{heat(days, today, 53, wst, u)}</div>', sub=t("last 12 months"),
                          lede=t("{n} training days in the last year; darker days moved more weight.", n=trained_days))
                + section(t("Weekly volume"), f'<div class="card">{vbars}</div>', sub=u,
                          lede=t("The busiest week, highlighted, was {d} with {v}.", d=fd(busiest[0]), v=f"{fmt(busiest[1])} {u}"))
                + '<div class="grid2">'
                + section(t("Muscle balance"), f'<div class="card">{balance}</div>', sub=t("average sets a week"),
                          lede=t("Working sets per muscle, averaged over the range, against each weekly range."))
                + section(t("Most trained"), top_rows, sub=t("by working sets"))
                + "</div>")
        return page("Stats", body)

    # MARK: Report

    @app.get("/report", response_class=HTMLResponse)
    async def report(range: str = "4w"):
        state, today = doc(), dt.date.today()
        ws = S.workouts(state)
        if not ws:
            return no_data("Report")
        range = range if range in ("7d", "4w", "3m") else "4w"
        a, b = range_of(range, today)
        n_days = (b - a).days + 1
        rws, pws = in_range(ws, a, b), in_range(ws, a - dt.timedelta(days=n_days), a - dt.timedelta(days=1))
        u = S.unit(state)
        mins, pmins = sum(S.minutes(w) or 0 for w in rws), sum(S.minutes(w) or 0 for w in pws)
        sets_, psets = sum(S.work_sets(w) for w in rws), sum(S.work_sets(w) for w in pws)
        strip = stats([(t("Workouts"), str(len(rws)), "", delta(len(rws), len(pws))),
                       (t("Volume"), compact(work_volume(rws)), u, delta(work_volume(rws), work_volume(pws))),
                       (t("Working sets"), fmt(sets_), "", delta(sets_, psets)),
                       (t("Time"), duration(mins) if mins else "–", "", delta(mins, pmins, " " + t("{n} min", n="").strip()))])
        ctl = seg([(t("7 days"), "/report?range=7d", "7d"), (t("4 weeks"), "/report?range=4w", "4w"), (t("3 months"), "/report?range=3m", "3m")], range)
        act = f'<span class="noprint">{ctl}</span><button class="noprint" onclick="print()">{icon("print", 14)} {t("Print")}</button>'
        recs = []
        for w in reversed(rws):
            for ex in prs_of(w):
                bs = next((S.best_set(e) for e in S.entries(w) if str(e.get("id")) == ex), None)
                recs.append(f'<tr><td>{escape(S.ex_name(ex, state))}</td><td class=r>{f"{kg(bs[1])} {u} × {fmt(bs[2])}" if bs else ""}</td>'
                            f'<td class=r>{fmt(bs[0], 1) if bs else ""}</td><td class=r>{fd(D(S.day(w)))}</td></tr>')
        load = S.load_of(rws, state)
        muscles = sorted(((S.muscle_name(k), v) for k, v in load.items() if v >= .5), key=lambda kv: -kv[1])[:10]
        bw = [(d, v) for d, v in S.weigh_ins(state) if a.isoformat() <= d <= b.isoformat()]
        wrows = [f'<tr><td style="white-space:nowrap"><a href="/history/{quote(str(w.get("id")))}">{fd(D(S.day(w)), "wd")}</a></td><td>{escape(w.get("name") or t("Workout"))}'
                 f'<div class=muted style=font-size:12px>{names(w, state, 6)}</div></td><td class=r>{duration(S.minutes(w))}</td>'
                 f'<td class=r>{S.work_sets(w)}</td><td class=r>{fmt(S.volume(w))} {u}</td></tr>' for w in reversed(rws)]
        body = (head(t("Training report"), t("{a} – {b} · {n} days, compared with the {n} days before", a=fd(a, "dy"), b=fd(b, "dy"), n=n_days), act) + strip
                + '<div class="grid2">'
                + section(t("Records"), table([t("Exercise"), t("Set") + ">", t("e1RM") + ">", t("Date") + ">"], recs, t("No records in this range.")),
                          sub=t("{n} new", n=len(recs)))
                + section(t("Muscles worked"), table([t("Muscle"), t("Sets") + ">"], [f"<tr><td>{escape(k)}</td><td class=r>{fmt(S.js_round1(v), 1)}</td></tr>" for k, v in muscles],
                                                     t("No working sets.")), sub=t("effective working sets"))
                + "</div>"
                + (section(t("Body weight"), f'<div class="card">{line([(D(d), v) for d, v in bw], height=150, label=t("Body weight"))}</div>',
                           sub=f"{fmt(bw[0][1], 1)} → {fmt(bw[-1][1], 1)} {u}") if bw else "")
                + section(t("Every workout"), table([t("Date"), t("Workout"), t("Time") + ">", t("Sets") + ">", t("Volume") + ">"], wrows, t("No workouts in this range.")))
                + f'<p class="note">{t("Made by Hexplate on {d}. The phone makes the same report as a PDF (Settings › Report).", d=fd(today, "dy"))}</p>')
        return page("Report", body, t("Training report"))

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
            ex_rows.append(f"<tr><td>{escape(S.ex_name(ex, state))}</td><td class=r>{len(fs)}</td><td class=r>{len(r)}</td>"
                           f"<td class=r>{f'{e}/{len(r)}' if r else '–'}</td><td class=r>{fmt(m, 2) if m is not None else '–'}</td></tr>")
        recent = []
        for f in files[:15]:
            off = f["auto"] - f["reps"] if rated(f) else None
            off_text = "" if off is None else ("0" if off == 0 else f'<span class="warn">{off:+d}</span>')
            weight = f"{kg(f['w'])} kg" if isinstance(f.get("w"), (int, float)) else "–"
            recent.append(f"<tr><td>{fd(dt.datetime.fromtimestamp(f['end'] / 1000), 'dt')}</td><td>{escape(S.ex_name(str(f.get('exId')), state))}</td>"
                          f"<td class=r>{weight}</td><td class=r>{f.get('auto', '–')}</td><td class=r>{f.get('reps', '–')}</td><td class=r>{off_text}</td></tr>")
        strip = stats([(t("Sets recorded"), str(len(files)), "", t("{n} exercises", n=len(per))),
                       (t("Confirmed"), str(len(checked)), "", t("counts checked on the watch")),
                       (t("Exact"), str(round(100 * exact / len(checked))) if checked else "–", "%", t("{a} of {b} counted right", a=exact, b=len(checked))),
                       (t("Mean error"), fmt(mae, 2) if mae is not None else "–", t("reps"), t("live count vs confirmed"))])
        note = t("Live is the watch's own count; Final is the count after you corrected it on the watch. The full check against the phone's log is analysis/motion_check.py.")
        body = (head(t("Rep counter"), t("How well the watch counts your reps")) + strip
                + section(t("By exercise"), table([t("Exercise"), t("Sets") + ">", t("Checked") + ">", t("Exact") + ">", t("Error") + ">"], ex_rows, t("No motion files yet.")))
                + section(t("Latest sets"), table([t("When"), t("Exercise"), t("Weight") + ">", t("Live") + ">", t("Final") + ">", t("Off") + ">"], recent, t("No sets yet.")))
                + f'<p class="note">{note}</p>')
        return page("Rep counter", body)

    # MARK: Motion data

    def flag_text(f):
        """A quality flag in the page's language: the number goes into the template ("gap {v} s")."""
        v = re.search(r"\d+(\.\d+)?", f)
        return t(f.replace(v.group(0), "{v}", 1), v=v.group(0)) if v else t(f)

    def motion_of(state):
        return M.by_workout(store.motion_meta(), S.workouts(state))

    @app.get("/motion", response_class=HTMLResponse)
    async def motion_list():
        state = doc()
        per = motion_of(state)
        ws = [w for w in S.workouts(state) if str(w.get("id")) in per]
        ws.sort(key=lambda w: S.num(w.get("start")) or 0, reverse=True)
        rows = [row(escape(w.get("name") or t("Workout")), names(w, state), t("{n} sets", n=len(per[str(w["id"])])),
                    f"/motion/{quote(str(w.get('id')))}", date_lead(D(S.day(w)))) for w in ws]
        loose = len(store.motion_meta()) - sum(len(v) for v in per.values())
        note = t("{n} set files belong to no saved workout.", n=loose) if loose else ""
        body = (head(t("Motion data"), t("What the watch recorded in each workout")) + group(rows, "No motion files yet.")
                + (f'<p class="note">{note}</p>' if note else ""))
        return page("Motion data", body)

    @app.get("/motion/{wid}", response_class=HTMLResponse)
    async def motion_workout(wid: str):
        state = doc()
        w = next((w for w in S.workouts(state) if str(w.get("id")) == wid), None)
        metas = motion_of(state).get(wid, []) if w else []
        if not metas:
            return page("Motion data", head(t("Not found"), back=(t("Motion data"), "/motion")) + group([], "No motion files for this workout."))
        rows = M.sets(store.motion_dir, metas, w)
        name = lambda r: S.ex_name(str(r["meta"].get("exId")), state)
        per_ex, n = {}, {}
        for r in rows:
            ex = str(r["meta"].get("exId"))
            per_ex.setdefault(ex, []).append(r)
            n[ex] = n.get(ex, 0) + 1
            r["label"] = f"{list(per_ex).index(ex) + 1}.{n[ex]}"
            r["tip"] = f"{name(r)} · {t('set {n}', n=r['meta'].get('set') or n[ex])}"
        clean = [r for r in rows if not r["flags"]]
        counts = {}
        for r in rows:
            for f in r["flags"]:
                k = re.sub(r"\d+(\.\d+)?", "#", f)
                counts[k] = (counts.get(k, (0, f))[0] + 1, f)
        secs = sum(r["q"].get("dur_s", 0) for r in rows)

        # 1. What there is
        strip = stats([(t("Sets recorded"), str(len(rows)), "", t("{n} exercises", n=len(per_ex))),
                       (t("Clean"), str(len(clean)), "", t("no quality flag")),
                       (t("Recorded"), duration(round(secs / 60)), "", t("of motion at 50 Hz")),
                       (t("Rows"), compact(sum(r["q"].get("rows", 0) for r in rows)), "", t("samples"))])
        ex_rows = [f"<tr><td>{list(per_ex).index(ex) + 1}. {escape(name(rs[0]))}</td><td class=r>{len(rs)}</td><td class=r>{sum(not r['flags'] for r in rs)}</td>"
                   f"<td>{escape(', '.join(sorted({flag_text(f) for r in rs for f in r['flags']})) or '–')}</td></tr>" for ex, rs in per_ex.items()]
        flag_rows = [f"<tr><td>{escape(flag_text(f))}</td><td class=r>{c}</td></tr>" for c, f in sorted(counts.values(), key=lambda v: -v[0])]
        body = (head(t("Motion data"), escape(f"{w.get('name') or t('Workout')} · {fd(D(S.day(w)), 'longy')}"),
                     f'<a class="btn plain" href="/history/{quote(wid)}">{icon("history", 14)} {t("Workout")}</a>', back=(t("Motion data"), "/motion")) + strip
                + '<div class="grid2">'
                + section(t("1. What there is"), table([t("Exercise"), t("Sets") + ">", t("Clean") + ">", t("Flags")], ex_rows))
                + section(t("Flags"), table([t("Flag"), t("Sets") + ">"], flag_rows, t("Every set is clean.")))
                + "</div>")

        # 2. Sampling, 3. Window
        pts = lambda k, flag: [(r["label"], r["q"][k], f"{r['tip']}: {r['q'][k]}", any(f.startswith(flag) for f in r["flags"]))
                               for r in rows if r["q"].get(k) is not None]
        hz = pts("hz", "rate")
        chart = lambda title, svg, legend: f'<div class="card"><h3 class="ch">{title}</h3>{key(legend)}{svg}</div>'
        ref = lambda text: [("ref", text)]
        body += section(t("2. Sampling: 50 Hz, no gaps?"), '<div class="grid2">'
                        + chart(t("Sample rate (Hz)"), per_set(hz, 50, t("Sample rate"), lo=min([45] + [p[1] for p in hz])), ref(t("50 Hz target")))
                        + chart(t("Largest gap (s, log scale)"), per_set(pts("max_gap_s", "gap"), .1, t("Largest gap"), log=True), ref(t("0.1 s: flagged above")))
                        + "</div>", lede=t("Each dot is a set; the x-axis labels are exercise.set as numbered in the table above."))
        body += section(t("3. Does the window hold the whole set?"), '<div class="grid2">'
                        + chart(t("Head: first second"), per_set(pts("head", "clipped start"), .6, t("Head")), [("ref", t("0.6: busy")), ("pt flag", t("clipped start"))])
                        + chart(t("Tail: last second"), per_set(pts("tail", "clipped end"), .6, t("Tail")), [("ref", t("0.6: busy")), ("pt flag", t("clipped end"))])
                        + "</div>", lede=t("How busy the first and last second is, against the set's 90th-percentile activity. A busy start with no rep in the first 2 s is the walk to the machine; a busy end would be a set cut before it finished."))

        # 4. One set per exercise: the last clean one
        legend = [("s1", "x"), ("s2", "y"), ("s3", "z"), ("mag", t("magnitude")), ("tick", t("rep counted live"))]
        cards = []
        for ex, rs in per_ex.items():
            r = ([x for x in rs if not x["flags"]] or rs)[-1]
            c = r["cols"]
            mag = M.smooth([math.sqrt(x * x + y * y + z * z) for x, y, z in zip(c["ax"], c["ay"], c["az"])])
            ticks = [e[0] for e in r["meta"].get("helpers", {}).get("log", []) if isinstance(e, list) and len(e) > 1 and isinstance(e[1], str) and e[1].startswith("rep ")]
            title = t("{name}: {reps} reps logged, {auto} counted live", name=name(r), reps=fmt(r["reps"]) if isinstance(r["reps"], (int, float)) else "–",
                      auto=r["auto"] if r["auto"] is not None else "–")
            cards.append(f'<div class="card"><h3 class="ch">{escape(title)}</h3>{traces(c, mag, ticks, title)}</div>')
        body += section(t("4. One set per exercise"), key(legend) + "".join(cards), lede=t("User acceleration (g) and its smoothed magnitude; ticks: reps the watch counted live."))

        # 5. Live count vs logged
        live = M.live_rows(rows)
        lrows = [f"<tr><td>{escape(S.ex_name(ex, state))}</td><td class=r>{k}</td><td class=r>{fmt(m, 1)}</td><td class=r>{fmt(e, 2)}</td>"
                 f"<td class=r>{round(100 * x)}%</td><td class=r>{b:+.2f}</td></tr>" for ex, k, m, e, x, b in live]
        sc = [(r["reps"], r["auto"], f"{r['tip']}: {fmt(r['reps'])} → {r['auto']}") for r in clean if r["auto"] is not None and isinstance(r["reps"], (int, float))]
        body += section(t("5. The watch's live count against the logged reps"), '<div class="grid2">'
                        + table([t("Exercise"), t("Sets") + ">", t("Reps") + ">", t("Error") + ">", t("Exact") + ">", t("Bias") + ">"], lrows, t("No clean sets with a live count."))
                        + f'<div class="card">{key([("tick", t("on the line: exact"))])}{scatter(sc, t("logged reps"), t("live count"), t("Live count vs logged"))}</div>'
                        + "</div>", lede=t("Clean sets only. Error is the mean miss in reps; bias above zero means the watch counts too many."))

        # 6. Findings
        found = [t("{a} of {b} sets are clean.", a=len(clean), b=len(rows))]
        if counts:
            c, f = max(counts.values(), key=lambda v: v[0])
            found.append(t("Most common flag: {f} ({n} sets).", f=flag_text(f), n=c))
        if sc:
            err = [a - r for r, a, _ in sc]
            found.append(t("Live count: exact on {x} of {n} clean sets, mean error {e} reps, bias {b:+.2f}.",
                           x=sum(e == 0 for e in err), n=len(err), e=fmt(sum(map(abs, err)) / len(err), 2), b=sum(err) / len(err)))
            worst = max(live, key=lambda r: r[3])
            if worst[3] > 0:
                found.append(t("Hardest to count: {ex} (mean error {e}).", ex=S.ex_name(worst[0], state), e=fmt(worst[3], 2)))
        body += section(t("6. Findings"), '<div class="card"><ul class="list">' + "".join(f"<li>{escape(x)}</li>" for x in found) + "</ul></div>")
        return page("Motion data", body, t("Motion data"))

    # MARK: Sync & backup

    def confirm(text):
        return escape(json.dumps(text), quote=True)

    def data_page(req: Request, code: str | None = None):
        port = req.url.port or 8765
        address = f"http://{local_name()}.local:{port}"
        ip = wifi_address()
        fallback = t(" If the phone cannot reach it, try {a}.", a=f"<b>http://{ip}:{port}</b>") if ip else ""
        how = t("Works once, for 5 minutes. On the phone: Settings › Server, address {a}, then this code.", a=f'<b style="color:var(--ink)">{escape(address)}</b>')
        pair = (f'<div class="code">{code}</div><div class="muted">{how}{fallback}</div>' if code else
                f'<p class="muted" style="margin:0 0 14px">{t("A code lets one phone sync with this Mac. It works once, for 5 minutes.")}</p>'
                f'<form method="post" action="/data/pair"><button>{t("New pairing code")}</button></form>')
        unpair = confirm(t("Unpair this phone? It stops syncing until it is paired again."))
        phones = [row(t("Phone {n}", n=i + 1), t("Paired {d}", d=fd(dt.datetime.fromtimestamp(at), "dt")),
                      f"""<form method="post" action="/data/revoke" onsubmit="return confirm({unpair})">
<input type="hidden" name="h" value="{h}"><button class="plain small">{t("Unpair")}</button></form>""") for i, (h, at) in enumerate(store.tokens())]
        versions = []
        for rev, at, n, size in store.versions():
            ask = confirm(t("Make rev {rev} the current copy? The phone takes it on its next sync and merges in anything it changed since. No version is deleted.", rev=rev))
            versions.append(f"""<tr><td>rev {rev}</td><td>{fd(dt.datetime.fromtimestamp(at), "wdt")}</td><td class=r>{n or 0}</td>
<td class=r>{fmt(size / 1024)} KB</td><td class=r><a class="btn plain small" href="/data/rev/{rev}.json" download>{t("Download")}</a>
<form method="post" action="/data/restore" onsubmit="return confirm({ask})">
<input type="hidden" name="rev" value="{rev}"><button class="plain small">{t("Restore")}</button></form></td></tr>""")
        act = (f'<a class="btn plain" href="/data/sets.csv" download>{t("Sets (CSV)")}</a>'
               f'<a class="btn" href="/data/latest.json" download>{t("Download backup")}</a>')
        body = (head(t("Sync & backup"), t("Pair phones, keep every version, download your data"), act)
                + '<div class="grid2">' + section(t("Pair a phone"), f'<div class="card">{pair}</div>')
                + section(t("Paired phones"), group(phones, "No phone paired yet.")) + "</div>"
                + section(t("Versions"), table([t("Version"), t("Received"), t("Workouts") + ">", t("Size") + ">", ">"], versions, t("No data yet.")),
                          sub=t("latest 30"),
                          lede=t("Every copy the phone sends is kept. The backup is the openGym JSON the app imports; the CSV has one row per set, for a spreadsheet.")))
        return page("Sync & backup", body)

    async def form(req: Request):
        return {k: v[0] for k, v in parse_qs((await req.body()).decode()).items()}

    def to(path):
        return Response(status_code=303, headers={"Location": path})

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
        return to("/data")

    @app.post("/data/restore")
    async def restore(req: Request):
        rev = (await form(req)).get("rev", "")
        if not rev.isdigit() or not store.restore(int(rev)):
            return PlainTextResponse("No such version.", status_code=404)
        return to("/data")

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
                    out.writerow([S.day(w), w.get("name") or "", e.get("id"), S.name_of(e.get("id"), state), i, int(S.is_warmup(x)),
                                  int(x.get("done") is True), x.get("w", ""), x.get("r", ""), x.get("rir", ""), hr.get("avg", ""), u])
        return Response(buf.getvalue(), media_type="text/csv",
                        headers={"Content-Disposition": f'attachment; filename="hexplate-sets-{dt.date.today()}.csv"'})

    # MARK: Connect (webhooks and the MCP server)

    from .webhooks import EVENT_LABELS, EVENTS
    hooks = app.state.webhooks

    def connect_page(note=""):
        def status(h):
            word = t("Paused") if h["paused"] else t("Not sent yet") if h["last_ok"] is None else t("Delivered") if h["last_ok"] else t("Failed")
            when = f" · {fd(dt.datetime.fromtimestamp(h['last_at']), 'dt')}" if h["last_at"] else ""
            return f'<span class="{"warn" if h["last_ok"] is False and not h["paused"] else ""}">{word}</span>{when}' + (f" · {escape(h['last_msg'])}" if h["last_msg"] else "")
        forget = confirm(t("Delete this webhook? Its URL and secret are forgotten."))
        rows = [row(escape(h["label"] or "Webhook"), f'{escape(_mask(h["url"]))} · {", ".join(t(EVENT_LABELS[e]) for e in h["events"])}<br>{status(h)}',
                    f"""<form method="post" action="/connect/test"><input type="hidden" name="id" value="{h["id"]}"><button class="plain small">{t("Send test")}</button></form>
<form method="post" action="/connect/pause"><input type="hidden" name="id" value="{h["id"]}"><input type="hidden" name="paused" value="{0 if h["paused"] else 1}">
<button class="plain small">{t("Resume") if h["paused"] else t("Pause")}</button></form>
<form method="post" action="/connect/remove" onsubmit="return confirm({forget})">
<input type="hidden" name="id" value="{h["id"]}"><button class="danger small">{t("Delete")}</button></form>""") for h in hooks.all()]
        boxes = "".join(f'<label class="check"><input type="checkbox" name="events" value="{e}"{" checked" if e == "workout.finished" else ""}> {t(EVENT_LABELS[e])}</label>' for e in EVENTS)
        here = Path(__file__).resolve().parents[1]
        mcp = json.dumps({"mcpServers": {"hexplate": {"command": str(here / ".venv/bin/python"), "args": ["-m", "hexserver", "mcp"],
                                                       "env": {"PYTHONPATH": str(here)}}}}, indent=2)
        add = f"""<div class="card"><form method="post" action="/connect/add" style="display:grid;gap:12px">
<div style="display:grid;grid-template-columns:1fr 2fr;gap:10px"><input name="label" placeholder="{t("Name (optional)")}" maxlength="60" aria-label="{t("Name")}">
<input name="url" type="url" placeholder="{t("https://… (the URL your tool gave you)")}" required aria-label="{t("URL")}"></div>
<div>{boxes}</div><div><button>{t("Add webhook")}</button></div></form></div>"""
        body = (note + head(t("Connect"), t("Send your training to other tools"))
                + section(t("Webhooks"), group(rows, "No webhooks yet."),
                          lede=t("A signed JSON message to Home Assistant, n8n, Node-RED or ntfy when you finish a workout, set a record or weigh in. Sent when the phone syncs, for what happened in the last seven days."))
                + section(t("Add a webhook"), add)
                + '<p class="note"><code>X-Hexplate-Signature: t=&lt;seconds&gt;,v1=&lt;HMAC-SHA256 of "t.body"&gt;</code></p>'
                + section(t("MCP server"), f"<pre>{escape(mcp)}</pre>", sub=t("for AI assistants"),
                          lede="Claude Desktop: <code>~/Library/Application Support/Claude/claude_desktop_config.json</code> · Claude Code: <code>.mcp.json</code>"))
        return page("Connect", body)

    async def fields(req: Request):
        return parse_qs((await req.body()).decode())

    @app.get("/connect", response_class=HTMLResponse)
    async def connect():
        return connect_page()

    @app.post("/connect/add", response_class=HTMLResponse)
    async def connect_add(req: Request):
        f = await fields(req)
        try:
            _, secret = hooks.add(f.get("url", [""])[0], f.get("label", [""])[0], f.get("events", []))
        except ValueError as e:
            return connect_page(f'<div class="banner"><b>{t("Not added.")}</b> {escape(str(e))}</div>')
        return connect_page(f'''<div class="banner"><b>{t("Webhook added.")}</b> {t("Its signing secret, shown only now. Copy it into your tool:")}
<div class="code" style="font-size:16px;word-break:break-all;margin-top:8px">{escape(secret)}</div></div>''')

    @app.post("/connect/test", response_class=HTMLResponse)
    async def connect_test(req: Request):
        ok, msg = hooks.send_test((await fields(req)).get("id", [""])[0])
        return connect_page(f'<div class="banner"><b>{t("Test sent." if ok else "Test failed.")}</b> {escape(msg)}</div>')

    @app.post("/connect/pause")
    async def connect_pause(req: Request):
        f = await fields(req)
        hooks.pause(f.get("id", [""])[0], f.get("paused", ["0"])[0] == "1")
        return to("/connect")

    @app.post("/connect/remove")
    async def connect_remove(req: Request):
        hooks.remove((await fields(req)).get("id", [""])[0])
        return to("/connect")

    # MARK: Settings (language, backup)

    def settings_page(note=""):
        lang = LANG.get()
        langs = "".join(f'<button name="lang" value="{k}" class="{"on" if k == lang else ""}"{" aria-pressed=true" if k == lang else ""}>{label}</button>'
                        for k, label in (("en", "English"), ("zh", "中文")))
        st = backup.status()
        if not st["on"]:
            state_line = t("Backup is off: the phone deletes the Watch's recordings as soon as this Mac has them.")
        elif st["error"]:
            state_line = f'<span class="warn">{escape(t(st["error"]))}</span>'
        elif st["at"]:
            state_line = t("Last backup {d}", d=fd(dt.datetime.fromtimestamp(st["at"]), "wdt"))
        else:
            state_line = t("Not backed up yet")
        folder = f'{t("iCloud Drive")} › {escape(Path(st["folder"]).name)}' if st["in_icloud"] else escape(st["folder"])
        toggle = (f'<form method="post" action="/settings/backup"><input type="hidden" name="on" value="{0 if st["on"] else 1}">'
                  f'<button class="plain small">{t("Turn off") if st["on"] else t("Turn on")}</button></form>')
        rows = [row(t("Backup is on") if st["on"] else t("Backup is off"), state_line, toggle),
                row(t("Folder"), end=folder),
                row(t("Daily copies"), end=t("{n} of the latest {k} days", n=st["copies"], k=30)),
                row(t("Watch recordings"), end=t("{n} files", n=st["motion"]))]
        run = f'<form method="post" action="/settings/backup/run" style="display:block;margin-top:12px"><button>{t("Back up now")}</button></form>' if st["on"] else ""
        body = (note + head(t("Settings"), t("Language and backup"))
                + section(t("Language"), f'<form method="post" action="/settings/lang"><div class="seg" role="group">{langs}</div></form>',
                          lede=t("The dashboard's language. The phone keeps its own."))
                + section(t("Backup"), group(rows) + run,
                          lede=t("The Watch hands each set's recording to the phone, then deletes its own. The phone sends it to this Mac, which saves it and copies it to the backup; only then does the phone delete its copy. Your training log stays on the phone and is kept here in every version, copied to the backup a minute after each sync.")))
        return page("Settings", body)

    @app.get("/settings", response_class=HTMLResponse)
    async def settings():
        return settings_page()

    @app.post("/settings/lang")
    async def settings_lang(req: Request):
        lang = (await form(req)).get("lang")
        if lang in ("en", "zh"):
            store.set_setting("lang", lang)
        return to("/settings")

    @app.post("/settings/backup")
    async def settings_backup(req: Request):
        store.set_setting("backup", "on" if (await form(req)).get("on") == "1" else "off")
        return to("/settings")

    @app.post("/settings/backup/run", response_class=HTMLResponse)
    async def settings_backup_run():
        copied, ok = backup.everything()
        msg = t("Backed up: {n} new Watch recordings and the database.", n=copied) if ok else t("Backup failed.")
        return settings_page(f'<div class="banner"><b>{msg}</b></div>')
