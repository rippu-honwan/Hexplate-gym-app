"""What is planned for a day, how many workouts the week asks for and the week streak, by the
app's rules (HexplateCore Schedule.swift and WidgetData.streak, themselves openGym's queue.js,
week-left.js, history.js and streak.js). test_schedule.py holds this to the same golden files.
Works on the document as the phone sent it.
"""
import datetime as dt

REST = "rest"
FREEZE_EVERY, FREEZE_MAX = 4, 2
BADGES = [4, 12, 26, 52, 104]


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _strings(v):
    return [x for x in (v if isinstance(v, list) else []) if isinstance(x, str)]


def _routines(s):
    return [r for r in s.get("routines") or [] if isinstance(r, dict)]


def _workouts(s):
    return [w for w in s.get("workouts") or [] if isinstance(w, dict)]


def _has(s, rid):
    return any(r.get("id") == rid for r in _routines(s))


def _canonical(s, rid):
    """Resolves an aiClone ID to its parent routine ID only when that parent still exists and is
    not itself an aiClone (mirroring HexplateCore Schedule.canonical)."""
    rs = _routines(s)
    r = next((x for x in rs if x.get("id") == rid), None)
    if not r or r.get("aiClone") is not True:
        return rid
    parent_id = r.get("cloneOf")
    if not isinstance(parent_id, str) or not parent_id:
        return rid
    parent = next((x for x in rs if x.get("id") == parent_id), None)
    if not parent or parent.get("aiClone") is True:
        return rid
    return parent_id


def _rids(w):
    if isinstance(w.get("routineIds"), list):
        return _strings(w["routineIds"])
    r = w.get("routineId")
    return [r] if isinstance(r, str) and r else []


def _day(w):
    return w.get("d") if isinstance(w.get("d"), str) else ""


def _start(w):
    return _num(w.get("start")) or 0


def _unique(ids):
    seen = set()
    return [i for i in ids if not (i in seen or seen.add(i))]


def _iso(ms):
    return dt.datetime.fromtimestamp(ms / 1000).date().isoformat()


def weekday(iso):
    """0 = Sunday, like JavaScript's getDay; None for a string that is not a date."""
    try:
        return (dt.date.fromisoformat(iso).weekday() + 1) % 7
    except (TypeError, ValueError):
        return None


def adding(n, iso):
    return (dt.date.fromisoformat(iso) + dt.timedelta(days=n)).isoformat()


def week_start(s):
    return 0 if s.get("weekStart") == 0 else 1


def week_key(iso, ws):
    wd = weekday(iso)
    return None if wd is None else adding(-((wd - ws) % 7), iso)


# MARK: the queue (queue.js)

def queue(s):
    q = s.get("queue")
    if not isinstance(q, dict) or not isinstance(q.get("ids"), list):
        return None
    ids = [i for i in _unique(_strings(q["ids"])) if _has(s, i)]
    if not ids:
        return None
    since = _num(q.get("since"))
    starts = q.get("startsOn") if isinstance(q.get("startsOn"), str) else _iso(since or 0)
    return {"ids": ids, "since": since, "startsOn": starts, "rotationId": q.get("rotationId"), "strict": q.get("strict") is True}


def _counts(s, q, w, rid):
    if rid not in _rids(w):
        return False
    if q["since"] is not None and _start(w) >= q["since"]:
        return True
    if q["strict"] or not _day(w) >= q["startsOn"]:
        return False
    name = next((r.get("name") for r in _routines(s) if r.get("id") == rid), None)
    return isinstance(name, str) and name in (w.get("name") or "").split(" + ")


def _done(s, q, rid):
    return any(_counts(s, q, w, rid) for w in _workouts(s))


def queue_remaining(s):
    q = queue(s)
    return [i for i in q["ids"] if not _done(s, q, i)] if q else []


def queue_done(s):
    q = queue(s)
    return [i for i in q["ids"] if _done(s, q, i)] if q else []


def _pins(s, remaining, today):
    plan = s.get("dayPlan") if isinstance(s.get("dayPlan"), dict) else {}
    out = []
    for iso, v in plan.items():
        if iso >= today and isinstance(v, str):
            cid = _canonical(s, v)
            if cid in remaining:
                out.append((iso, cid))
    return sorted(out)


def _next_on(s, remaining, on, today):
    pins = _pins(s, remaining, today)
    here = next((i for iso, i in pins if iso == on), None)
    return here or next((i for i in remaining if not any(p == i for _, p in pins)), None)


def _on(q, today):
    return today if today > q["startsOn"] else q["startsOn"]


def _queue_next(s, iso, today):
    q = queue(s)
    return _next_on(s, queue_remaining(s), iso, today) if q and iso == _on(q, today) else None


def _queue_live_on(s, iso, today):
    q = queue(s)
    return bool(q) and iso == _on(q, today) and bool(queue_remaining(s))


def _pin_state(s, rid):
    q = queue(s)
    if not q or not rid:
        return None
    cid = _canonical(s, rid)
    if cid not in q["ids"]:
        return None
    return "done" if _done(s, q, cid) else "open"


def schedule_mode(s):
    return "rotation" if queue(s) or s.get("scheduleMode") == "rotation" else "week"


# MARK: what a day holds (history.js effectiveRoutineIds)

def routine_ids(s, iso, today):
    """The routines planned for `iso`: the day's override, else the queue's session in front of
    the weekday's own routines."""
    plan = s.get("dayPlan") if isinstance(s.get("dayPlan"), dict) else {}
    override = plan.get(iso) if isinstance(plan.get(iso), str) else None
    if override == REST:
        return []
    pin = _pin_state(s, override)
    if pin is None and override and _has(s, override):
        return [override]
    wd = weekday(iso)
    slot = (s.get("week") or {}).get(str(wd)) if wd is not None and isinstance(s.get("week"), dict) else None
    own = [i for i in ([slot] if isinstance(slot, str) else _strings(slot)) if _has(s, i)]
    q = override if pin == "open" else _queue_next(s, iso, today)
    queued = _strings((s.get("queue") or {}).get("ids") if isinstance(s.get("queue"), dict) else None)
    if q is not None or _queue_live_on(s, iso, today):
        own = [i for i in own if i not in queued]
    return [q] + own if q is not None else own


# MARK: the week (queue.js weekTally, week-left.js)

def week_tally(s, today):
    ws = week_start(s)
    week = week_key(today, ws)
    all_ = _workouts(s)
    this = [i for i, w in enumerate(all_) if week_key(_day(w), ws) == week]
    q = queue(s)
    q = q if q and today >= q["startsOn"] else None
    queued = set(_strings(s["queue"].get("ids")) if q else [])

    def own(v):
        return [i for i in ([v] if isinstance(v, str) else _strings(v)) if _has(s, i) and i not in queued]
    own_days = sum(1 for v in (s.get("week") or {}).values() if own(v)) if isinstance(s.get("week"), dict) else 0
    if not q:
        return {"done": len(this), "planned": own_days}
    chrono = sorted(range(len(all_)), key=lambda i: (_day(all_[i]), _num(all_[i].get("start")) or 0, i))
    credited = {next((i for i in chrono if _counts(s, q, all_[i], rid)), None) for rid in q["ids"]} - {None}
    other = sum(1 for i in this if i not in credited or any(r not in queued for r in _rids(all_[i])))
    return {"done": len(queue_done(s)) + other, "planned": len(q["ids"]) + own_days}


def workouts_left(s, today):
    """{left, of, done} for "2 of 4 left this week", None when there is nothing to count against."""
    q = queue(s)
    rot = s.get("rotation") if isinstance(s.get("rotation"), dict) else None
    managed = q is not None and rot is not None and q["rotationId"] == rot.get("id")
    if schedule_mode(s) == "rotation" and (managed or q is None):
        n = int((_num(s.get("weekTarget")) or 0) + 0.5)
        if not 1 <= n <= 7:
            return None
        ws = week_start(s)
        done = sum(1 for w in _workouts(s) if week_key(_day(w), ws) == week_key(today, ws))
        return {"left": max(0, n - done), "of": n, "done": done}
    t = week_tally(s, today)
    if t["planned"] <= 0:
        return None
    return {"left": max(0, t["planned"] - t["done"]), "of": t["planned"], "done": t["done"]}


# MARK: streak (streak.js streakInfo)

def streak(s, today):
    """Weeks in a row with a workout; every fourth week earns a freeze (at most two) that covers a missed one."""
    ws = week_start(s)
    cur = week_key(today, ws)
    empty = {"current": 0, "best": 0, "freezes": 0, "weekDone": False, "next": BADGES[0]}
    if cur is None:
        return empty
    trained = set()
    for w in _workouts(s):
        d = _day(w)
        try:
            ok = dt.date.fromisoformat(d).isoformat() == d
        except ValueError:
            ok = False
        k = week_key(d, ws) if ok else None
        if k and k <= cur:
            trained.add(k)
    if not trained:
        return empty
    wk = max(min(trained), adding(-7 * 1500, cur))
    run = best = freezes = earned = 0
    while wk <= cur:
        if wk in trained:
            run += 1
            earned += 1
            if earned % FREEZE_EVERY == 0 and freezes < FREEZE_MAX:
                freezes += 1
        elif wk != cur:
            if freezes > 0:
                freezes -= 1
            else:
                run = earned = freezes = 0
        best = max(best, run)
        wk = adding(7, wk)
    return {"current": run, "best": best, "freezes": freezes, "weekDone": cur in trained, "next": next((b for b in BADGES if best < b), None)}
