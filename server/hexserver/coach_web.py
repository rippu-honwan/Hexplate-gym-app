"""Server-side AI Coach for the web dashboard.

Python ports of the HexplateCore pieces the web Coach needs, so a plan change made in the browser
merges on the phone exactly like one made on the phone:

- `stamp_change` / `highest_stamp`: SyncStamps.stampChange (golden-tested against
  `stamp-cases.json` -> `stamp-golden.json`).
- `compute_recovery` / `fatigue_map`: Recovery.loadSummary / Recovery.fatigue (golden-tested
  against the `fatigue` cases of `recovery-cases.json`).
- `build_web_coach_context`: CoachContext.build, with today always locked as `active` (R3): the
  server never sees a live iPhone session because `Store.put` strips `active`.
- `preview_coach_ops` / `apply_coach_preview` / `undo_coach_batch`: CoachOps.preview / apply and
  AIUndo.apply, server-authoritative and optimistic-locked through `Store.put` (R5, R6).

Unlike `ai.py`, this module may read the server clock (`datetime` / `zoneinfo`): it only uses it
to reject a client `today` more than one day away from the server's date (C6).
"""
from __future__ import annotations

import copy
import datetime as dt
from functools import cache
import hashlib
import json
import math
import re
import secrets
import time
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from . import ai, queries, schedule
from .ai import AIBadRequestError, AIError, atomic_write_secret_json, read_capped_json
from .store import Conflict

Object = dict[str, Any]

WINDOW_DAYS = ai.COACH_WINDOW_DAYS  # today + 14 days, as CoachContext.planWindowDays
RECENT_WORKOUT_DAYS = 14
MAX_CANDIDATE_EXERCISES = 30
UNDO_FILE = "ai-undo.json"
MAX_TODAY_SKEW_DAYS = 1
_SYNC_META = ("_ts", "_f", "_u")
_WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
_ROTATION_NOTE = (
    "Rotation mode v1: move_day is unavailable, and queue-session edits apply only to the current "
    "next session date (future queue sessions cannot be re-dated)."
)


class CoachConflictError(AIError):
    """The live document moved since the preview (`stale-preview`) or during the write (`conflict`)."""

    def __init__(self, message: str, *, code: str = "conflict"):
        super().__init__(message, code, 409)


# MARK: - JSON values the way HexplateCore's JSONValue compares and reads them

_MISSING = object()  # an absent key, which JSONValue tells apart from an explicit null


def _g(d: Any, k: str) -> Any:
    return d.get(k, _MISSING) if isinstance(d, dict) else _MISSING


def _eq(a: Any, b: Any) -> bool:
    """JSONValue equality: a bool is never a number, 1 == 1.0, absent != null."""
    if a is _MISSING or b is _MISSING:
        return a is b
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_eq(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_eq(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def _is_num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _num(v: Any) -> float:
    """JavaScript's `Number(v) || 0` (JSONValue.num)."""
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if _is_num(v):
        return 0.0 if v != v else float(v)
    if isinstance(v, str) and "_" not in v:
        try:
            return float(v.strip(" "))
        except ValueError:
            return 0.0
    return 0.0


def _out(x: float) -> int | float:
    """Integral stamps are written as JSON integers, like JavaScript prints them."""
    return int(x) if isinstance(x, float) and x.is_integer() and abs(x) < 2**53 else x


def _key(v: Any) -> str:
    """An id as JavaScript's `String(x)` prints it (SyncStamps.key)."""
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return str(int(v)) if v.is_integer() and abs(v) < 1e15 else repr(v)
    if v is None:
        return "null"
    return "[object Object]"


def _obj(v: Any) -> Object | None:
    return v if isinstance(v, dict) else None


def _arr(v: Any) -> list | None:
    return v if isinstance(v, list) else None


def _strings(v: Any) -> list[str]:
    return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []


def _strip_meta(o: Object) -> Object:
    return {k: v for k, v in o.items() if k not in _SYNC_META}


def _round(x: float, digits: int = 0) -> float:
    """Swift `.rounded()` (half away from zero) at `digits` decimals."""
    scale = 10**digits
    return math.copysign(math.floor(abs(x) * scale + 0.5), x) / scale


def _canonical_json(v: Any) -> str:
    def norm(x: Any) -> Any:
        if isinstance(x, dict):
            return {k: norm(y) for k, y in x.items()}
        if isinstance(x, list):
            return [norm(y) for y in x]
        return _out(x) if isinstance(x, float) else x

    return json.dumps(norm(v), sort_keys=True, separators=(",", ":"), ensure_ascii=False)


# MARK: - SyncStamps (exact port of SyncStamps.swift / sync-merge.js stampChange)

STAMPED_MAPS = ["balanceOverrides", "loadKind", "plates", "dbLoad", "dumbbells", "stackWeights", "exUnit", "dayNotes", "dayPhotos", "exMerged"]
_ENTRY_META = frozenset({"id", "_ts", "_f", "_u"})
_DELETION_LISTS = ["workouts", "routines", "customEx", "bodyweight", "measurements", "gymCards", "equipProfiles", "favEx"]
DELETED_MAX = 5000
_OWN_MERGE = frozenset({
    "_ts", "_rev", "_wid", "_wids", "_unstamped", "_prior", "active", "unit", "unitSet", "resetAt", "resetIds", "deleted",
    "edited", "undone", "routineOrder", "workouts", "routines", "customEx", "equipProfiles", "gymCards", "bodyweight",
    "measurements", "favEx", "exWeights", *STAMPED_MAPS, "meals",
})
_PER_KEY = frozenset({"week", "dayPlan", "exNotes", "barWeights", "exAliases", "programmes", "modules"})
_EDIT_KEEP_MS = 180.0 * 86_400_000


def highest_stamp(state: Object) -> float:
    """The latest stamp a copy carries (SyncStamps.highestStamp). Meals are never counted."""
    m = 0.0

    def see(v: Any) -> None:
        nonlocal m
        m = max(m, abs(_num(v)))

    see(state.get("_ts"))
    see((_obj(state.get("unitSet")) or {}).get("at"))
    see(state.get("resetAt"))
    for v in (_obj(state.get("edited")) or {}).values():
        see(v)
    for v in (_obj(state.get("deleted")) or {}).values():
        for w in (_obj(v) or {}).values():
            see(w)
    for f in ("workouts", "routines", "customEx", "equipProfiles", "gymCards"):
        for x in _arr(state.get(f)) or []:
            if isinstance(x, dict):
                see(x.get("_ts"))
                for v in (_obj(x.get("_f")) or {}).values():
                    see(v)
    for f in STAMPED_MAPS:
        for v in (_obj(state.get(f)) or {}).values():
            see(v.get("_ts") if isinstance(v, dict) else None)
    for f in ("bodyweight", "measurements"):
        for x in _arr(state.get(f)) or []:
            see(x.get("t") if isinstance(x, dict) else None)
    return m


def _same_entry(a: Object, b: Object) -> bool:
    return _eq(_strip_meta(a), _strip_meta(b))


def _by_id(lst: Any) -> dict[str, Object]:
    out: dict[str, Object] = {}
    for x in _arr(lst) or []:
        if isinstance(x, dict) and x.get("id") is not None:
            out[_key(x["id"])] = x
    return out


def _settle_marks(marks: Any, stamps: Object, now: float) -> Object | None:
    if not isinstance(marks, dict):
        return None
    out: Object = {}
    for k, m in marks.items():
        if not isinstance(m, list):
            continue
        at = _num(stamps[k]) if k in stamps else 0.0
        if len(m) == 2 and at == now:
            out[k] = [_out(_num(m[0])), _out(_num(m[1])), _out(now)]
        elif len(m) == 3 and at > 0 and _num(m[2]) == at:
            out[k] = m
    return out or None


def _stamp_entry(old: Object | None, x: Object, now: float) -> None:
    x["_ts"] = _out(now)
    if old is None:
        return
    f = dict(old["_f"]) if isinstance(old.get("_f"), dict) else {}
    for k in set(old) | set(x):
        if k not in _ENTRY_META and not _eq(_g(old, k), _g(x, k)):
            f[k] = _out(now)
    if f:
        x["_f"] = f
    else:
        x.pop("_f", None)
    marks = _settle_marks(x.get("_u"), f, now)
    if marks is None:
        x.pop("_u", None)
    else:
        x["_u"] = marks


def _stamp_entries(field: str, prev: Object, nxt: Object, now: float, skip=None) -> None:
    entries = _arr(nxt.get(field))
    if entries is None:
        return
    before = _by_id(prev.get(field))
    for i, x in enumerate(entries):
        if not isinstance(x, dict) or x.get("id") is None:
            continue
        old = before.get(_key(x["id"]))
        if old is None and skip is not None and skip(x):
            continue
        if old is not None and _same_entry(old, x):
            continue
        x = dict(x)
        _stamp_entry(old, x, now)
        entries[i] = x


def _deletion_key(field: str, x: Any) -> str:
    if field == "favEx":
        return _key(x)
    o = _obj(x)
    if field in ("bodyweight", "measurements"):
        return _key(o["d"]) if o is not None and "d" in o else "undefined"
    if field == "workouts":
        if o is not None and o.get("id") is not None:
            return _key(o["id"])

        def part(k: str) -> str:
            return _key(o[k]) if o is not None and k in o else "undefined"

        return f"{part('d')}|{part('start')}"
    return _key(o["id"]) if o is not None and "id" in o else "undefined"


def _deletion_time(field: str, x: Any) -> float:
    o = _obj(x) or {}

    def n(k: str) -> float:
        return _num(o[k]) if k in o else 0.0

    if field == "workouts":
        return next((v for v in (n("_ts"), n("end"), n("start")) if v != 0), 0.0)
    if field in ("bodyweight", "measurements"):
        return n("t")
    if field == "favEx":
        return 0.0
    return n("_ts")


def _stamp_deletions(prev: Object, nxt: Object, now: float) -> None:
    deleted = dict(_obj(nxt.get("deleted")) or {})
    touched = False
    for f in _DELETION_LISTS:
        before = [x for x in _arr(prev.get(f)) or [] if x is not None]
        after = [x for x in _arr(nxt.get(f)) or [] if x is not None]
        have = {_deletion_key(f, x) for x in after}
        had = {_deletion_key(f, x) for x in before}
        m = dict(_obj(deleted.get(f)) or {})
        changed = False
        for x in before:
            k = _deletion_key(f, x)
            if k not in have:
                m[k] = _out(max(now, _deletion_time(f, x) + 1))
                changed = True
        for k in have - had:
            if k in m:
                if _num(m[k]) > 0:
                    m[k] = _out(-now)
                    changed = True
            elif f == "favEx":
                m[k] = _out(-now)
                changed = True
        if changed:
            if len(m) > DELETED_MAX:
                for k in sorted(m, key=lambda k: abs(_num(m[k])))[: len(m) - DELETED_MAX]:
                    del m[k]
            deleted[f] = m
            touched = True
    if touched:
        nxt["deleted"] = deleted


def _order_moved(a: Any, b: Any) -> bool:
    def ids(v: Any) -> list[str]:
        return [_key(x["id"]) for x in _arr(v) or [] if isinstance(x, dict) and x.get("id") is not None]

    ida, idb = ids(a), ids(b)
    sa, sb = set(ida), set(idb)
    return [i for i in ida if i in sb] != [i for i in idb if i in sa]


def _stamp_edits(prev: Object, nxt: Object, now: float) -> None:
    ed = dict(_obj(nxt.get("edited")) or {})
    stamp = _out(now)
    touched = False
    for k in set(prev) | set(nxt):
        if k in _OWN_MERGE:
            continue
        p, n = _g(prev, k), _g(nxt, k)
        if _eq(p, n):
            continue
        if k in _PER_KEY:
            pm, nm = _obj(p) or {}, _obj(n) or {}
            for s in set(pm) | set(nm):
                if not _eq(_g(pm, s), _g(nm, s)):
                    ed[f"{k}.{s}"] = stamp
                    touched = True
        else:
            ed[k] = stamp
            touched = True
    if _order_moved(prev.get("routines"), nxt.get("routines")):
        ed["routineOrder"] = stamp
        touched = True
    # An own accent colour is one choice made in two fields: either one changed stamps both.
    if touched and _eq(_g(nxt, "accent"), "custom") and (_eq(_g(ed, "accent"), now) or _eq(_g(ed, "accentCustom"), now)):
        ed["accent"] = stamp
        ed["accentCustom"] = stamp
    if touched:
        # A per-key stamp of a key no longer there is dropped after half a year.
        for k, at in list(ed.items()):
            dot = k.find(".")
            if dot < 0 or now - _num(at) < _EDIT_KEEP_MS:
                continue
            mp = nxt.get(k[:dot])
            if not isinstance(mp, dict) or k[dot + 1:] not in mp:
                del ed[k]
        nxt["edited"] = ed
    if "undone" in nxt:
        marks = _settle_marks(nxt["undone"], ed, now)
        if marks is None:
            del nxt["undone"]
        else:
            nxt["undone"] = marks


def stamp_change(prev: Object, nxt: Object, wall_ms: float) -> int | float:
    """Stamps into `nxt` (in place) what differs from `prev`; returns the time used, which the
    caller sets as `nxt["_ts"]` (SyncStamps.stampChange)."""
    now = max(float(wall_ms), highest_stamp(prev) + 1)

    # Workouts a screen re-stamped: an edit takes the change's time, a no-op save keeps its stamp.
    workouts = _arr(nxt.get("workouts"))
    if workouts is not None:
        before = _by_id(prev.get("workouts"))
        for i, w in enumerate(workouts):
            if not isinstance(w, dict) or w.get("id") is None or w.get("_ts") is None:
                continue
            old = before.get(_key(w["id"]))
            if old is None or _eq(_g(old, "_ts"), w["_ts"]):
                continue
            w = dict(w)
            if _same_entry(old, w):
                if old.get("_ts") is not None:
                    w["_ts"] = old["_ts"]
                else:
                    w.pop("_ts", None)
            else:
                _stamp_entry(old, w, now)
            workouts[i] = w

    # Settings maps whose entries carry their own stamp.
    for f in STAMPED_MAPS:
        n = _obj(nxt.get(f))
        if n is None:
            continue
        p = _obj(prev.get(f)) or {}
        for k, v in list(n.items()):
            if not isinstance(v, dict) or v.get("_ts") is None:
                continue
            old = p.get(k)
            if _num(v.get("_ts")) == (_num(old.get("_ts")) if isinstance(old, dict) else 0.0):
                continue
            n[k] = {**v, "_ts": _out(now)}

    # A weigh-in or check-in the change logged or corrected (its `t` moved).
    for f in ("bodyweight", "measurements"):
        entries = _arr(nxt.get(f))
        if entries is None:
            continue
        before_d: dict[str, Object] = {}
        for e in _arr(prev.get(f)) or []:
            if isinstance(e, dict) and e.get("d") is not None:
                before_d[_key(e["d"])] = e
        for i, e in enumerate(entries):
            if not isinstance(e, dict) or e.get("d") is None or e.get("t") is None:
                continue
            old = before_d.get(_key(e["d"]))
            if old is not None and _eq(_g(old, "t"), e["t"]):
                continue
            was = _num(e["t"])
            at = max(was, now)
            e = {**e, "t": _out(at)}
            ins = _arr(e.get("ins"))
            if f == "bodyweight" and ins is not None and at != was:
                prior: dict[str, Object] = {}
                for r in _arr((old or {}).get("ins")) or []:
                    if isinstance(r, dict) and r.get("id") is not None:
                        prior[_key(r["id"])] = r
                ins = list(ins)
                for j, r in enumerate(ins):
                    if not isinstance(r, dict):
                        continue
                    pr = prior.get(_key(r["id"])) if "id" in r else None
                    if pr is None or any(not _eq(_g(pr, k), _g(r, k)) for k in ("t", "w", "at")):
                        ins[j] = {**r, "t": _out(at)}
                e["ins"] = ins
                gone = _obj(e.get("gone"))
                if gone is not None:
                    old_gone = _obj((old or {}).get("gone")) or {}
                    e["gone"] = {
                        k: _out(at) if k not in old_gone or _num(v) != _num(old_gone[k]) else v
                        for k, v in gone.items()
                    }
            entries[i] = e

    # A routine put back by an Undo keeps the edit time it had.
    gone_routines = _obj((_obj(prev.get("deleted")) or {}).get("routines")) or {}
    prev_routine_ids = {_key(r["id"]) for r in _arr(prev.get("routines")) or [] if isinstance(r, dict) and "id" in r}

    def put_back(r: Object) -> bool:
        if "id" not in r:
            return False
        k = _key(r["id"])
        removed = _num(gone_routines[k]) if k in gone_routines else 0.0
        ts = _num(r["_ts"]) if "_ts" in r else 0.0
        return removed > 0 and (not ts > 0 or ts < removed) and k not in prev_routine_ids

    _stamp_entries("routines", prev, nxt, now, skip=put_back)
    for f in ("customEx", "equipProfiles", "gymCards"):
        _stamp_entries(f, prev, nxt, now)
    _stamp_deletions(prev, nxt, now)
    _stamp_edits(prev, nxt, now)
    return _out(now)


# MARK: - Exercise catalogue (HexplateCore ExerciseCatalog over `queries.CATALOGUE`, C4)

_RE_BENCH = re.compile(r"\bbench\b|\bincline\b|\bdecline\b", re.I)
_RE_BAR = re.compile(r"pull-up|pull up|chin-up|\bchin\b|hanging|dead hang|muscle-up|muscle up", re.I)
_RE_ASSIST = re.compile(r"\bassist(ed)?\b", re.I)
_RE_ONE_LIMB = re.compile(r"\b(single|one)[\s-]+(arm|leg|hand)\b|\bunilateral\b", re.I)
_RE_NOT_ONE_LIMB = re.compile(r"stretch|\broll(er|ball)?\b|two to one|single leg (push|plank)|leg push up", re.I)


@cache
def _catalog() -> Object:
    try:
        data = json.loads(queries.CATALOGUE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    exercises = [e for e in data.get("exercises") or [] if isinstance(e, dict) and isinstance(e.get("id"), str)]
    by_id: dict[str, Object] = {}
    for e in exercises:
        by_id.setdefault(e["id"], e)
    for alias, target in (data.get("aliases") or {}).items():
        if target in by_id:
            by_id[alias] = by_id[target]
    meta = data.get("meta") or {}
    return {
        "all": exercises,
        "by_id": by_id,
        "muscles": [m for m in meta.get("muscles") or [] if isinstance(m, str)],
        "equipment": [m for m in meta.get("equipment") or [] if isinstance(m, str)],
    }


def _ex(ex_id: Any) -> Object | None:
    # ponytail: the profile's custom exercises are not merged into the catalogue (names still come
    # from `queries.name_of`); add `customEx` here if the Coach should score or load them.
    return _catalog()["by_id"].get(ex_id) if isinstance(ex_id, str) else None


def _ex_name(e: Object) -> str:
    return e.get("n") if isinstance(e.get("n"), str) else ""


def _ex_eq(e: Object | None) -> str | None:
    return e.get("eq") if e is not None and isinstance(e.get("eq"), str) else None


def _is_cardio(e: Object | None) -> bool:
    return e is not None and e.get("bp") == "cardio"


def _is_hold(e: Object | None) -> bool:
    return e is not None and e.get("hd") is True


def _is_bodyweight_eq(e: Object | None) -> bool:
    return _ex_eq(e) in ("body weight", "band", "resistance band")


def _is_assisted_ex(e: Object) -> bool:
    if isinstance(e.get("assisted"), bool):
        return e["assisted"]
    return _ex_eq(e) == "leverage machine" and bool(_RE_ASSIST.search(_ex_name(e)))


def _is_one_limb(e: Object | None) -> bool:
    if e is None or e.get("custom") is True or _is_cardio(e):
        return False
    name = _ex_name(e)
    return bool(_RE_ONE_LIMB.search(name)) and not _RE_NOT_ONE_LIMB.search(name)


def _muscle_weights(e: Object) -> dict[str, float]:
    return {k: float(v) for k, v in (_obj(e.get("mw")) or {}).items() if _is_num(v)}


def _primary_muscle(e: Object) -> str | None:
    muscles = _catalog()["muscles"]
    ranked = [(w, -muscles.index(k), k) for k, w in _muscle_weights(e).items() if k in muscles]
    return max(ranked)[2] if ranked else None


def _accessories(e: Object) -> list[str]:
    name = _ex_name(e)
    if not name or (_ex_eq(e) or "") in ("leverage machine", "sled machine", "assisted"):
        return []
    need = []
    if _RE_BENCH.search(name):
        need.append("bench")
    if _RE_BAR.search(name):
        need.append("pull-up bar")
    for a in _strings(e.get("nd")):
        if a in ("bench", "pull-up bar") and a not in need:
            need.append(a)
    return need


def _is_available(e: Object, equipment: list[str]) -> bool:
    eq = _ex_eq(e)
    if eq and eq != "body weight" and eq in _catalog()["equipment"] and eq not in equipment:
        return False
    return all(a in equipment for a in _accessories(e))


def _profile_equipment(profile: Object) -> list[str]:
    have = _strings(profile.get("equipment"))
    if _eq(_g(profile, "accV"), 2):
        return have
    add = ["bench", "pull-up bar"] if _num(profile.get("accV")) < 1 else []
    if "roller" in have:
        add.append("massage ball")
    return list(dict.fromkeys(have + add))


def _active_profile(root: Object) -> Object | None:
    if root.get("equipFilterOn") is not True or root.get("activeEquipId") is None:
        return None
    pid = root["activeEquipId"]
    return next((p for p in _arr(root.get("equipProfiles")) or [] if isinstance(p, dict) and _eq(_g(p, "id"), pid)), None)


def _cap_words(s: str) -> str:
    out, boundary = [], True
    for ch in s:
        out.append(ch.upper() if boundary and ch.islower() else ch)
        boundary = ch.isspace() or ch in "(-/"
    return "".join(out)


def _display_name(ex_id: str, state: Object | None, lang: str) -> str:
    e = _ex(ex_id)
    if e is None:
        return queries.name_of(ex_id, state)
    if lang.lower().startswith("zh"):
        from . import i18n  # the zh names live in the app's JSON, never in this module

        zh = i18n.exercise_names().get(ex_id)
        if zh:
            return zh
    return _cap_words(_ex_name(e))


def _slot_mode(cfg: Object) -> str:
    """RoutineOps.mode: how a slot is logged."""
    m = cfg.get("mode")
    if m in ("reps", "time", "cardio"):
        return m
    if cfg.get("min") is not None or cfg.get("speed") is not None:
        return "cardio"
    return "cardio" if _is_cardio(_ex(cfg.get("id"))) else "reps"


def _picked_config(ex_id: str) -> Object:
    """RoutineOps.pickedConfig: what a freshly picked exercise starts with."""
    e = _ex(ex_id)
    if not _is_hold(e) and _is_cardio(e):
        return {"sets": 1, "min": 20, "speed": 8}
    timed = _is_hold(e)
    cfg: Object = {"sets": 3, "weight": 0, "mode": "time" if timed else "reps"}
    cfg["sec" if timed else "reps"] = 45 if timed else 10
    if _is_bodyweight_eq(e):
        cfg["bodyweight"] = True
    if _is_one_limb(e):
        cfg["side"] = True
        if not timed:
            cfg["reps"] = 20
    return cfg


def _sg(e: Any) -> str | None:
    tag = e.get("sg") if isinstance(e, dict) else None
    return tag if isinstance(tag, str) and tag else None


def _cleanup_supersets(ex: list) -> None:
    """RoutineOps.cleanupSupersets: lonely tags go; every group member carries the group's meta."""
    for i in range(len(ex)):
        tag = _sg(ex[i])
        if tag is None or not isinstance(ex[i], dict):
            continue
        before = _sg(ex[i - 1]) if i > 0 else None
        after = _sg(ex[i + 1]) if i + 1 < len(ex) else None
        if before != tag and after != tag:
            ex[i] = {k: v for k, v in ex[i].items() if k != "sg"}
    names: dict[str, str] = {}
    rests: dict[str, float] = {}
    order: list[str] = []
    for i, e in enumerate(ex):
        if not isinstance(e, dict):
            continue
        tag = _sg(e)
        if tag is None:
            ex[i] = {k: v for k, v in e.items() if k not in ("sgName", "sgRest")}
            continue
        if tag not in order:
            order.append(tag)
        if tag not in names and isinstance(e.get("sgName"), str) and e["sgName"]:
            names[tag] = e["sgName"]
        if tag not in rests and "sgRest" in e and _num(e["sgRest"]) > 0:
            rests[tag] = _num(e["sgRest"])
    for tag in order:
        name = names.get(tag, "").strip(" ")[:40]
        rest = math.floor(rests[tag] + 0.5) if tag in rests else 0
        for i, e in enumerate(ex):
            if _sg(e) != tag or not isinstance(e, dict):
                continue
            e = {k: v for k, v in e.items() if k not in ("sgName", "sgRest")}
            if name:
                e["sgName"] = name
            if rest > 0:
                e["sgRest"] = rest
            ex[i] = e


# MARK: - Recovery (exact port of Recovery.swift fatigue / loadSummary)

_DAY_MS = 86_400_000.0
_SCAN_MS, _RIR_WINDOW_MS, _ACUTE_MS, _CHRONIC_MS = 30 * _DAY_MS, 90 * _DAY_MS, 7 * _DAY_MS, 28 * _DAY_MS
_SETS_PER_UNIT, _CARDIO_MINUTES, _MAX_SETS, _RIR_FLOOR = 8.0, 30.0, 12.0, 0.3
_NOVICE_WEEKLY, _BODYWEIGHT_REF, _LB_TO_KG, _HARD_RIR, _REP_CAP = 4.0, 75.0, 0.45359237, 3.0, 12.0
_HOURS24 = {"deltoids", "serratus", "biceps", "triceps", "forearm", "abs", "obliques", "hip-flexors", "tibialis"}
_HOURS48 = {"lower-back", "gluteal", "quadriceps", "hamstring", "adductors", "calves"}
_UNIT_KEYS = ("unit", "u", "weightUnit", "weight_unit", "loadUnit")


def _half_life(slug: str) -> float:
    return (24 if slug in _HOURS24 else 48 if slug in _HOURS48 else 30) * 3_600_000


def day_noon_ms(iso: Any) -> float:
    """Noon UTC of a `YYYY-MM-DD` day in ms, NaN for anything else.

    ponytail: the phone reads noon in its own zone; UTC noon keeps day-only workouts on their day
    and differs from a `start` stamp by at most the zone offset."""
    n = ai._parse_iso_day_number(iso)
    return math.nan if n is None else n * _DAY_MS + 12 * 3_600_000


def _numeric(v: Any) -> float | None:
    """Recovery.numeric: None for missing, null, "" or a bool, else a finite Number()."""
    if _is_num(v):
        return float(v) if math.isfinite(v) else None
    if isinstance(v, str):
        if not v:
            return None
        t = v.strip()
        if not t:
            return 0.0
        try:
            x = float(t)
        except ValueError:
            return None
        return x if math.isfinite(x) and "_" not in t else None
    return None


def _truthy(v: Any) -> bool:
    if isinstance(v, bool):
        return v
    if _is_num(v):
        return v != 0 and v == v
    if isinstance(v, str):
        return bool(v)
    return isinstance(v, (list, dict))


def _workout_at(w: Object) -> float:
    s = w.get("start")
    return float(s) if _is_num(s) and math.isfinite(s) else day_noon_ms(w.get("d"))


def _is_warmup_row(row: Object | None) -> bool:
    if row is None:
        return False
    p = row.get("phase")
    if p is not None and p != "":
        token = p.strip().lower() if isinstance(p, str) else ""
        return token in ("warmup", "warm-up", "warm_up")
    return row.get("warmup") is True


def _rir(row: Object | None) -> float | None:
    if row is None:
        return None
    if row.get("rir") is not None:
        return _numeric(row["rir"])
    if row.get("rpe") is not None:
        v = _numeric(row["rpe"])
        return None if v is None else 10 - v
    return 0.0 if row.get("failure") is True and not _is_warmup_row(row) else None


def _done(row: Any) -> bool:
    return isinstance(row, dict) and row.get("done") is True


def _stamped(v: Any) -> bool:
    if v is _MISSING or v is None:
        return False
    return bool(v.strip()) if isinstance(v, str) else True


def _unit(*records: Object | None) -> Any:
    for r in records:
        if r is None:
            continue
        for k in _UNIT_KEYS:
            if _stamped(_g(r, k)):
                return r[k]
    return "kg"


def _has_unit_stamp(*records: Object | None) -> bool:
    return any(_stamped(_g(r, k)) for r in records if r is not None for k in _UNIT_KEYS)


def _is_pounds(u: Any) -> bool:
    return isinstance(u, str) and u != "kg" and u.strip().lower() in ("lb", "lbs", "pound", "pounds")


def _kg(v: Any, u: Any) -> float:
    n = _numeric(v)
    return 0.0 if n is None else max(0.0, n) * (_LB_TO_KG if _is_pounds(u) else 1.0)


class _Opts:
    def __init__(self, unit: str | None, bodyweight_kg: float | None):
        self.record: Object = {"unit": unit} if unit is not None else {}
        self.bodyweight_kg = bodyweight_kg


def _lifter_kg(w: Object, o: _Opts, load_unit: Any) -> float:
    s = _numeric(w.get("bw"))
    if s is None:
        s = _numeric(w.get("bodyweight"))
    if s is not None:
        return _kg(s, _unit({"unit": w.get("bwUnit")}, {"unit": w.get("bodyweightUnit")}, w,
                            None if load_unit is None else {"unit": load_unit}, o.record))
    if o.bodyweight_kg is not None:
        return max(0.0, o.bodyweight_kg)
    return _BODYWEIGHT_REF


def _entry_equipment(entry: Object) -> str | None:
    eq = _ex_eq(_ex(entry.get("id")))
    return eq if eq is not None else (entry.get("eq") if isinstance(entry.get("eq"), str) else None)


def _bodyweight_configured(entry: Object, set_: Object, w: Object, o: _Opts) -> bool:
    target = _obj(entry.get("target"))
    if target is not None and "bodyweight" in target:
        return _truthy(target["bodyweight"])
    if "bodyweight" in entry:
        return _truthy(entry["bodyweight"])
    if _entry_equipment(entry) != "body weight":
        return False
    added = _kg(set_.get("w"), _unit(set_, target, entry, w, o.record))
    context = (_numeric(w.get("bw")) is not None or _numeric(w.get("bodyweight")) is not None
               or o.bodyweight_kg is not None or _has_unit_stamp(set_, target, entry, w))
    return added == 0 or context


def _load_kg(entry: Object, set_: Object, w: Object, o: _Opts, row: Object) -> float:
    target = _obj(entry.get("target"))
    row_unit = _unit(row, set_, target, entry, w, o.record)
    added = _kg(row.get("w"), row_unit)
    if not _bodyweight_configured(entry, set_, w, o):
        return added
    load_unit = row_unit if _has_unit_stamp(row, set_, target, entry) else None
    return _lifter_kg(w, o, load_unit) + added


def _snapshot_weights(ex: Object | None) -> dict[str, float] | None:
    mw = _obj(ex.get("muscleWeights")) if ex is not None else None
    if mw is None:
        return None
    out = {}
    for slug in _catalog()["muscles"]:
        v = _numeric(mw.get(slug))
        if v is not None and 0 <= v <= 1:
            out[slug] = v
    return {k: v for k, v in out.items() if v > 0} if out else None


def _entry_muscles(entry: Object) -> dict[str, float]:
    e = _ex(entry.get("id"))
    if e is not None:
        muscles = _catalog()["muscles"]
        return {k: v for k, v in _muscle_weights(e).items() if v > 0 and k in muscles}
    return _snapshot_weights(entry) or {}


def _entries(w: Object) -> list[Object]:
    return [e for e in _arr(w.get("entries")) or [] if isinstance(e, dict)]


def _rows(e: Object) -> list[Object]:
    return [s if isinstance(s, dict) else {} for s in _arr(e.get("sets")) or []]


def _rir_weight(rir: float | None) -> float:
    if rir is None or rir <= _HARD_RIR:
        return 1.0
    if rir >= 6:
        return _RIR_FLOOR
    return 1 - (1 - _RIR_FLOOR) * (rir - _HARD_RIR) / (6 - _HARD_RIR)


def _estimate_rir(load: float, reps: float | None, anchor: float) -> float | None:
    if not (anchor > 0 and load > 0 and reps is not None and 1 <= reps <= _REP_CAP):
        return None
    return min(10.0, max(0.0, 30 * (anchor / load - 1) - reps))


def _js_round(v: float) -> float:
    return math.floor(v + 0.5)


def _estimate_1rm(w: float, r: float) -> float | None:
    """Stats.estimate1RM with the default Epley formula and no rated RIR."""
    if not (math.isfinite(w) and math.isfinite(r) and w > 0 and r >= 1):
        return None
    if r == 1:
        return _js_round(w * 10) / 10
    if r > 12:
        return None
    est = w * (1 + _js_round(r) / 30)
    return _js_round(est * 10) / 10 if math.isfinite(est) and est > 0 else None


def _is_assisted_cfg(cfg: Object) -> bool:
    if isinstance(cfg.get("assisted"), bool):
        return cfg["assisted"]
    target = _obj(cfg.get("target")) or {}
    if isinstance(target.get("assisted"), bool):
        return target["assisted"]
    e = _ex(cfg.get("id"))
    return e is not None and _is_assisted_ex(e)


def _is_side_set(s: Object) -> bool:
    sides = _obj(s.get("sides"))
    return sides is not None and isinstance(sides.get("L"), dict) and isinstance(sides.get("R"), dict)


def _session_eff_sets(w: Object, anchors: dict[str, float], o: _Opts) -> dict[str, float]:
    sums: dict[str, float] = {}
    for entry in _entries(w):
        weights = _entry_muscles(entry)
        mode = _slot_mode({**(_obj(entry.get("target")) or {}), "id": entry.get("id")})
        eid = entry.get("id") if isinstance(entry.get("id"), str) else ""

        def score(row: Object, set_: Object, require_done: bool) -> None:
            if require_done and not _done(row):
                return
            resolved = _resolve_rir(row, set_, entry, w, anchors.get(eid), o)
            logged = resolved is not None and resolved[1]
            count = _RIR_FLOOR if not logged and _is_warmup_row(set_) else _rir_weight(resolved[0] if resolved else None)
            # Number(row.min): missing is NaN (no scaling), null is 0.
            minutes = None if "min" not in row else 0.0 if row["min"] is None else _numeric(row["min"])
            scale = max(0.0, minutes) / _CARDIO_MINUTES if mode == "cardio" and minutes is not None else 1.0
            for slug, weight in weights.items():
                sums[slug] = sums.get(slug, 0.0) + count * scale * weight

        for set_ in _rows(entry):
            score(set_, set_, True)
            if _done(set_) and set_.get("type") == "dropset" and isinstance(set_.get("drops"), list):
                for d in set_["drops"]:
                    score(d if isinstance(d, dict) else {}, set_, False)
    return {k: min(v, _MAX_SETS) for k, v in sums.items()}


def _resolve_rir(row: Object, set_: Object, entry: Object, w: Object, anchor: float | None, o: _Opts):
    logged = _rir(row)
    if logged is not None:
        return logged, True
    if anchor is None or anchor <= 0:
        return None
    est = _estimate_rir(_load_kg(entry, set_, w, o, row), _numeric(row.get("r")), anchor)
    return None if est is None else (est, False)


def _session_bests(w: Object, o: _Opts) -> dict[str, float]:
    best: dict[str, float] = {}
    for entry in _entries(w):
        eid = entry.get("id") if isinstance(entry.get("id"), str) else ""
        if _is_assisted_cfg({"id": entry.get("id")}):
            continue
        for set_ in _rows(entry):
            if not _done(set_):
                continue
            pair = _obj(set_.get("sides")) or {}
            sides = ([s for s in (_obj(pair.get("L")) or {}, _obj(pair.get("R")) or {}) if _done(s)]
                     if _is_side_set(set_) else [set_])
            for side in sides:
                reps = _numeric(side.get("r"))
                logged = _rir(side)
                if logged is None:
                    logged = _rir(set_)
                if reps is None:
                    continue
                est = _estimate_1rm(_load_kg(entry, set_, w, o, side), reps + logged if logged is not None else reps)
                if est is not None and est > best.get(eid, -math.inf):
                    best[eid] = est
    return best


def _fatigue_state(workouts: list[Object], now: float, unit: str | None, bodyweight_kg: float | None):
    muscles = _catalog()["muscles"]
    values = {m: 0.0 for m in muscles}
    last_sets = {m: 0.0 for m in muscles}
    if not math.isfinite(now):
        return values, last_sets, 0.0, 0.0
    o = _Opts(unit, bodyweight_kg)
    cutoff = now - (_SCAN_MS + _RIR_WINDOW_MS)
    pool = [(w, i, ts) for i, w in enumerate(workouts) if math.isfinite(ts := _workout_at(w)) and ts > cutoff]
    pool.sort(key=lambda item: (item[2], item[1]))
    bests = [_session_bests(w, o) for w, _, _ in pool]
    eff_sets: list[dict[str, float]] = []
    for i, (w, _, ts) in enumerate(pool):
        anchors: dict[str, float] = {}
        for j in range(i + 1):
            if pool[j][2] > ts - _RIR_WINDOW_MS:
                for eid, est in bests[j].items():
                    if est > anchors.get(eid, -math.inf):
                        anchors[eid] = est
        eff_sets.append(_session_eff_sets(w, anchors, o))

    events: dict[str, list[tuple[float, float]]] = {}
    global_acute = global_chronic_28d = 0.0
    for i, (_, _, ts) in enumerate(pool):
        if not ts > now - _SCAN_MS:
            continue
        acute: dict[str, float] = {}
        chronic: dict[str, float] = {}
        for j in range(i + 1):
            age = ts - pool[j][2]
            if age < 0 or age > _CHRONIC_MS:
                continue
            for slug, v in eff_sets[j].items():
                if age <= _ACUTE_MS:
                    acute[slug] = acute.get(slug, 0.0) + v
                chronic[slug] = chronic.get(slug, 0.0) + v
        for slug, stim in eff_sets[i].items():
            if stim <= 0:
                continue
            gain = min(2.0, max(0.5, (acute.get(slug, 0.0) + _NOVICE_WEEKLY) / (chronic.get(slug, 0.0) / 4 + _NOVICE_WEEKLY)))
            events.setdefault(slug, []).append((ts, stim / _SETS_PER_UNIT * gain))
            if ts <= now and slug in last_sets:
                last_sets[slug] = stim
        age_now = now - ts
        if 0 <= age_now <= _CHRONIC_MS:
            total = sum(eff_sets[i].values())
            global_chronic_28d += total
            if age_now <= _ACUTE_MS:
                global_acute += total
    for slug, lst in events.items():
        if slug not in values:
            continue
        hl = _half_life(slug)
        value, last = 0.0, lst[0][0]
        for ts, stim in lst:
            value = value * 0.5 ** ((ts - last) / hl) + stim
            last = ts
        values[slug] = value * 0.5 ** (max(0.0, now - last) / hl)
    return values, last_sets, global_acute, global_chronic_28d / 4.0


def fatigue_map(workouts: list[Object], now_ms: float, *, unit: str | None, bodyweight_kg: float | None) -> dict[str, float]:
    """Recovery.fatigue: muscle -> fatigue (0...1) at `now_ms`."""
    values = _fatigue_state([w for w in workouts if isinstance(w, dict)], float(now_ms), unit, bodyweight_kg)[0]
    return {k: 1 - math.exp(-v) for k, v in values.items()}


def latest_bodyweight_kg(state: Object) -> float | None:
    """Balance.bodyweightKg: the latest weigh-in by day, in kg."""
    entries = sorted((e for e in _arr(state.get("bodyweight")) or [] if isinstance(e, dict)),
                     key=lambda e: e.get("d") if isinstance(e.get("d"), str) else "")
    if not entries or _num(entries[-1].get("w")) <= 0:
        return None
    w = _num(entries[-1].get("w"))
    return w * _LB_TO_KG if state.get("unit") == "lb" else w


def compute_recovery(state: Object, now_ms: float) -> Object:
    """Recovery.loadSummary over the profile document."""
    workouts = [w for w in _arr(state.get("workouts")) or [] if isinstance(w, dict)]
    unit = state.get("unit") if isinstance(state.get("unit"), str) else None
    values, last_sets, acute, chronic = _fatigue_state(workouts, float(now_ms), unit, latest_bodyweight_kg(state))
    ln2 = math.log(2.0)
    muscles = {}
    for slug in _catalog()["muscles"]:
        value = values.get(slug, 0.0)
        hours = _half_life(slug) / 3_600_000.0 * math.log2(value / ln2) if value > ln2 else 0.0
        muscles[slug] = {"fatigue": 1 - math.exp(-value), "lastSessionSets": last_sets.get(slug, 0.0), "hoursToRecovered": hours}
    ratio = acute / chronic if chronic >= _NOVICE_WEEKLY else None
    return {"muscles": muscles, "global": {"acute": acute, "chronic": chronic, "ratio": ratio}}


# MARK: - Plan days (CoachContext.dayDigest / lockReason / functionalEx)

def _routines_by_id(root: Object) -> dict[str, Object]:
    out: dict[str, Object] = {}
    for r in _arr(root.get("routines")) or []:
        if isinstance(r, dict) and isinstance(r.get("id"), str):
            out.setdefault(r["id"], r)
    return out


def _is_ai_clone(r: Object | None) -> bool:
    return isinstance(r, dict) and r.get("aiClone") is True


def _functional_ex(routine: Object | None) -> list[Object]:
    return [_strip_meta(x) for x in _arr((routine or {}).get("ex")) or [] if isinstance(x, dict)]


def _window(today: str) -> list[str]:
    return [schedule.adding(i, today) for i in range(WINDOW_DAYS + 1)]


def _is_logged(root: Object, date: str) -> bool:
    return any(isinstance(w, dict) and w.get("d") == date for w in _arr(root.get("workouts")) or [])


def _active_day(root: Object) -> Any:
    return (_obj(root.get("active")) or {}).get("d")


def day_digest(root: Object, date: str, today: str) -> str:
    """CoachContext.dayDigest: 16 hex chars over the day's effective plan and lock state."""
    mode = schedule.schedule_mode(root)
    ids = schedule.routine_ids(root, date, today)
    by_id = _routines_by_id(root)
    q = schedule.queue(root) if mode == "rotation" else None
    payload = {
        "canonicalIds": [schedule._canonical(root, i) for i in ids],
        "isActive": _active_day(root) == date,
        "isLogged": _is_logged(root, date),
        "queue": {"ids": q["ids"], "remaining": schedule.queue_remaining(root), "startsOn": q["startsOn"]} if q else None,
        "rawDayPlan": (_obj(root.get("dayPlan")) or {}).get(date),
        "resolvedEx": [_functional_ex(by_id.get(i)) for i in ids],
        "resolvedIds": ids,
        "scheduleMode": mode,
    }
    return hashlib.sha256(_canonical_json(payload).encode("utf-8")).hexdigest()[:16]


def _lock_reason(root: Object, date: str, today: str) -> str | None:
    """CoachContext.lockReason (active > logged > multi > orphan), plus R3: today is always
    `active` on the web, since the server cannot see a live iPhone session."""
    if date == today or _active_day(root) == date:
        return "active"
    if _is_logged(root, date):
        return "logged"
    ids = schedule.routine_ids(root, date, today)
    if len(ids) > 1:
        return "multi"
    if ids and _is_ai_clone(_routines_by_id(root).get(ids[0])) and schedule._canonical(root, ids[0]) == ids[0]:
        return "orphan"
    return None


# MARK: - C6: the client's today must be the server's today (+/- 1 day) in the client's zone

def _zone(timezone: Any) -> dt.tzinfo:
    if isinstance(timezone, str) and timezone.strip():
        try:
            return ZoneInfo(timezone.strip())
        except Exception:  # ZoneInfoNotFoundError, ValueError, OSError on odd keys
            pass
    return dt.timezone.utc


def check_today(today: Any, timezone: Any) -> str:
    """`today` when it is a valid date within one day of the server's date in `timezone` (UTC when
    unknown), else `AIBadRequestError(code="invalid-today")`."""
    if ai._parse_iso_day_number(today) is None:
        raise AIBadRequestError("today must be a valid YYYY-MM-DD date.", code="invalid-today")
    server_day = dt.datetime.now(_zone(timezone)).date()
    if abs((dt.date.fromisoformat(today) - server_day).days) > MAX_TODAY_SKEW_DAYS:
        raise AIBadRequestError("today does not match the server's date for this time zone.", code="invalid-today")
    return today


# MARK: - Context (CoachContext.build)

def _meal_macros(state: Object, day: str) -> Object:
    total = {"kcal": 0.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0}
    for key, m in (_obj(state.get("meals")) or {}).items():
        if not isinstance(m, dict) or m.get("deleted") is True or m.get("date") != day:
            continue
        mid = (m.get("id") if isinstance(m.get("id"), str) else key).strip()
        if not mid:
            continue
        for k in total:
            v = m.get(k)
            if _is_num(v) and math.isfinite(v) and v > 0:
                total[k] += v
    return total


def _nutrition(state: Object, today: str) -> Object:
    goals = _obj(state.get("nutritionGoals")) or {}

    def positive(k: str) -> float | None:
        v = goals.get(k)
        return float(v) if _is_num(v) and math.isfinite(v) and v > 0 else None

    per_kg = positive("proteinPerKg") or 2.0
    weights = sorted((e for e in _arr(state.get("bodyweight")) or [] if isinstance(e, dict) and _num(e.get("w")) > 0),
                     key=lambda e: e.get("d") if isinstance(e.get("d"), str) else "")
    weight_kg = None
    if weights:
        w = _num(weights[-1].get("w"))
        weight_kg = w * _LB_TO_KG if state.get("unit") == "lb" else w
    protein, derived = positive("protein"), False
    if protein is None and weight_kg is not None:
        protein, derived = _round(weight_kg * per_kg), True
    hexplate = _meal_macros(state, today)
    # ponytail: Apple Health nutrition lives on the phone only, so `external` is always absent here.
    return {
        "hexplate": hexplate,
        "total": dict(hexplate),
        "goals": _drop_none({
            "kcal": positive("kcal"), "protein": protein, "proteinIsDerived": derived, "carbs": positive("carbs"),
            "fat": positive("fat"), "proteinPerKg": per_kg, "weightKgUsed": weight_kg,
        }),
    }


def _drop_none(d: Object) -> Object:
    """Swift's JSONEncoder leaves out nil optionals."""
    return {k: v for k, v in d.items() if v is not None}


def _slot_summary(cfg: Object, idx: int, alias_of: dict[str, str], state: Object, lang: str) -> Object:
    ex_id = cfg.get("id") if isinstance(cfg.get("id"), str) else ""
    mode = _slot_mode(cfg)
    sets = cfg.get("sets")
    reps, sec = cfg.get("reps"), cfg.get("sec")
    name = _display_name(ex_id, state, lang) if _ex(ex_id) else (cfg.get("name") if isinstance(cfg.get("name"), str) else queries.name_of(ex_id, state))
    return _drop_none({
        "slotIndex": idx,
        "alias": alias_of.get(ex_id, ex_id),
        "exerciseId": ex_id,
        "name": name,
        "mode": mode,
        "sets": max(1, int(_round(sets if _is_num(sets) else 3))),
        "reps": int(_round(reps)) if mode == "reps" and _is_num(reps) else None,
        "sec": int(_round(sec)) if mode == "time" and _is_num(sec) else None,
        # ponytail: programme percentages are not ported (Programmes.slot); the phone shows them.
        "hasProgrammePct": False,
    })


def _recent_workouts(state: Object, today: str) -> list[Object]:
    since = schedule.adding(-(RECENT_WORKOUT_DAYS - 1), today)
    ws = [w for w in _arr(state.get("workouts")) or [] if isinstance(w, dict) and isinstance(w.get("d"), str) and since <= w["d"] <= today]
    ws.sort(key=lambda w: (w["d"], _num(w.get("start"))), reverse=True)
    out = []
    for w in ws:
        muscle_sets: dict[str, float] = {}
        sets_done, volume = 0, 0.0
        for e in _entries(w):
            done = [s for s in _rows(e) if _done(s) and not _is_warmup_row(s)]
            sets_done += len(done)
            # ponytail: plain weight x reps (WorkoutMath.volume also adds body weight and units).
            volume += sum(max(0.0, _num(s.get("w"))) * max(0.0, _num(s.get("r"))) for s in done)
            ex = _ex(e.get("id"))
            if done and ex is not None:
                for slug, wt in _muscle_weights(ex).items():
                    if wt > 0:
                        muscle_sets[slug] = muscle_sets.get(slug, 0.0) + len(done) * wt
        top = [k for k, _ in sorted(muscle_sets.items(), key=lambda kv: (-kv[1], kv[0]))[:3]]
        out.append(_drop_none({
            "date": w["d"],
            "name": w.get("name") if isinstance(w.get("name"), str) else "Workout",
            "routineId": w.get("routineId") if isinstance(w.get("routineId"), str) else None,
            "setsDone": sets_done,
            "volume": _round(volume, 1),
            "topMuscles": top,
        }))
    return out


def _build_snapshot(state: Object, today: str, timezone: str, lang: str, now_ms: float) -> Object:
    mode = schedule.schedule_mode(state)
    allowed = ["skip", "swap_exercise", "set_sets", "add"] if mode == "rotation" else ["move_day", "skip", "swap_exercise", "set_sets", "add"]
    routines = [r for r in _arr(state.get("routines")) or [] if isinstance(r, dict)]
    by_id = _routines_by_id(state)
    catalog = _catalog()

    # 1. R1..Rn for non-clone routines, in document order.
    routine_aliases, alias_of_routine = [], {}
    for r in routines:
        rid = r.get("id")
        if _is_ai_clone(r) or not isinstance(rid, str) or not rid:
            continue
        alias = f"R{len(routine_aliases) + 1}"
        routine_aliases.append({"alias": alias, "id": rid, "name": r.get("name") if isinstance(r.get("name"), str) else ""})
        alias_of_routine[rid] = alias

    # 2. Exercises already in the routines and the 15-day plan.
    dates = _window(today)
    plan_order: list[str] = []
    plan_cardio = False
    demand: dict[str, float] = {}

    def register(ex_id: Any) -> None:
        nonlocal plan_cardio
        if not isinstance(ex_id, str) or not ex_id:
            return
        if ex_id not in plan_order:
            plan_order.append(ex_id)
        ex = _ex(ex_id)
        if ex is not None:
            plan_cardio = plan_cardio or _is_cardio(ex)
            for slug, w in _muscle_weights(ex).items():
                if w > 0:
                    demand[slug] = demand.get(slug, 0.0) + w

    for r in routines:
        if not _is_ai_clone(r):
            for slot in _arr(r.get("ex")) or []:
                if isinstance(slot, dict):
                    register(slot.get("id"))
    for d in dates:
        for rid in schedule.routine_ids(state, d, today):
            for slot in _arr((by_id.get(rid) or {}).get("ex")) or []:
                if isinstance(slot, dict):
                    register(slot.get("id"))

    # 3. Up to 30 scored candidates the active gym profile can do.
    profile = _active_profile(state)
    equipment = _profile_equipment(profile) if profile is not None else None
    planned = set(plan_order)
    scored = []
    for ex in catalog["all"]:
        if ex["id"] in planned or (_is_cardio(ex) and not plan_cardio):
            continue
        if equipment is not None and not _is_available(ex, equipment):
            continue
        weights = _muscle_weights(ex)
        if not demand:
            overlap = sum(weights.values())
        else:
            primary = _primary_muscle(ex)
            overlap = demand[primary] * 2.0 if primary in demand else 0.0
            overlap += sum(w * demand[s] for s, w in weights.items() if w > 0 and s in demand)
        if overlap > 0:
            scored.append((round(overlap, 9), ex["id"]))
    scored.sort(key=lambda t: (-t[0], t[1]))

    exercise_aliases, alias_of_ex = [], {}

    def add_alias(ex_id: str) -> None:
        if ex_id in alias_of_ex:
            return
        alias = f"E{len(exercise_aliases) + 1}"
        ex = _ex(ex_id)
        mode_ = "reps" if ex is None else "time" if _is_hold(ex) else "cardio" if _is_cardio(ex) else "reps"
        target = (_primary_muscle(ex) or ex.get("tg")) if ex is not None else None
        exercise_aliases.append(_drop_none({
            "alias": alias, "id": ex_id, "name": _display_name(ex_id, state, lang),
            "target": target if isinstance(target, str) else None, "equipment": _ex_eq(ex), "mode": mode_,
        }))
        alias_of_ex[ex_id] = alias

    for ex_id in plan_order:
        add_alias(ex_id)
    for _, ex_id in scored[:MAX_CANDIDATE_EXERCISES]:
        add_alias(ex_id)

    # 4. The 15-day plan.
    q = schedule.queue(state)
    queue_ids = set(q["ids"]) if q else set()
    plan = []
    for date in dates:
        ids = schedule.routine_ids(state, date, today)
        wd = schedule.weekday(date) or 0
        entry: Object = {
            "date": date,
            "weekday": _WEEKDAYS[max(0, min(6, wd))],
            "digest": day_digest(state, date, today),
            "locked": _lock_reason(state, date, today),
            "isRest": not any(_arr((by_id.get(i) or {}).get("ex")) for i in ids),
        }
        if len(ids) == 1 and ids[0] in by_id:
            r = by_id[ids[0]]
            canonical = schedule._canonical(state, ids[0])
            slots = [x for x in _arr(r.get("ex")) or [] if isinstance(x, dict)]
            entry.update({
                "isAIClone": _is_ai_clone(r),
                "isQueueSession": mode == "rotation" and canonical in queue_ids,
                "routineAlias": alias_of_routine.get(canonical),
                "routineId": canonical,
                "routineName": r.get("name") if isinstance(r.get("name"), str) else "",
                "exercises": [_slot_summary(cfg, i, alias_of_ex, state, lang) for i, cfg in enumerate(slots)],
            })
        else:
            first = schedule._canonical(state, ids[0]) if ids else None
            name = " + ".join(by_id[i]["name"] for i in ids if isinstance((by_id.get(i) or {}).get("name"), str))
            entry.update({
                "isAIClone": False, "isQueueSession": False,
                "routineAlias": alias_of_routine.get(first) if first else None,
                "routineId": first, "routineName": name or None, "exercises": [],
            })
        plan.append(_drop_none(entry))

    # 5. Rotation on-date (only when that day is unlocked, so never today on the web).
    rotation_on_date = rotation_note = None
    if mode == "rotation":
        rotation_note = _ROTATION_NOTE
        if q and schedule.queue_remaining(state):
            on = today if today > q["startsOn"] else q["startsOn"]
            day = next((p for p in plan if p["date"] == on), None)
            if day and "locked" not in day and day["isQueueSession"] and not day["isRest"]:
                rotation_on_date = on

    # 8. Recovery.
    load = compute_recovery(state, now_ms)
    recovering = sorted(
        ((slug, m) for slug, m in load["muscles"].items() if m["fatigue"] > 0.35),
        key=lambda kv: (-round(kv[1]["fatigue"], 6), kv[0]),
    )
    g = load["global"]
    recovery = _drop_none({
        "globalAcute": _round(g["acute"], 1),
        "globalChronic": _round(g["chronic"], 1),
        "globalRatio": _round(g["ratio"], 2) if g["ratio"] is not None else None,
        "recoveringMuscles": [
            {"slug": s, "fatigue": _round(m["fatigue"], 2), "hoursToRecovered": _round(m["hoursToRecovered"], 1)}
            for s, m in recovering
        ],
    })

    # ponytail: programmes (`activeProgramme`) and HealthKit readiness are phone-only; both absent.
    return _drop_none({
        "today": today,
        "timezone": timezone,
        "unit": "lb" if state.get("unit") == "lb" else "kg",
        "scheduleMode": mode,
        "allowedOps": allowed,
        "rotationOnDate": rotation_on_date,
        "rotationNote": rotation_note,
        "recentWorkouts": _recent_workouts(state, today),
        "recovery": recovery,
        "todayNutrition": _nutrition(state, today),
        "plan": plan,
        "routineAliases": routine_aliases,
        "exerciseAliases": exercise_aliases,
    })


def build_web_coach_context(state: Object | None, *, today: str, timezone: str, lang: str = "en") -> Object:
    """The Coach snapshot for the live document plus a short summary for the dashboard."""
    check_today(today, timezone)
    if state is None:
        raise AIBadRequestError("No synced training data yet.", code="no-data")
    snapshot = _build_snapshot(state, today, timezone if isinstance(timezone, str) else "UTC", lang, time.time() * 1000)
    next7 = [
        _drop_none({
            "date": p["date"],
            "weekday": p["weekday"],
            "routineName": p.get("routineName"),
            "isRest": p["isRest"],
            "isAIClone": bool(p.get("isAIClone")),
            "locked": p.get("locked"),
        })
        for p in snapshot["plan"][:7]
    ]
    return {
        "context": snapshot,
        "summary": {
            "today": today,
            "scheduleMode": snapshot["scheduleMode"],
            "recentWorkoutsCount": len(snapshot["recentWorkouts"]),
            "topFatigued": snapshot["recovery"]["recoveringMuscles"][:5],
            "todayNutrition": snapshot["todayNutrition"],
            "plannedNext7d": next7,
            "todayLockedReason": "active",
        },
    }


# MARK: - Preview (CoachOps.preview: simulate, minimal Clone-and-Pin compile, verify)

def _validate_ops(ops: Any, snapshot: Object) -> list[Object]:
    if not isinstance(ops, list):
        raise AIBadRequestError("ops must be an array.", code="invalid_schema")
    errors = ai.validate_coach_ops_schema(ops)
    if errors:
        raise AIBadRequestError(f"Invalid coach ops: {errors[0]}", code="invalid_schema")
    ops = ai.normalize_coach_op_integers(ops)
    semantic_ctx, _, _ = ai.extract_semantic_context(snapshot)
    ok, code, detail = ai.validate_coach_ops_semantic(ops, semantic_ctx)
    if not ok:
        raise AIBadRequestError(detail or "Coach ops are not valid for this plan.", code=code or "invalid_schema")
    return ops


def _touched(op: Object) -> list[str]:
    return [op["from"], op["to"]] if op["type"] == "move_day" else [op["date"]]


def _sets_of(slot: Object) -> int:
    v = slot.get("sets")
    return max(1, int(_round(v if _is_num(v) else 3)))


def _reps_of(slot: Object) -> int | None:
    v = slot.get("reps")
    return int(_round(v)) if _is_num(v) else None


def _sim_day(state: Object, date: str, today: str, by_id: dict[str, Object]) -> Object:
    ids = schedule.routine_ids(state, date, today)
    if len(ids) == 1 and ids[0] in by_id:
        r = by_id[ids[0]]
        ex = _functional_ex(r)
        base = {"canonicalId": schedule._canonical(state, ids[0]), "isClone": _is_ai_clone(r), "ex": ex, "isRest": not ex}
    else:
        base = {"canonicalId": None, "isClone": False, "ex": [], "isRest": True}
    return {**base, "initial": copy.deepcopy(base), "slotChanges": [], "reasons": []}


def _carry(day: Object, src: Object) -> None:
    for k in ("canonicalId", "isClone", "ex", "isRest"):
        day[k] = src[k]


def _clear(day: Object) -> None:
    day.update(canonicalId=None, isClone=False, ex=[], isRest=True)


def _resolve_state(s: Object, date: str, today: str) -> tuple[list[str], list[str], list[list[Object]]]:
    ids = schedule.routine_ids(s, date, today)
    by_id = _routines_by_id(s)
    return ids, [schedule._canonical(s, i) for i in ids], [_functional_ex(by_id.get(i)) for i in ids]


def _with_plan(state: Object, compiled: Object, clones: dict[str, Object]) -> Object:
    out = dict(state)
    out["dayPlan"] = {**(_obj(state.get("dayPlan")) or {}), **compiled}
    if clones:
        out["routines"] = list(_arr(state.get("routines")) or []) + [clones[k] for k in sorted(clones)]
    return out


def _verify_post_compile(state: Object, compiled: Object, clones: dict[str, Object], expected: dict[str, Object], today: str) -> None:
    after_root = _with_plan(state, compiled, clones)
    bad = []
    for d in _window(today):
        ids, canon, exs = _resolve_state(after_root, d, today)
        want = expected.get(d)
        if want is not None:
            if want["isRest"]:
                if any(exs):
                    bad.append(d)
            elif not (len(canon) == 1 and canon[0] == want["canonicalId"] and len(exs) == 1 and _eq(exs[0], want["ex"])):
                bad.append(d)
        else:
            b_ids, _, b_exs = _resolve_state(state, d, today)
            if ids != b_ids or not _eq(exs, b_exs):
                bad.append(d)
    if bad:
        raise AIBadRequestError(f"The change would also alter {', '.join(bad)}.", code="unexpected_side_effect")


def _day_summary(state: Object, canonical: str | None, is_rest: bool, is_clone: bool, ex: list[Object]) -> Object:
    name = (_routines_by_id(state).get(canonical) or {}).get("name") if canonical else None
    return {"isRest": is_rest, "routineId": canonical, "routineName": name if isinstance(name, str) else None,
            "isAIClone": is_clone, "exerciseCount": len(ex)}


def _new_token() -> str:
    """RoutineOps.newId: base-36 ms clock plus five random base-36 characters."""
    alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    n, digits = int(time.time() * 1000), ""
    while n:
        n, r = divmod(n, 36)
        digits = alphabet[r] + digits
    return (digits or "0") + "".join(secrets.choice(alphabet) for _ in range(5))


def preview_coach_ops(state: Object, ops: list[Object], *, snapshot: Object, today: str, lang: str = "en") -> Object:
    """Validates canonical `ops` (schema + semantics, against `snapshot`), checks every touched
    day's digest against the live `state`, simulates the window, and compiles the minimal
    `dayPlan` pins and `aiClone` routines. Raises `AIBadRequestError` for invalid ops and
    `CoachConflictError(stale-preview)` when the plan moved since `snapshot`."""
    if snapshot.get("today") != today:
        raise CoachConflictError("The day changed since this preview; ask the Coach again.", code="stale-preview")
    ops = _validate_ops(ops, snapshot)
    touched = sorted({d for op in ops for d in _touched(op)})
    snap_days = {p.get("date"): p for p in snapshot.get("plan") or [] if isinstance(p, dict)}
    expected_digests: dict[str, str] = {}
    stale = []
    for date in touched:
        if date not in snap_days:
            raise AIBadRequestError(f"{date} is outside the plan window.", code="date_out_of_window")
        expected_digests[date] = snap_days[date].get("digest")
        if day_digest(state, date, today) != expected_digests[date]:
            stale.append(date)
    if stale:
        raise CoachConflictError(f"The plan changed on {', '.join(stale)}; ask the Coach again.", code="stale-preview")

    by_id = _routines_by_id(state)
    sim = {d: _sim_day(state, d, today, by_id) for d in _window(today)}

    for op in ops:
        kind, reason = op["type"], op.get("reason")
        if kind == "move_day":
            src, dst = sim.get(op["from"]), sim.get(op["to"])
            if src is None or dst is None:
                continue
            moved, prev_dst = copy.deepcopy(src), copy.deepcopy(dst)
            _carry(dst, moved)
            if reason:
                dst["reasons"].append(reason)
            if op["collision"] == "swap":
                _carry(src, prev_dst)
            else:
                _clear(src)
            if reason:
                src["reasons"].append(reason)
            continue
        day = sim.get(op["date"])
        if day is None:
            continue
        if kind == "skip":
            _clear(day)
        elif kind == "swap_exercise":
            idx = op["slotIndex"]
            if idx >= len(day["ex"]):
                continue
            old = day["ex"][idx]
            new = {**_picked_config(op["toExerciseId"]), "id": op["toExerciseId"]}
            sets = op.get("sets") if op.get("sets") is not None else _sets_of(old)
            new["sets"] = sets
            reps = None
            if _slot_mode(new) == "reps":
                if op.get("reps") is not None:
                    new["reps"] = reps = op["reps"]
                elif _slot_mode(old) == "reps" and _is_num(old.get("reps")):
                    new["reps"] = old["reps"]
                    reps = int(_round(old["reps"]))
                else:
                    reps = _reps_of(new)
            else:
                new.pop("reps", None)
            # Carry mode-agnostic superset and per-slot rest metadata.
            for k in ("sg", "sgName", "sgRest", "rest", "restSec"):
                if old.get(k) is not None:
                    new[k] = old[k]
            ex = list(day["ex"])
            ex[idx] = new
            _cleanup_supersets(ex)
            day["ex"] = [_strip_meta(x) for x in ex if isinstance(x, dict)]
            day["slotChanges"].append({
                "kind": "swapped", "slotIndex": idx,
                "fromExerciseId": op["fromExerciseId"], "fromName": _display_name(op["fromExerciseId"], state, lang),
                "toExerciseId": op["toExerciseId"], "toName": _display_name(op["toExerciseId"], state, lang),
                "sets": sets, "reps": reps,
            })
        elif kind == "set_sets":
            idx = op["slotIndex"]
            if idx >= len(day["ex"]):
                continue
            slot = dict(day["ex"][idx])
            before_sets, before_reps = _sets_of(slot), _reps_of(slot)
            slot["sets"] = op["sets"]
            if op.get("reps") is not None:
                slot["reps"] = op["reps"]
            day["ex"][idx] = _strip_meta(slot)
            day["slotChanges"].append({
                "kind": "setsChanged", "slotIndex": idx, "exerciseId": op["exerciseId"],
                "name": _display_name(op["exerciseId"], state, lang),
                "beforeSets": before_sets, "afterSets": op["sets"], "beforeReps": before_reps, "afterReps": _reps_of(slot),
            })
        elif kind == "add":
            new = {**_picked_config(op["exerciseId"]), "id": op["exerciseId"], "sets": op["sets"]}
            if _slot_mode(new) == "reps":
                if op.get("reps") is not None:
                    new["reps"] = op["reps"]
                reps = _reps_of(new)
            else:
                new.pop("reps", None)
                reps = None
            at = op.get("slotIndex") if op.get("slotIndex") is not None else len(day["ex"])
            ex = list(day["ex"])
            ex.insert(at, new)
            _cleanup_supersets(ex)
            day["ex"] = [_strip_meta(x) for x in ex if isinstance(x, dict)]
            day["slotChanges"].append({
                "kind": "added", "slotIndex": at, "exerciseId": op["exerciseId"],
                "name": _display_name(op["exerciseId"], state, lang), "sets": op["sets"], "reps": reps,
            })
        if reason:
            day["reasons"].append(reason)

    # Minimal Clone-and-Pin: only days whose final state differs get a write.
    existing = set(by_id)
    compiled: Object = {}
    clones: dict[str, Object] = {}
    expected_final: dict[str, Object] = {}
    day_diffs = []
    for date in touched:
        day = sim[date]
        init = day["initial"]
        if day["isRest"] == init["isRest"] and day["canonicalId"] == init["canonicalId"] and _eq(day["ex"], init["ex"]):
            continue
        canonical = day["canonicalId"]
        if day["isRest"] or canonical is None:
            compiled[date] = schedule.REST
            after_clone = False
        elif canonical in by_id:
            parent = by_id[canonical]
            if _eq(day["ex"], _functional_ex(parent)):
                compiled[date] = canonical
                after_clone = False
            else:
                cid = f"ai-{date}-{_new_token()}"
                while cid in existing:
                    cid = f"ai-{date}-{_new_token()}"
                existing.add(cid)
                clones[cid] = {
                    **_strip_meta(parent), "id": cid, "name": parent.get("name", ""), "ex": copy.deepcopy(day["ex"]),
                    "aiClone": True, "cloneOf": canonical, "ephemeralDate": date,
                }
                compiled[date] = cid
                after_clone = True
        else:
            continue
        expected_final[date] = {"isRest": day["isRest"], "canonicalId": canonical, "ex": day["ex"]}
        day_diffs.append({
            "date": date,
            "before": _day_summary(state, init["canonicalId"], init["isRest"], init["isClone"], init["ex"]),
            "after": _day_summary(state, canonical, day["isRest"], after_clone, day["ex"]),
            "slotChanges": day["slotChanges"],
            "reasons": day["reasons"],
            # ponytail: programme-week shifts are not ported (Programmes); always False on the web.
            "programmeWeekChanged": False,
        })

    if compiled:
        _verify_post_compile(state, compiled, clones, expected_final, today)
    return {
        "hasChanges": bool(compiled),
        "touchedDates": sorted(compiled),
        "expectedDigests": {d: v for d, v in expected_digests.items() if d in compiled},
        "dayDiffs": day_diffs,
        "compiledDayPlan": compiled,
        "createdClones": clones,
    }


# MARK: - Propose / Apply / Undo

async def propose_coach_change(ai_service: ai.AIService, store, *, message: str, today: str, timezone: str, lang: str = "en") -> Object:
    """One web Coach turn: live context -> `AIService.coach` (token `web`, endpoint `web-coach`)
    -> server-side preview of the returned canonical ops (C1)."""
    rev, state = store.current()
    built = build_web_coach_context(state, today=today, timezone=timezone, lang=lang)
    snapshot = built["context"]
    reply = await ai_service.coach(
        {"message": message, "lang": lang, "context": snapshot}, token_key="web", endpoint="web-coach"
    )
    changes = reply.get("changes") or []
    note = reply.get("note")
    preview = {"hasChanges": False, "touchedDates": [], "expectedDigests": {}, "dayDiffs": []}
    if changes:
        try:
            preview = preview_coach_ops(state, changes, snapshot=snapshot, today=today, lang=lang)
        except AIBadRequestError:
            changes, note = [], ai.COACH_NO_VALID_CHANGE_NOTE
    return {
        "answer": reply.get("answer"),
        "note": note,
        "changes": changes,
        "dayDiffs": preview["dayDiffs"],
        "touchedDates": preview["touchedDates"],
        "expectedDigests": preview["expectedDigests"],
        "hasChanges": preview["hasChanges"],
        "baseRev": rev,
        "baseWid": state.get("_wid"),
        "summary": built["summary"],
    }


def _put(store, nxt: Object, rev: int, wid: Any) -> Object:
    try:
        return store.put(nxt, base_rev=rev, base_wid=wid)
    except Conflict as exc:
        raise CoachConflictError("Your plan changed on another device; review it and try again.", code="conflict") from exc


def apply_coach_preview(
    store,
    backup,
    folder: Path,
    *,
    ops: list[Object],
    base_rev: int,
    base_wid: str | None,
    expected_digests: dict[str, str],
    today: str,
    timezone: str,
    lang: str = "en",
) -> Object:
    """Re-validates `ops` against the live document, writes the compiled plan through the
    optimistic lock, and records `<data_dir>/ai-undo.json` (never inside the document)."""
    check_today(today, timezone)
    rev, state = store.current()
    if state is None:
        raise AIBadRequestError("No synced training data yet.", code="no-data")
    if rev != base_rev or (base_wid is not None and state.get("_wid") != base_wid):
        raise CoachConflictError("Your plan changed since this preview; ask the Coach again.", code="stale-preview")
    if not isinstance(expected_digests, dict):
        raise AIBadRequestError("expectedDigests must be an object.")
    snapshot = _build_snapshot(state, today, timezone, lang, time.time() * 1000)
    for date, digest in expected_digests.items():
        if not isinstance(date, str) or day_digest(state, date, today) != digest:
            raise CoachConflictError("Your plan changed since this preview; ask the Coach again.", code="stale-preview")
    preview = preview_coach_ops(state, ops, snapshot=snapshot, today=today, lang=lang)
    if preview["expectedDigests"] != expected_digests:
        raise CoachConflictError("This preview no longer matches the plan; ask the Coach again.", code="stale-preview")
    if not preview["hasChanges"]:
        return {"ok": True, "rev": rev, "wid": state.get("_wid"), "dayDiffs": [], "undo": None}

    nxt = copy.deepcopy(state)
    plan = dict(_obj(nxt.get("dayPlan")) or {})
    day_plan_diffs = {}
    for date in preview["touchedDates"]:
        day_plan_diffs[date] = {"before": plan.get(date), "after": preview["compiledDayPlan"][date]}
        plan[date] = preview["compiledDayPlan"][date]
    nxt["dayPlan"] = plan
    clones = preview["createdClones"]
    if clones:
        nxt["routines"] = list(_arr(nxt.get("routines")) or []) + [copy.deepcopy(clones[k]) for k in sorted(clones)]
    wall_ms = time.time() * 1000
    nxt["_ts"] = stamp_change(state, nxt, wall_ms)
    saved = _put(store, nxt, rev, state.get("_wid"))
    if backup is not None:
        backup.soon()

    record = {
        "tokenId": secrets.token_hex(16),
        "acceptedAt": _out(wall_ms // 1),
        "acceptedDay": today,
        "dayPlanDiffs": day_plan_diffs,
        "createdClones": {k: _strip_meta(v) for k, v in clones.items()},
    }
    try:
        atomic_write_secret_json(Path(folder) / UNDO_FILE, record)
        undo = _undo_summary(record, "available")
    except OSError:
        undo = None  # the change is saved; only the one-tap undo is lost
    return {"ok": True, "rev": saved["_rev"], "wid": saved["_wid"], "dayDiffs": preview["dayDiffs"], "undo": undo}


def _load_undo(folder: Path) -> Object | None:
    rec = read_capped_json(Path(folder) / UNDO_FILE)
    if (not rec or not isinstance(rec.get("tokenId"), str) or not isinstance(rec.get("acceptedDay"), str)
            or not isinstance(rec.get("dayPlanDiffs"), dict) or not isinstance(rec.get("createdClones"), dict)):
        return None
    return rec


def _undo_status(rec: Object, state: Object | None, today: str) -> str:
    """AIUndo.status, plus R3: today is treated as active on the web."""
    if today > rec["acceptedDay"]:
        return "expired"
    touched = set(rec["dayPlanDiffs"])
    if today in touched or (state is not None and _active_day(state) in touched):
        return "blockedByActive"
    if state is not None and any(isinstance(w, dict) and w.get("d") in touched for w in _arr(state.get("workouts")) or []):
        return "blockedByLoggedWorkout"
    return "available"


def _undo_summary(rec: Object, status: str) -> Object:
    return {
        "tokenId": rec["tokenId"],
        "acceptedAt": rec.get("acceptedAt"),
        "acceptedDay": rec["acceptedDay"],
        "touchedDates": sorted(rec["dayPlanDiffs"]),
        "createdCloneIds": sorted(rec["createdClones"]),
        "status": status,
    }


def get_undo_status(store, folder: Path, *, today: str) -> Object | None:
    """The last applied web Coach batch and whether it can be undone, `None` when absent or expired."""
    rec = _load_undo(folder)
    if rec is None:
        return None
    _, state = store.current()
    status = _undo_status(rec, state, today)
    return None if status == "expired" else _undo_summary(rec, status)


def _referenced_routine_ids(s: Object) -> set[str]:
    """RoutineOps.referencedRoutineIds: every schedule pointer and the active session."""
    ids = set()
    for v in (_obj(s.get("dayPlan")) or {}).values():
        if isinstance(v, str) and v and v != schedule.REST:
            ids.add(v)
    for v in (_obj(s.get("week")) or {}).values():
        if isinstance(v, str) and v:
            ids.add(v)
        ids.update(i for i in _strings(v) if i)
    ids.update(i for i in _strings((_obj(s.get("rotation")) or {}).get("sequence")) if i and i != schedule.REST)
    ids.update(i for i in _strings((_obj(s.get("queue")) or {}).get("ids")) if i)
    active = _obj(s.get("active"))
    if active is not None:
        ids.update(i for i in _strings(active.get("routineIds")) if i)
        if isinstance(active.get("routineId"), str) and active["routineId"]:
            ids.add(active["routineId"])
    return ids


def undo_coach_batch(store, backup, folder: Path, *, token_id: str, today: str, timezone: str = "UTC") -> Object:
    """AIUndo.apply against the live document: restore each `dayPlan` day still holding what the
    batch wrote, then drop each created clone that is unreferenced and unchanged."""
    check_today(today, timezone)
    rec = _load_undo(folder)
    if rec is None or rec["tokenId"] != token_id:
        raise AIError("There is no matching AI change to undo.", "undo-not-found", 404)
    rev, state = store.current()
    if state is None:
        raise AIBadRequestError("No synced training data yet.", code="no-data")
    status = _undo_status(rec, state, today)
    if status == "expired":
        raise AIBadRequestError("This AI change can only be undone on the day it was applied.", code="undo-expired")
    if status != "available":
        raise CoachConflictError(
            "Today's plan or a logged workout is part of this change; edit it on the phone instead.",
            code="undo-blocked-active" if status == "blockedByActive" else "undo-blocked-logged",
        )

    nxt = copy.deepcopy(state)
    plan = dict(_obj(nxt.get("dayPlan")) or {})
    restored, skipped = [], []
    for iso in sorted(rec["dayPlanDiffs"]):
        diff = rec["dayPlanDiffs"][iso] if isinstance(rec["dayPlanDiffs"][iso], dict) else {}
        if _eq(_g(plan, iso), diff.get("after", _MISSING)):
            if diff.get("before") is None:
                plan.pop(iso, None)
            else:
                plan[iso] = diff["before"]
            restored.append(iso)
        else:
            skipped.append(iso)
    if restored:
        nxt["dayPlan"] = plan

    referenced = _referenced_routine_ids(nxt)
    routines = list(_arr(nxt.get("routines")) or [])
    removed, kept = [], []
    for cid in sorted(rec["createdClones"]):
        idx = next((i for i, r in enumerate(routines) if isinstance(r, dict) and r.get("id") == cid), None)
        if idx is None:
            removed.append(cid)  # already gone through sync or GC: Undo stays idempotent
        elif cid not in referenced and _eq(_strip_meta(routines[idx]), _strip_meta(_obj(rec["createdClones"][cid]) or {})):
            routines.pop(idx)
            removed.append(cid)
        else:
            kept.append(cid)
    if len(routines) != len(_arr(nxt.get("routines")) or []):
        nxt["routines"] = routines

    saved_rev = rev
    if restored or len(routines) != len(_arr(state.get("routines")) or []):
        nxt["_ts"] = stamp_change(state, nxt, time.time() * 1000)
        saved_rev = _put(store, nxt, rev, state.get("_wid"))["_rev"]
        if backup is not None:
            backup.soon()
    try:
        (Path(folder) / UNDO_FILE).unlink(missing_ok=True)
    except OSError:
        pass
    return {"ok": True, "rev": saved_rev, "restoredDates": restored, "skippedDates": skipped,
            "removedCloneIds": removed, "skippedCloneIds": kept}
