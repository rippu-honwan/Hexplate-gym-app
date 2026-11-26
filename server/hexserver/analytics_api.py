"""Localhost-only JSON API for the React web dashboard (`/analytics/api/*`).

Mounted inside `dashboard.install()` BEFORE `/analytics/{path:path}` so it inherits `guard`
(loopback IP check, Host allowlist against DNS rebinding, and Origin/Sec-Fetch-Site CSRF checks on
every non-GET method) while staying completely separate from the phone's `/api/*` endpoints.

All AI config persistence, origin-binding, Coach context/preview/apply/undo, and SyncStamps logic
live in `ai.py` and `coach_web.py`; routes here stay thin and set `Cache-Control: no-store` on
every AI / Coach / Bootstrap response.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import re
import socket
import subprocess
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from fastapi import Request
from fastapi.responses import JSONResponse

from . import coach_web
from . import i18n
from . import motion as M
from . import schedule as P
from . import stats as S
from .ai import AIError, read_limited_json
from .i18n import LANG, LANG_OPTIONS, dashboard_zh_strings, tm
from .webhooks import EVENT_LABELS, EVENTS

_NO_STORE = {"Cache-Control": "no-store"}
_MAIN_MUSCLES = [slug for slug, _ in S.DEFAULT_TARGETS]
_SPLIT_KEYS = ("push", "pull", "legs", "upper", "lower")

_MCP_TOOLS = [
    {
        "name": "get_summary",
        "description": "Totals, last 5 workouts, this week's count and volume, latest body weight, and Watch motion count.",
    },
    {
        "name": "get_exercise_history",
        "description": "Per-session progression for one exercise (matched by words): best set, Epley 1RM, working sets, volume.",
    },
    {
        "name": "get_routines",
        "description": "Saved user routines with planned sets, reps/ranges, weight, hold seconds, cardio minutes, restSec, and notes.",
    },
    {
        "name": "get_schema",
        "description": "SQLite table definitions (workouts, sets, bodyweight, motion_files, documents) and SQL helpers exname()/e1rm().",
    },
    {
        "name": "run_query",
        "description": "Execute one read-only SQLite SELECT query (max 500 rows, 5 s timeout, authorizer-enforced read-only).",
    },
]


def _local_name() -> str:
    try:
        out = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True, timeout=2).stdout.strip()
        return out or socket.gethostname().removesuffix(".local")
    except OSError:
        return socket.gethostname().removesuffix(".local")


def _wifi_address() -> str | None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.168.0.1", 9))
            ip = s.getsockname()[0]
        return ip if not ip.startswith("127.") else None
    except OSError:
        return None


def _mask_url(url: str) -> str:
    u = urlsplit(url)
    return f"{u.scheme}://{u.netloc}" + ("/…" + u.path[-4:] if len(u.path) > 1 else "")


def _server_addresses(req: Request) -> dict[str, Any]:
    port = req.url.port or 8765
    ip = _wifi_address()
    return {
        "local": f"http://{_local_name()}.local:{port}",
        "ip": f"http://{ip}:{port}" if ip else None,
        "port": port,
    }


def _safe_today(raw: str | None) -> str:
    if isinstance(raw, str) and len(raw) == 10:
        try:
            d = dt.date.fromisoformat(raw)
            if d.isoformat() == raw:
                return raw
        except ValueError:
            pass
    return dt.date.today().isoformat()


def _prs_of(w: dict[str, Any]) -> list[str]:
    return [str(p if not isinstance(p, dict) else p.get("id") or p.get("ex")) for p in (w.get("prs") or [])]


def _infer_split(w: dict[str, Any], muscle_sets: dict[str, float]) -> str:
    name = str(w.get("name") or "").lower()
    for key in _SPLIT_KEYS:
        if re.search(rf"\b{key}\b", name):
            return key
    if any(k in name for k in ("chest", "shoulder", "tricep", "press")):
        return "push"
    if any(k in name for k in ("back", "bicep", "row")):
        return "pull"
    if any(k in name for k in ("leg", "squat", "quad", "glute", "hamstring")):
        return "legs"
    push_score = muscle_sets.get("chest", 0) + muscle_sets.get("deltoids", 0) + muscle_sets.get("triceps", 0)
    pull_score = muscle_sets.get("upper-back", 0) + muscle_sets.get("biceps", 0)
    legs_score = (
        muscle_sets.get("quadriceps", 0)
        + muscle_sets.get("hamstring", 0)
        + muscle_sets.get("gluteal", 0)
        + muscle_sets.get("calves", 0)
    )
    upper_score = push_score + pull_score
    if legs_score >= upper_score and legs_score > 0:
        return "legs"
    if push_score > 0 and pull_score > 0 and min(push_score, pull_score) >= 0.45 * max(push_score, pull_score):
        return "upper"
    if push_score >= pull_score and push_score > 0:
        return "push"
    if pull_score > 0:
        return "pull"
    return "upper"


def _top_exercise(w: dict[str, Any], state: dict[str, Any]) -> str:
    best_name = ""
    best_vol = -1.0
    for e in S.entries(w):
        done_sets = [s for s in S.sets(e) if S.done_units(s) and not S.is_warmup(s)]
        if not done_sets:
            continue
        vol = 0.0
        for s in done_sets:
            rows = [s["sides"]["L"], s["sides"]["R"]] if S.is_side(s) else [s]
            for r in rows:
                if r.get("done") is True:
                    vol += (S.num(r.get("w")) or 0.0) * (S.num(r.get("r")) or 0.0)
        nm = S.ex_name(e.get("id"), state, e)
        if vol > best_vol or not best_name:
            best_vol = vol
            best_name = nm
    return best_name or "—"


def _workout_muscles(w: dict[str, Any], state: dict[str, Any]) -> dict[str, float]:
    raw = S.load_of([w], state)
    return {slug: round(val, 2) for slug, val in raw.items() if slug in _MAIN_MUSCLES and val > 0}


def _nutrition_series(state: dict[str, Any]) -> list[dict[str, Any]]:
    by_day: dict[str, dict[str, Any]] = {}
    meals = state.get("meals")
    if isinstance(meals, dict):
        for key, m in meals.items():
            if not isinstance(m, dict) or m.get("deleted") is True:
                continue
            d = m.get("date")
            if not isinstance(d, str) or len(d) != 10:
                continue
            mid = (m.get("id") if isinstance(m.get("id"), str) else key).strip()
            if not mid:
                continue
            slot = by_day.setdefault(d, {"kcal": 0.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0, "meals": 0})
            slot["meals"] += 1
            for k in ("kcal", "protein", "carbs", "fat"):
                v = S.num(m.get(k))
                if v is not None and v > 0:
                    slot[k] += v
    out = []
    for d in sorted(by_day):
        row = by_day[d]
        out.append({
            "d": d,
            "totals": {
                "kcal": round(row["kcal"]),
                "protein": round(row["protein"], 1),
                "carbs": round(row["carbs"], 1),
                "fat": round(row["fat"], 1),
            },
            "meals": row["meals"],
        })
    return out


def _effective_goals(state: dict[str, Any], bw_kg: float | None) -> dict[str, Any]:
    raw = state.get("nutritionGoals") if isinstance(state.get("nutritionGoals"), dict) else {}

    def pos(k: str) -> float | None:
        v = S.num(raw.get(k))
        return v if v is not None and v > 0 else None

    per_kg = pos("proteinPerKg") or 2.0
    kcal = pos("kcal") or 2400.0
    protein = pos("protein")
    derived = False
    if protein is None:
        if bw_kg is not None and bw_kg > 0:
            protein = round(bw_kg * per_kg)
            derived = True
        else:
            protein = 150.0
    fat = pos("fat") or round((kcal * 0.27) / 9)
    carbs = pos("carbs") or max(50.0, round((kcal - protein * 4 - fat * 9) / 4))
    return {
        "kcal": round(kcal),
        "protein": round(protein),
        "carbs": round(carbs),
        "fat": round(fat),
        "proteinIsDerived": derived,
        "hasCustomGoals": bool(raw),
    }


def _load_ratio_series(ws: list[dict[str, Any]], today_iso: str, days: int = 182) -> list[dict[str, Any]]:
    today_d = dt.date.fromisoformat(today_iso)
    start_d = today_d - dt.timedelta(days=days + 27)
    sets_by_day: dict[str, int] = {}
    for w in ws:
        d = S.day(w)
        if d:
            sets_by_day[d] = sets_by_day.get(d, 0) + S.work_sets(w)
    span_days = (today_d - start_d).days + 1
    daily = [sets_by_day.get((start_d + dt.timedelta(days=i)).isoformat(), 0) for i in range(span_days)]
    out = []
    for i in range(28, span_days):
        acute = sum(daily[max(0, i - 6) : i + 1])
        chronic = sum(daily[max(0, i - 27) : i + 1]) / 4.0
        d = (start_d + dt.timedelta(days=i)).isoformat()
        ratio = round(acute / chronic, 2) if chronic >= 1.0 else (0.0 if acute == 0 else 1.0)
        out.append({"d": d, "ratio": ratio})
    return out


def _plan_payload(state: dict[str, Any], today_iso: str) -> dict[str, Any]:
    mode = P.schedule_mode(state)
    ws_start = S.week_start(state)
    week_monday = dt.date.fromisoformat(S.week_key(today_iso, ws_start))
    all_routines = S.routines(state, include_clones=True)
    by_id = {str(r["id"]): r for r in all_routines}
    week_days = []
    for offset in range(7):
        day_d = week_monday + dt.timedelta(days=offset)
        iso = day_d.isoformat()
        rids = P.routine_ids(state, iso, today_iso)
        names = [by_id[rid].get("name") or "Workout" for rid in rids if rid in by_id]
        is_clone = any((by_id.get(rid) or {}).get("aiClone") is True for rid in rids)
        week_days.append({
            "date": iso,
            "weekday": (day_d.weekday() + 1) % 7,
            "isToday": iso == today_iso,
            "routineIds": rids,
            "routineNames": names,
            "isRest": not names,
            "isAIClone": is_clone,
        })
    rot = state.get("rotation") if isinstance(state.get("rotation"), dict) else None
    q = P.queue(state)
    rotation_info = None
    if mode == "rotation" or rot or q:
        seq_ids = [i for i in (rot.get("sequence") if rot and isinstance(rot.get("sequence"), list) else []) if isinstance(i, str)]
        rotation_info = {
            "sequence": [
                {"id": rid, "name": "Rest" if rid == P.REST else (by_id.get(rid, {}).get("name") or rid), "isRest": rid == P.REST}
                for rid in seq_ids
            ],
            "queueIds": q["ids"] if q else [],
            "doneIds": P.queue_done(state),
            "remainingIds": P.queue_remaining(state),
        }
    user_routines = []
    for r in S.routines(state, include_clones=False):
        ex_list = []
        total_sets = 0
        for cfg in r.get("ex") or []:
            if not isinstance(cfg, dict):
                continue
            sets_n = int(S.num(cfg.get("sets")) or 0)
            total_sets += sets_n
            ex_list.append({
                "id": str(cfg.get("id") or ""),
                "name": S.ex_name(cfg.get("id"), state, cfg),
                "sets": sets_n,
                "reps": S.num(cfg.get("reps")),
                "repsMin": S.num(cfg.get("repsMin")),
                "repsMax": S.num(cfg.get("repsMax")),
                "weight": S.num(cfg.get("weight")),
                "sec": S.num(cfg.get("sec")),
                "min": S.num(cfg.get("min")),
                "restSec": S.num(cfg.get("restSec")),
                "mode": cfg.get("mode") if isinstance(cfg.get("mode"), str) else None,
                "note": cfg.get("note") if isinstance(cfg.get("note"), str) else None,
            })
        user_routines.append({
            "id": str(r.get("id")),
            "name": str(r.get("name") or "Routine"),
            "exerciseCount": len(ex_list),
            "totalSets": total_sets,
            "exercises": ex_list,
        })
    return {
        "mode": mode,
        "weekStart": ws_start,
        "weekTarget": S.num(state.get("weekTarget")),
        "weekDays": week_days,
        "rotation": rotation_info,
        "routines": user_routines,
    }


def _body_payload(state: dict[str, Any], today_iso: str) -> dict[str, Any]:
    bw = S.weigh_ins(state)
    today_d = dt.date.fromisoformat(today_iso)

    def change_since(days_back: int) -> float | None:
        if len(bw) < 2:
            return None
        cutoff = (today_d - dt.timedelta(days=days_back)).isoformat()
        older = [w for d, w in bw if d <= cutoff]
        base = older[-1] if older else bw[0][1]
        return round(bw[-1][1] - base, 2)

    goal = S.num(state.get("bwGoal"))
    meas_raw = S.measurements(state)
    by_metric: dict[str, list[dict[str, Any]]] = {}
    for d, vals in meas_raw:
        for name, (val, unit) in vals.items():
            by_metric.setdefault(name, []).append({"d": d, "value": val, "unit": unit})
    measurements = []
    for name, series in by_metric.items():
        first_v = series[0]["value"]
        last_v = series[-1]["value"]
        measurements.append({
            "key": name,
            "name": tm(name),
            "unit": series[-1]["unit"],
            "latest": last_v,
            "latestDate": series[-1]["d"],
            "first": first_v,
            "delta": round(last_v - first_v, 2) if len(series) > 1 else None,
            "count": len(series),
        })
    return {
        "unit": S.unit(state),
        "weighIns": [{"d": d, "w": w} for d, w in bw],
        "latest": {"d": bw[-1][0], "w": bw[-1][1]} if bw else None,
        "delta30": change_since(30),
        "delta90": change_since(90),
        "goal": goal,
        "measurements": measurements,
    }


def _stats_payload(state: dict[str, Any], ws: list[dict[str, Any]], today_iso: str) -> dict[str, Any]:
    today_d = dt.date.fromisoformat(today_iso)
    # 53-week consistency heatmap
    start_d = today_d - dt.timedelta(days=370)
    by_day: dict[str, dict[str, Any]] = {}
    for w in ws:
        d = S.day(w)
        if not d or d < start_d.isoformat():
            continue
        cur = by_day.setdefault(d, {"vol": 0.0, "count": 0})
        cur["vol"] += S.volume(w)
        cur["count"] += 1
    heatmap = []
    cur_d = start_d
    while cur_d <= today_d:
        iso = cur_d.isoformat()
        hit = by_day.get(iso)
        heatmap.append({"d": iso, "vol": round(hit["vol"], 1) if hit else 0.0, "count": hit["count"] if hit else 0})
        cur_d += dt.timedelta(days=1)

    # Top exercises by working sets
    ex_sets: dict[str, dict[str, Any]] = {}
    for w in ws:
        seen_in_w = set()
        for e in S.entries(w):
            n = sum(S.done_units(s) for s in S.sets(e) if not S.is_warmup(s))
            if not n:
                continue
            eid = str(e.get("id"))
            rec = ex_sets.setdefault(eid, {"id": eid, "name": S.ex_name(eid, state, e), "sets": 0, "sessions": 0})
            rec["sets"] += n
            if eid not in seen_in_w:
                rec["sessions"] += 1
                seen_in_w.add(eid)
    top_ex = sorted(ex_sets.values(), key=lambda x: (-x["sets"], -x["sessions"]))[:12]

    # Weekly volume last 16 weeks
    ws_start = S.week_start(state)
    this_wk = dt.date.fromisoformat(S.week_key(today_iso, ws_start))
    weekly_vol = []
    for k in range(15, -1, -1):
        wk_d = this_wk - dt.timedelta(weeks=k)
        wk_iso = wk_d.isoformat()
        in_wk = [w for w in ws if S.week_key(S.day(w), ws_start) == wk_iso]
        weekly_vol.append({
            "week": wk_iso,
            "vol": round(sum(S.volume(w) for w in in_wk), 1),
            "workouts": len(in_wk),
            "sets": sum(S.work_sets(w) for w in in_wk),
        })

    return {"heatmap": heatmap, "topExercises": top_ex, "weeklyVolume": weekly_vol}


def _reps_payload(store, state: dict[str, Any]) -> dict[str, Any]:
    files = [f for f in store.motion_meta() if isinstance(f.get("end"), (int, float))]

    def rated(f):
        return f.get("checked") is True and isinstance(f.get("auto"), int) and isinstance(f.get("reps"), int)

    checked = [f for f in files if rated(f)]
    exact = sum(f["auto"] == f["reps"] for f in checked)
    mae = round(sum(abs(f["auto"] - f["reps"]) for f in checked) / len(checked), 2) if checked else None
    per: dict[str, list[dict[str, Any]]] = {}
    for f in files:
        per.setdefault(str(f.get("exId")), []).append(f)
    by_ex = []
    for ex, fs in sorted(per.items(), key=lambda kv: -len(kv[1])):
        r = [f for f in fs if rated(f)]
        e = sum(f["auto"] == f["reps"] for f in r)
        m = round(sum(abs(f["auto"] - f["reps"]) for f in r) / len(r), 2) if r else None
        by_ex.append({
            "id": ex,
            "name": S.ex_name(ex, state),
            "sets": len(fs),
            "checked": len(r),
            "exact": e,
            "mae": m,
        })
    latest = []
    for f in files[:20]:
        off = f["auto"] - f["reps"] if rated(f) else None
        latest.append({
            "atMs": f["end"],
            "exId": str(f.get("exId")),
            "exercise": S.ex_name(str(f.get("exId")), state),
            "weight": f.get("w") if isinstance(f.get("w"), (int, float)) else None,
            "auto": f.get("auto") if isinstance(f.get("auto"), int) else None,
            "final": f.get("reps") if isinstance(f.get("reps"), int) else None,
            "off": off,
        })
    return {
        "setsRecorded": len(files),
        "exercisesCount": len(per),
        "confirmed": len(checked),
        "exact": exact,
        "exactPct": round(100 * exact / len(checked)) if checked else None,
        "mae": mae,
        "byExercise": by_ex,
        "latest": latest,
    }


def _motion_list_payload(store, state: dict[str, Any], ws: list[dict[str, Any]]) -> dict[str, Any]:
    metas = store.motion_meta()
    per = M.by_workout(metas, ws)
    matched = [w for w in ws if str(w.get("id")) in per]
    matched.sort(key=lambda w: S.num(w.get("start")) or 0, reverse=True)
    workouts_out = []
    for w in matched:
        wid = str(w.get("id"))
        ex_names = [S.ex_name(e.get("id"), state, e) for e in S.entries(w) if any(S.done_units(s) for s in S.sets(e))]
        workouts_out.append({
            "id": wid,
            "date": S.day(w),
            "name": str(w.get("name") or "Workout"),
            "exercisesSummary": ", ".join(ex_names[:4]) + (f" +{len(ex_names) - 4}" if len(ex_names) > 4 else ""),
            "fileCount": len(per[wid]),
        })
    unlinked = len(metas) - sum(len(v) for v in per.values())
    return {"workouts": workouts_out, "unlinkedCount": max(0, unlinked)}


def _mcp_payload(store) -> dict[str, Any]:
    here = Path(__file__).resolve().parents[1]
    snippet = {
        "mcpServers": {
            "hexplate": {
                "command": str(here / ".venv/bin/python"),
                "args": ["-m", "hexserver", "mcp"],
                "env": {"PYTHONPATH": str(here)},
            }
        }
    }
    db_path = (store.folder / "hexplate.sqlite3").resolve()
    return {
        "configJson": json.dumps(snippet, indent=2),
        "claudeDesktopPath": "~/Library/Application Support/Claude/claude_desktop_config.json",
        "claudeCodePath": ".mcp.json",
        "dbExists": db_path.is_file(),
        "tools": _MCP_TOOLS,
    }


def _downsample_trace(cols: dict[str, list[float]], mag: list[float], max_pts: int = 240) -> list[dict[str, float]]:
    t = cols["t"]
    n = len(t)
    if n == 0:
        return []
    t0 = t[0]
    step = max(1, math.ceil(n / max_pts))
    out = []
    for i in range(0, n, step):
        out.append({
            "t": round(t[i] - t0, 2),
            "ax": round(cols["ax"][i], 3),
            "ay": round(cols["ay"][i], 3),
            "az": round(cols["az"][i], 3),
            "mag": round(mag[i], 3),
        })
    if (n - 1) % step != 0:
        out.append({
            "t": round(t[-1] - t0, 2),
            "ax": round(cols["ax"][-1], 3),
            "ay": round(cols["ay"][-1], 3),
            "az": round(cols["az"][-1], 3),
            "mag": round(mag[-1], 3),
        })
    return out


def _ai_error_response(exc: AIError) -> JSONResponse:
    headers = dict(_NO_STORE)
    if exc.retry_after is not None:
        headers["Retry-After"] = str(exc.retry_after)
    return JSONResponse({"error": exc.message, "code": exc.code}, status_code=exc.status_code, headers=headers)


def install(app, store) -> None:
    """Installs `/analytics/api/*` endpoints onto `app` (must be called before `/analytics/{path:path}`)."""
    db = store.db
    backup = app.state.backup
    hooks = app.state.webhooks
    signing = app.state.signing
    ai_service = app.state.ai

    def doc() -> dict[str, Any]:
        return store.current()[1] or {}

    @app.get("/analytics/api/bootstrap")
    async def api_bootstrap(req: Request, today: str | None = None):
        today_iso = _safe_today(today)
        rev_row = db.execute("SELECT rev, received_at FROM documents ORDER BY rev DESC LIMIT 1").fetchone()
        rev, state = store.current()
        lang = LANG.get()
        payload = {
            "hasData": bool(state and S.workouts(state)),
            "hasDocument": state is not None,
            "rev": rev,
            "wid": state.get("_wid") if isinstance(state, dict) else None,
            "syncedAt": float(rev_row[1]) if rev_row else None,
            "lang": lang,
            "languages": LANG_OPTIONS,
            "strings": dashboard_zh_strings() if lang == "zh" else {},
            "unit": S.unit(state),
            "ai": ai_service.masked_config(),
            "aiUndo": coach_web.get_undo_status(store, store.folder, today=today_iso),
            "backup": backup.status(),
            "signing": signing.status(),
            "mcp": _mcp_payload(store),
            "pairedCount": len(store.tokens()),
            "webhookCount": len(hooks.all()),
            "serverAddresses": _server_addresses(req),
        }
        return JSONResponse(payload, headers=_NO_STORE)

    @app.get("/analytics/api/i18n/{lang_code}")
    async def api_i18n(lang_code: str):
        if lang_code not in ("en", "zh"):
            return JSONResponse({"error": "Unsupported language"}, status_code=400)
        return {"lang": lang_code, "strings": dashboard_zh_strings() if lang_code == "zh" else {}}

    @app.get("/analytics/api/dataset")
    async def api_dataset(today: str | None = None):
        today_iso = _safe_today(today)
        rev, state_opt = store.current()
        state = state_opt or {}
        ws = S.workouts(state)
        sessions = []
        for w in ws:
            ms = _workout_muscles(w, state)
            prs = _prs_of(w)
            w_sets = S.work_sets(w)
            status = "pr" if prs else "completed"
            sessions.append({
                "id": str(w.get("id")),
                "d": S.day(w),
                "routine": str(w.get("name") or "Workout"),
                "split": _infer_split(w, ms),
                "minutes": S.minutes(w) or 0,
                "vol": round(S.volume(w), 1),
                "workSets": w_sets,
                "prs": len(prs),
                "topExercise": _top_exercise(w, state),
                "muscleSets": ms,
                "status": status,
            })

        now_ms = coach_web.day_noon_ms(today_iso)
        raw_rec = coach_web.compute_recovery(state, now_ms)
        rec_muscles = {
            slug: {
                "fatigue": round(raw_rec["muscles"].get(slug, {}).get("fatigue", 0.0), 3),
                "lastSessionSets": round(raw_rec["muscles"].get(slug, {}).get("lastSessionSets", 0.0), 1),
                "hoursToRecovered": round(raw_rec["muscles"].get(slug, {}).get("hoursToRecovered", 0.0), 1),
            }
            for slug in _MAIN_MUSCLES
        }
        g_rec = raw_rec["global"]
        recovery = {
            "muscles": rec_muscles,
            "global": {
                "acute": round(g_rec["acute"], 1),
                "chronic": round(g_rec["chronic"], 1),
                "ratio": round(g_rec["ratio"], 2) if g_rec["ratio"] is not None else None,
            },
        }

        bw_kg = coach_web.latest_bodyweight_kg(state)
        goals = _effective_goals(state, bw_kg)
        nutrition = _nutrition_series(state)
        trained_list = []
        for ex_id, count, last_day in S.trained_exercises(state):
            ex_sess = S.exercise_sessions(state, ex_id)
            best = max((x for x in ex_sess if x["est"] is not None), key=lambda x: x["est"], default=None)
            trained_list.append({
                "id": ex_id,
                "name": S.ex_name(ex_id, state),
                "sessions": count,
                "lastDate": last_day,
                "bestE1rm": round(best["est"], 1) if best else None,
                "bestWeight": best["w"] if best else None,
                "bestReps": best["r"] if best else None,
            })

        return {
            "source": "local",
            "hasData": bool(ws),
            "rev": rev,
            "today": today_iso,
            "unit": S.unit(state),
            "sessions": sessions,
            "readiness": [],
            "nutrition": nutrition,
            "goals": goals,
            "bodyweightKg": round(bw_kg, 1) if bw_kg is not None else 75.0,
            "hasBodyweight": bw_kg is not None,
            "loadRatio": _load_ratio_series(ws, today_iso),
            "recovery": recovery,
            "weeklyProgress": {
                "workoutsLeft": P.workouts_left(state, today_iso),
                "streak": P.streak(state, today_iso),
                "muscleSets": S.weekly_muscle_sets(state, today_iso),
            },
            "plan": _plan_payload(state, today_iso),
            "exercises": trained_list,
            "body": _body_payload(state, today_iso),
            "stats": _stats_payload(state, ws, today_iso),
            "reps": _reps_payload(store, state),
            "motion": _motion_list_payload(store, state, ws),
        }

    @app.get("/analytics/api/workouts/{wid}")
    async def api_workout_detail(wid: str):
        state = doc()
        w = next((x for x in S.workouts(state) if str(x.get("id")) == wid), None)
        if not w:
            return JSONResponse({"error": "Workout not found."}, status_code=404)
        prs = set(_prs_of(w))
        has_motion = wid in M.by_workout(store.motion_meta(), [w])
        entries_out = []
        for e in S.entries(w):
            eid = str(e.get("id"))
            best = S.best_set(e)
            set_rows = []
            work_idx = 0
            for s in S.sets(e):
                warmup = S.is_warmup(s)
                if not warmup:
                    work_idx += 1
                set_index = None if warmup else work_idx
                if S.is_side(s):
                    for side_key in ("L", "R"):
                        part = s["sides"][side_key]
                        hr = part.get("hr") if isinstance(part.get("hr"), dict) else {}
                        set_rows.append({
                            "index": set_index,
                            "side": side_key,
                            "warmup": warmup,
                            "done": part.get("done") is True,
                            "weight": S.num(part.get("w")),
                            "reps": S.num(part.get("r")),
                            "sec": S.num(part.get("sec")),
                            "min": S.num(part.get("min")),
                            "rir": S.num(part.get("rir")),
                            "hrAvg": S.num(hr.get("avg")),
                        })
                else:
                    hr = s.get("hr") if isinstance(s.get("hr"), dict) else {}
                    set_rows.append({
                        "index": set_index,
                        "side": None,
                        "warmup": warmup,
                        "done": s.get("done") is True,
                        "weight": S.num(s.get("w")),
                        "reps": S.num(s.get("r")),
                        "sec": S.num(s.get("sec")),
                        "min": S.num(s.get("min")),
                        "rir": S.num(s.get("rir")),
                        "hrAvg": S.num(hr.get("avg")),
                    })
            entries_out.append({
                "id": eid,
                "name": S.ex_name(eid, state, e),
                "isPr": eid in prs,
                "best": {"e1rm": round(best[0], 1), "weight": best[1], "reps": best[2]} if best else None,
                "sets": set_rows,
            })
        return {
            "id": wid,
            "date": S.day(w),
            "name": str(w.get("name") or "Workout"),
            "minutes": S.minutes(w),
            "volume": round(S.volume(w), 1),
            "workSets": S.work_sets(w),
            "bodyweight": S.num(w.get("bw")),
            "note": w.get("note") if isinstance(w.get("note"), str) else None,
            "unit": S.unit(state),
            "prsCount": len(prs),
            "hasMotion": has_motion,
            "entries": entries_out,
        }

    @app.get("/analytics/api/exercises/{ex_id}")
    async def api_exercise_detail(ex_id: str):
        state = doc()
        rows = S.exercise_sessions(state, ex_id)
        if not rows:
            return JSONResponse({"error": "No logged sets for this exercise."}, status_code=404)
        best = max((r for r in rows if r["est"] is not None), key=lambda r: r["est"], default=None)
        heaviest = max((r for r in rows if r["w"] is not None), key=lambda r: (r["w"], r["r"] or 0), default=None)
        return {
            "id": ex_id,
            "name": S.ex_name(ex_id, state),
            "unit": S.unit(state),
            "sessionsCount": len(rows),
            "firstDate": rows[0]["d"],
            "lastDate": rows[-1]["d"],
            "bestE1rm": {"est": round(best["est"], 1), "w": best["w"], "r": best["r"], "d": best["d"]} if best else None,
            "heaviest": {"w": heaviest["w"], "r": heaviest["r"], "d": heaviest["d"]} if heaviest else None,
            "sessions": [
                {
                    "d": r["d"],
                    "workoutId": str(r["id"]),
                    "e1rm": round(r["est"], 1) if r["est"] is not None else None,
                    "weight": r["w"],
                    "reps": r["r"],
                    "sets": r["sets"],
                    "volume": round(r["volume"], 1),
                    "pr": bool(r["pr"]),
                }
                for r in rows
            ],
        }

    @app.get("/analytics/api/report")
    async def api_report(range: str = "4w", today: str | None = None):
        import calendar

        today_iso = _safe_today(today)
        today_d = dt.date.fromisoformat(today_iso)
        kind = range if range in ("7d", "4w", "3m") else "4w"
        if kind == "7d":
            a, b = today_d - dt.timedelta(days=6), today_d
        elif kind == "3m":
            y, m = divmod(today_d.month - 1 - 3, 12)
            y, m = today_d.year + y, m + 1
            a, b = dt.date(y, m, min(today_d.day, calendar.monthrange(y, m)[1])) + dt.timedelta(days=1), today_d
        else:
            a, b = today_d - dt.timedelta(days=27), today_d
        span = (b - a).days + 1
        prev_a, prev_b = a - dt.timedelta(days=span), a - dt.timedelta(days=1)

        state = doc()
        ws = S.workouts(state)
        cur = [w for w in ws if a.isoformat() <= S.day(w) <= b.isoformat()]
        prev = [w for w in ws if prev_a.isoformat() <= S.day(w) <= prev_b.isoformat()]

        def agg(items):
            return {
                "workouts": len(items),
                "volume": round(sum(S.volume(w) for w in items), 1),
                "sets": sum(S.work_sets(w) for w in items),
                "minutes": sum(S.minutes(w) or 0 for w in items),
            }

        recs = []
        for w in cur:
            for eid in _prs_of(w):
                es = [e for e in S.entries(w) if str(e.get("id")) == eid]
                best = max((x for x in (S.best_set(e) for e in es) if x), default=None)
                recs.append({
                    "exerciseId": eid,
                    "exercise": S.ex_name(eid, state),
                    "weight": best[1] if best else None,
                    "reps": best[2] if best else None,
                    "e1rm": round(best[0], 1) if best else None,
                    "date": S.day(w),
                    "workoutId": str(w.get("id")),
                })
        load = S.load_of(cur, state)
        muscles = [
            {"slug": slug, "name": S.muscle_name(slug), "sets": S.js_round1(val)}
            for slug, val in sorted(load.items(), key=lambda kv: -kv[1])
            if val > 0
        ]
        bw = [{"d": d, "w": v} for d, v in S.weigh_ins(state) if a.isoformat() <= d <= b.isoformat()]
        workouts_out = [
            {
                "id": str(w.get("id")),
                "date": S.day(w),
                "name": str(w.get("name") or "Workout"),
                "minutes": S.minutes(w),
                "sets": S.work_sets(w),
                "volume": round(S.volume(w), 1),
                "exercises": [S.ex_name(e.get("id"), state, e) for e in S.entries(w) if any(S.done_units(s) for s in S.sets(e))][:6],
            }
            for w in reversed(cur)
        ]
        return {
            "range": kind,
            "from": a.isoformat(),
            "to": b.isoformat(),
            "days": span,
            "unit": S.unit(state),
            "current": agg(cur),
            "previous": agg(prev),
            "records": recs,
            "muscles": muscles,
            "bodyweight": bw,
            "workouts": workouts_out,
        }

    @app.get("/analytics/api/motion/{wid}")
    async def api_motion_detail(wid: str):
        state = doc()
        ws = S.workouts(state)
        w = next((x for x in ws if str(x.get("id")) == wid), None)
        metas = M.by_workout(store.motion_meta(), ws).get(wid, []) if w else []
        if not w or not metas:
            return JSONResponse({"error": "No motion files for this workout."}, status_code=404)
        rows = M.sets(store.motion_dir, metas, w)
        per_ex: dict[str, list[dict[str, Any]]] = {}
        seq_n: dict[str, int] = {}
        for r in rows:
            ex = str(r["meta"].get("exId"))
            per_ex.setdefault(ex, []).append(r)
            seq_n[ex] = seq_n.get(ex, 0) + 1
            r["label"] = f"{list(per_ex).index(ex) + 1}.{seq_n[ex]}"
            r["exName"] = S.ex_name(ex, state)
        clean = [r for r in rows if not r["flags"]]
        flag_counts: dict[str, int] = {}
        for r in rows:
            for f in r["flags"]:
                k = re.sub(r"\d+(\.\d+)?", "#", f)
                flag_counts[k] = flag_counts.get(k, 0) + 1
        secs = sum(r["q"].get("dur_s", 0) for r in rows)
        exercises_table = [
            {
                "index": idx,
                "exId": ex,
                "name": rs[0]["exName"],
                "sets": len(rs),
                "clean": sum(not r["flags"] for r in rs),
                "flags": sorted({f for r in rs for f in r["flags"]}),
            }
            for idx, (ex, rs) in enumerate(per_ex.items(), 1)
        ]

        def pts(key: str, flag_prefix: str):
            return [
                {
                    "label": r["label"],
                    "exercise": r["exName"],
                    "value": r["q"][key],
                    "flagged": any(f.startswith(flag_prefix) for f in r["flags"]),
                }
                for r in rows
                if r["q"].get(key) is not None
            ]

        traces_out = []
        for ex, rs in per_ex.items():
            picked = ([x for x in rs if not x["flags"]] or rs)[-1]
            c = picked["cols"]
            mag = M.smooth([math.sqrt(x * x + y * y + z * z) for x, y, z in zip(c["ax"], c["ay"], c["az"])])
            t0 = c["t"][0] if c["t"] else 0.0
            ticks = [
                round(e[0] - t0, 2) if e[0] > 1e6 else round(e[0], 2)
                for e in picked["meta"].get("helpers", {}).get("log", [])
                if isinstance(e, list) and len(e) > 1 and isinstance(e[1], str) and e[1].startswith("rep ")
            ]
            traces_out.append({
                "exId": ex,
                "name": picked["exName"],
                "label": picked["label"],
                "reps": picked["reps"],
                "auto": picked["auto"],
                "points": _downsample_trace(c, mag),
                "ticks": ticks,
            })

        live = M.live_rows(rows)
        live_table = [
            {
                "exId": ex,
                "name": S.ex_name(ex, state),
                "sets": k,
                "meanReps": round(m, 1),
                "mae": round(e, 2),
                "exactPct": round(100 * x),
                "bias": round(b, 2),
            }
            for ex, k, m, e, x, b in live
        ]
        scatter_pts = [
            {"label": r["label"], "exercise": r["exName"], "logged": r["reps"], "live": r["auto"]}
            for r in clean
            if r["auto"] is not None and isinstance(r["reps"], (int, float))
        ]
        findings = [f"{len(clean)} of {len(rows)} sets are clean."]
        if flag_counts:
            top_k, top_n = max(flag_counts.items(), key=lambda kv: kv[1])
            findings.append(f"Most common flag: {top_k} ({top_n} sets).")
        if scatter_pts:
            errs = [p["live"] - p["logged"] for p in scatter_pts]
            exact_n = sum(e == 0 for e in errs)
            findings.append(
                f"Live count: exact on {exact_n} of {len(errs)} clean sets, mean error {sum(map(abs, errs)) / len(errs):.2f} reps, bias {sum(errs) / len(errs):+.2f}."
            )
            worst = max(live, key=lambda r: r[3])
            if worst[3] > 0:
                findings.append(f"Hardest to count: {S.ex_name(worst[0], state)} (mean error {worst[3]:.2f}).")

        return {
            "id": wid,
            "date": S.day(w),
            "name": str(w.get("name") or "Workout"),
            "summary": {
                "setsRecorded": len(rows),
                "exercisesCount": len(per_ex),
                "cleanSets": len(clean),
                "durationSec": round(secs, 1),
                "totalRows": sum(r["q"].get("rows", 0) for r in rows),
            },
            "exercises": exercises_table,
            "flags": [{"flag": k, "count": v} for k, v in sorted(flag_counts.items(), key=lambda kv: -kv[1])],
            "hzPoints": pts("hz", "rate"),
            "gapPoints": pts("max_gap_s", "gap"),
            "headPoints": pts("head", "clipped start"),
            "tailPoints": pts("tail", "clipped end"),
            "traces": traces_out,
            "liveAccuracy": live_table,
            "scatter": scatter_pts,
            "findings": findings,
        }

    # MARK: Sync & Data

    @app.get("/analytics/api/data")
    async def api_data(req: Request):
        tokens = [{"hash": h, "index": i + 1, "createdAt": at} for i, (h, at) in enumerate(store.tokens())]
        versions = [
            {"rev": rev, "receivedAt": at, "workouts": n or 0, "bytes": size}
            for rev, at, n, size in store.versions()
        ]
        return {"tokens": tokens, "versions": versions, "serverAddresses": _server_addresses(req)}

    @app.post("/analytics/api/data/pair")
    async def api_data_pair(req: Request):
        code = store.new_pair_code()
        return JSONResponse({"code": code, "expiresInSeconds": 300, "serverAddresses": _server_addresses(req)}, headers=_NO_STORE)

    @app.post("/analytics/api/data/revoke")
    async def api_data_revoke(req: Request):
        try:
            body = await read_limited_json(req)
        except AIError as e:
            return _ai_error_response(e)
        h = body.get("hash")
        if not isinstance(h, str) or not h.strip():
            return JSONResponse({"error": "hash is required."}, status_code=400)
        store.revoke(h.strip())
        return {"ok": True}

    @app.post("/analytics/api/data/restore")
    async def api_data_restore(req: Request):
        try:
            body = await read_limited_json(req)
        except AIError as e:
            return _ai_error_response(e)
        rev = body.get("rev")
        if isinstance(rev, bool) or not isinstance(rev, int) or rev < 1:
            return JSONResponse({"error": "rev must be a positive integer."}, status_code=400)
        if not store.restore(rev):
            return JSONResponse({"error": "No such version."}, status_code=404)
        backup.soon()
        return {"ok": True, "rev": store.current()[0]}

    # MARK: Connect (Webhooks & MCP Server)

    @app.get("/analytics/api/connect")
    async def api_connect():
        items = [
            {**h, "maskedUrl": _mask_url(h["url"]), "url": _mask_url(h["url"])}
            for h in hooks.all()
        ]
        events = [{"key": e, "label": EVENT_LABELS[e]} for e in EVENTS]
        return {"webhooks": items, "events": events, "mcp": _mcp_payload(store)}

    @app.post("/analytics/api/connect/webhooks")
    async def api_webhook_add(req: Request):
        try:
            body = await read_limited_json(req)
        except AIError as e:
            return _ai_error_response(e)
        url = body.get("url")
        label = body.get("label") or ""
        events = body.get("events")
        if not isinstance(url, str) or not isinstance(label, str) or not isinstance(events, list):
            return JSONResponse({"error": "url, label, and events are required."}, status_code=400)
        try:
            wid, secret = hooks.add(url, label, [e for e in events if isinstance(e, str)])
        except ValueError as e:
            return JSONResponse({"error": str(e)}, status_code=400)
        return JSONResponse({"ok": True, "id": wid, "secret": secret}, headers=_NO_STORE)

    @app.post("/analytics/api/connect/webhooks/{wid}/test")
    async def api_webhook_test(wid: str):
        ok, msg = hooks.send_test(wid)
        return {"ok": ok, "message": msg}

    @app.post("/analytics/api/connect/webhooks/{wid}/pause")
    async def api_webhook_pause(wid: str, req: Request):
        try:
            body = await read_limited_json(req)
        except AIError as e:
            return _ai_error_response(e)
        paused = body.get("paused")
        if not isinstance(paused, bool):
            return JSONResponse({"error": "paused must be a boolean."}, status_code=400)
        hooks.pause(wid, paused)
        return {"ok": True, "paused": paused}

    @app.delete("/analytics/api/connect/webhooks/{wid}")
    async def api_webhook_delete(wid: str):
        hooks.remove(wid)
        return {"ok": True}

    # MARK: Settings (Language, Backup, Signing, AI)

    @app.post("/analytics/api/settings/lang")
    async def api_settings_lang(req: Request):
        try:
            body = await read_limited_json(req)
        except AIError as e:
            return _ai_error_response(e)
        lang = body.get("lang")
        if lang not in ("en", "zh"):
            return JSONResponse({"error": "lang must be 'en' or 'zh'."}, status_code=400)
        store.set_setting("lang", lang)
        LANG.set(lang)
        return {"ok": True, "lang": lang, "strings": dashboard_zh_strings() if lang == "zh" else {}}

    @app.post("/analytics/api/settings/backup")
    async def api_settings_backup(req: Request):
        try:
            body = await read_limited_json(req)
        except AIError as e:
            return _ai_error_response(e)
        on = body.get("on")
        if not isinstance(on, bool):
            return JSONResponse({"error": "on must be a boolean."}, status_code=400)
        store.set_setting("backup", "on" if on else "off")
        return {"ok": True, "backup": backup.status()}

    @app.post("/analytics/api/settings/backup/run")
    async def api_settings_backup_run():
        copied, ok = backup.everything()
        return {"ok": ok, "copied": copied, "backup": backup.status()}

    @app.post("/analytics/api/settings/signing/run")
    async def api_settings_signing_run():
        started = signing.start()
        return {"ok": True, "started": started, "signing": signing.status()}

    @app.get("/analytics/api/settings/ai")
    async def api_settings_ai_get():
        return JSONResponse(ai_service.masked_config(), headers=_NO_STORE)

    @app.post("/analytics/api/settings/ai")
    async def api_settings_ai_save(req: Request):
        try:
            body = await read_limited_json(req)
            out = ai_service.save_config(
                base_url=body.get("baseUrl") if "baseUrl" in body else None,
                model=body.get("model") if "model" in body else None,
                api_key=body.get("apiKey") if "apiKey" in body else None,
                clear_api_key=bool(body.get("clearApiKey", False)),
                daily_token_cap=body.get("dailyTokenCap") if "dailyTokenCap" in body else None,
                rate_limit_per_min=body.get("rateLimitPerMin") if "rateLimitPerMin" in body else None,
                reset_to_env=bool(body.get("resetToEnv", False)),
            )
            return JSONResponse(out, headers=_NO_STORE)
        except AIError as e:
            return _ai_error_response(e)

    @app.post("/analytics/api/settings/ai/test")
    async def api_settings_ai_test(req: Request):
        try:
            body = await read_limited_json(req)
            out = await ai_service.test_connection(
                base_url=body.get("baseUrl") if isinstance(body.get("baseUrl"), str) else None,
                model=body.get("model") if isinstance(body.get("model"), str) else None,
                api_key=body.get("apiKey") if isinstance(body.get("apiKey"), str) else None,
            )
            return JSONResponse(out, headers=_NO_STORE)
        except AIError as e:
            return _ai_error_response(e)

    # MARK: Web AI Coach (thin routes over coach_web.py)

    @app.get("/analytics/api/ai/coach/context")
    async def api_coach_context(today: str | None = None, timezone: str = "UTC"):
        today_iso = _safe_today(today)
        lang = LANG.get()
        try:
            rev, state = store.current()
            built = coach_web.build_web_coach_context(state, today=today_iso, timezone=timezone, lang=lang)
            return JSONResponse(
                {
                    "rev": rev,
                    "wid": state.get("_wid") if isinstance(state, dict) else None,
                    "summary": built["summary"],
                    "ai": ai_service.masked_config(),
                    "undo": coach_web.get_undo_status(store, store.folder, today=today_iso),
                },
                headers=_NO_STORE,
            )
        except AIError as e:
            return _ai_error_response(e)

    @app.post("/analytics/api/ai/coach")
    async def api_coach_propose(req: Request):
        try:
            body = await read_limited_json(req)
            message = body.get("message")
            today_iso = body.get("today")
            timezone = body.get("timezone") if isinstance(body.get("timezone"), str) else "UTC"
            lang = body.get("lang") if isinstance(body.get("lang"), str) and body.get("lang") in ("en", "zh") else LANG.get()
            if not isinstance(message, str) or not message.strip():
                return JSONResponse({"error": "message is required.", "code": "bad-request"}, status_code=400, headers=_NO_STORE)
            out = await coach_web.propose_coach_change(
                ai_service,
                store,
                message=message,
                today=today_iso,
                timezone=timezone,
                lang=lang,
            )
            return JSONResponse(out, headers=_NO_STORE)
        except AIError as e:
            return _ai_error_response(e)

    @app.post("/analytics/api/ai/coach/apply")
    async def api_coach_apply(req: Request):
        try:
            body = await read_limited_json(req)
            ops = body.get("ops")
            base_rev = body.get("baseRev")
            base_wid = body.get("baseWid")
            expected_digests = body.get("expectedDigests")
            today_iso = body.get("today")
            timezone = body.get("timezone") if isinstance(body.get("timezone"), str) else "UTC"
            lang = body.get("lang") if isinstance(body.get("lang"), str) and body.get("lang") in ("en", "zh") else LANG.get()
            if isinstance(base_rev, bool) or not isinstance(base_rev, int):
                return JSONResponse({"error": "baseRev must be an integer.", "code": "bad-request"}, status_code=400, headers=_NO_STORE)
            if base_wid is not None and not isinstance(base_wid, str):
                return JSONResponse({"error": "baseWid must be a string or null.", "code": "bad-request"}, status_code=400, headers=_NO_STORE)
            out = coach_web.apply_coach_preview(
                store,
                backup,
                store.folder,
                ops=ops,
                base_rev=base_rev,
                base_wid=base_wid,
                expected_digests=expected_digests,
                today=today_iso,
                timezone=timezone,
                lang=lang,
            )
            return JSONResponse(out, headers=_NO_STORE)
        except AIError as e:
            return _ai_error_response(e)

    @app.post("/analytics/api/ai/coach/undo")
    async def api_coach_undo(req: Request):
        try:
            body = await read_limited_json(req)
            token_id = body.get("tokenId")
            today_iso = body.get("today")
            timezone = body.get("timezone") if isinstance(body.get("timezone"), str) else "UTC"
            if not isinstance(token_id, str) or not token_id.strip():
                return JSONResponse({"error": "tokenId is required.", "code": "bad-request"}, status_code=400, headers=_NO_STORE)
            out = coach_web.undo_coach_batch(
                store,
                backup,
                store.folder,
                token_id=token_id.strip(),
                today=today_iso,
                timezone=timezone,
            )
            return JSONResponse(out, headers=_NO_STORE)
        except AIError as e:
            return _ai_error_response(e)
