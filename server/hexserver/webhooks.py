"""Webhooks: a signed JSON POST to a URL of your choosing when a workout is finished, sets
records, or you weigh in, so Home Assistant, n8n, Node-RED or ntfy can act on it.

A port of openGym's api/integrations (events.js, providers/webhook.js, crypto.js signature): the
events come from comparing the document before and after the phone's PUT /api/data, the only
moment the server sees a workout finish. Payloads are openGym's (docs/INTEGRATIONS.md there).

Signature: `X-Hexplate-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<body>">`, keyed
with the webhook's secret. Check it, and that t is recent, before trusting a message.

The URLs are set on the dashboard, which only this Mac can open, so plain http to a box on the
home network is allowed. Redirects are not followed; each try gives up after 10 seconds.
ponytail: retries live in a thread (three tries over about a minute); a delivery still waiting
when the server stops is lost. A durable outbox if that ever matters.
"""
import datetime as dt
import hashlib
import hmac
import json
import math
import secrets
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from .queries import catalogue_names

EVENTS = ["workout.finished", "workout.pr", "weighin.logged"]
EVENT_LABELS = {"workout.finished": "Workout finished", "workout.pr": "New personal record", "weighin.logged": "Weigh-in logged"}
RECENT_MS = 7 * 86400_000
MAX_PER_WRITE = 10
PAYLOAD_VERSION = 1
MAX_WEBHOOKS = 10
TIMEOUT = 10
RETRY_AFTER = (10, 60)
MAX_EXERCISES, MAX_SETS, NAME_MAX, NOTE_MAX = 60, 50, 80, 500

SCHEMA = """CREATE TABLE IF NOT EXISTS webhooks (
    id TEXT PRIMARY KEY, label TEXT, url TEXT NOT NULL, secret TEXT NOT NULL, events TEXT NOT NULL,
    paused INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, last_at REAL, last_ok INTEGER, last_msg TEXT);"""


# MARK: what happened (events.js)

def _list(v):
    return [x for x in v if isinstance(x, dict)] if isinstance(v, list) else []


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else None


def _text(v, n):
    return v[:n] if isinstance(v, str) else None


def _day_ms(d):
    if not isinstance(d, str) or len(d) < 10:
        return None
    try:
        return dt.datetime.fromisoformat(d[:10] + "T12:00:00+00:00").timestamp() * 1000
    except ValueError:
        return None


def _js_round1(x):
    return math.floor(x * 10 + 0.5) / 10


def _iso(ms):
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _js_id(v):
    """String(v) as JavaScript writes it: 7, not 7.0."""
    return str(int(v)) if isinstance(v, float) and v.is_integer() else str(v)


def workout_time(w):
    return _num(w.get("end")) or _num(w.get("start")) or _day_ms(w.get("d")) or 0


def detect_events(prev, nxt, now_ms):
    """[{type, entity, at, data}] for what is new in `nxt`, oldest first, at most MAX_PER_WRITE.
    Only what is recent counts: a restored backup or a first sync is not news."""
    out = []
    before = {_js_id(w.get("id")) for w in _list((prev or {}).get("workouts"))}
    for w in _list((nxt or {}).get("workouts")):
        if w.get("id") is None or _js_id(w["id"]) in before:
            continue
        at = workout_time(w)
        if not at or now_ms - at > RECENT_MS or at - now_ms > 86400_000:
            continue
        out.append({"type": "workout.finished", "entity": _js_id(w["id"])[:80], "at": at, "data": w})
        if isinstance(w.get("prs"), list) and w["prs"]:
            out.append({"type": "workout.pr", "entity": _js_id(w["id"])[:80], "at": at, "data": w})
    old = {str(b.get("d")): _num(b.get("w")) for b in _list((prev or {}).get("bodyweight"))}
    for b in _list((nxt or {}).get("bodyweight")):
        w = _num(b.get("w"))
        if w is None or not isinstance(b.get("d"), str) or (str(b["d"]) in old and old[str(b["d"])] == w):
            continue
        at = _num(b.get("t")) or _day_ms(b["d"]) or 0
        if not at or now_ms - at > RECENT_MS or at - now_ms > 86400_000:
            continue
        out.append({"type": "weighin.logged", "entity": f"{b['d'][:10]}:{_js_num(w)}", "at": at, "data": b})
    out.sort(key=lambda e: e["at"])   # stable, like Array.sort
    return out[-MAX_PER_WRITE:]


def _js_num(v):
    return str(int(v)) if float(v).is_integer() else repr(v)


# MARK: payloads

def _exercise_name(ex_id, doc):
    own = next((c for c in _list((doc or {}).get("customEx")) if str(c.get("id")) == str(ex_id)), None)
    return _text((own or {}).get("name"), NAME_MAX) or _text(catalogue_names().get(str(ex_id)), NAME_MAX) or str(ex_id)[:NAME_MAX]


def _warmup(s):
    phase = s.get("phase")
    return phase == "warmup" if phase is not None and phase != "" else s.get("warmup") is True


def _set_out(s):
    sides = s.get("sides")
    if isinstance(sides, dict) and sides.get("L") and sides.get("R"):
        return {"sides": {"left": _set_out(sides["L"]), "right": _set_out(sides["R"])}}
    o = {}
    for key, name in (("w", "weight"), ("r", "reps"), ("sec", "seconds"), ("min", "minutes"), ("speed", "speedKmh"),
                      ("incline", "incline"), ("rpe", "rpe"), ("rir", "rir")):
        if _num(s.get(key)) is not None:
            o[name] = s[key]
    if _warmup(s):
        o["warmup"] = True
    return o


def _done(s):
    sides = s.get("sides")
    if sides:
        return (sides.get("L") or {}).get("done") is True or (sides.get("R") or {}).get("done") is True
    return s.get("done") is True


def workout_payload(w, doc):
    exercises = [{"id": str(e.get("id"))[:40], "name": _exercise_name(e.get("id"), doc),
                  "sets": [_set_out(s) for s in _list(e.get("sets")) if _done(s)][:MAX_SETS]}
                 for e in _list(w.get("entries"))[:MAX_EXERCISES]]
    sets = reps = volume = 0
    for e in exercises:
        for s in e["sets"]:
            if s.get("warmup"):
                continue
            sets += 1
            for p in ([s["sides"]["left"], s["sides"]["right"]] if "sides" in s else [s]):
                reps += p.get("reps") or 0
                volume += (p.get("weight") or 0) * (p.get("reps") or 0)
    start, end = _num(w.get("start")), _num(w.get("end"))
    out = {
        "id": _js_id(w.get("id"))[:80],
        "name": _text(w.get("name"), NAME_MAX) or None,
        "date": w["d"][:10] if isinstance(w.get("d"), str) else None,
        "startedAt": _iso(start) if start else None,
        "endedAt": _iso(end) if end else None,
        "durationMin": math.floor((end - start) / 60000 + 0.5) if start and end and end > start else None,
        "unit": "lb" if (doc or {}).get("unit") == "lb" else "kg",
        "bodyweight": _num(w.get("bw")),
        "totals": {"exercises": len(exercises), "sets": sets, "reps": reps, "volume": _js_round1(volume)},
        "exercises": exercises,
        "records": [{"id": str(i)[:40], "name": _exercise_name(i, doc)} for i in (w.get("prs") if isinstance(w.get("prs"), list) else [])[:MAX_EXERCISES]],
    }
    if _text(w.get("note"), NOTE_MAX):
        out["note"] = _text(w.get("note"), NOTE_MAX)
    return out


def _records_payload(w, doc):
    full = workout_payload(w, doc)
    records = []
    for r in full["records"]:
        ex = next((e for e in full["exercises"] if e["id"] == r["id"]), None)
        cands = [s for s in (ex or {}).get("sets", []) if not s.get("warmup") and s.get("weight") is not None]
        cands.sort(key=lambda s: (-s["weight"], -(s.get("reps") or 0)))
        records.append({**r, **({"weight": cands[0]["weight"], "reps": cands[0].get("reps")} if cands else {})})
    return {"workout": {"id": full["id"], "name": full["name"], "date": full["date"]}, "unit": full["unit"], "records": records}


def event_data(ev, doc):
    unit = "lb" if (doc or {}).get("unit") == "lb" else "kg"
    if ev["type"] == "workout.finished":
        return {"workout": workout_payload(ev["data"], doc)}
    if ev["type"] == "workout.pr":
        return _records_payload(ev["data"], doc)
    b = ev["data"]
    return {"weighin": {"date": b["d"][:10], "weight": b["w"], "unit": unit}}


def envelope(id, type, data, at_ms, test=False):
    return {"version": PAYLOAD_VERSION, "id": id, "type": type, "createdAt": _iso(at_ms), **({"test": True} if test else {}), "data": data}


def sample_data(type, now_ms):
    today = _iso(now_ms)[:10]
    if type == "weighin.logged":
        return {"weighin": {"date": today, "weight": 80, "unit": "kg"}}
    if type == "workout.pr":
        return {"workout": {"id": "test", "name": "Test workout", "date": today}, "unit": "kg",
                "records": [{"id": "0025", "name": "barbell bench press", "weight": 60, "reps": 8}]}
    return {"workout": {
        "id": "test", "name": "Test workout", "date": today, "startedAt": _iso(now_ms - 45 * 60000), "endedAt": _iso(now_ms),
        "durationMin": 45, "unit": "kg", "bodyweight": None, "totals": {"exercises": 1, "sets": 3, "reps": 24, "volume": 1440},
        "exercises": [{"id": "0025", "name": "barbell bench press", "sets": [{"weight": 60, "reps": 8}] * 3}], "records": []}}


def signature(secret, body, ts=None):
    ts = int(time.time()) if ts is None else ts
    return f"t={ts},v1=" + hmac.new(secret.encode(), f"{ts}.{body}".encode(), hashlib.sha256).hexdigest()


# MARK: sending

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def post(url, secret, env):
    """One try: (ok, retry, message)."""
    body = json.dumps(env, separators=(",", ":"), ensure_ascii=False)
    req = urllib.request.Request(url, data=body.encode(), method="POST", headers={
        "Content-Type": "application/json", "User-Agent": "Hexplate-Webhook/1",
        "X-Hexplate-Event": env["type"], "X-Hexplate-Delivery": env["id"], "X-Hexplate-Signature": signature(secret, body)})
    try:
        with _opener.open(req, timeout=TIMEOUT) as r:
            r.read(2048)
            return True, False, f"Answered {r.status}."
    except urllib.error.HTTPError as e:
        s = e.code
        if 300 <= s < 400:
            return False, False, f"Answered {s}: redirects are not followed, use the final URL."
        return False, s in (408, 425, 429) or s >= 500, f"The receiver answered {s}."
    except TimeoutError:
        return False, True, "No answer within 10 seconds."
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        if isinstance(reason, TimeoutError):
            return False, True, "No answer within 10 seconds."
        if isinstance(reason, ConnectionRefusedError):
            return False, True, "The receiver refused the connection."
        if isinstance(reason, socket.gaierror):
            return False, True, "The address could not be found."
        if "CERTIFICATE" in str(reason).upper():
            return False, False, "The receiver's HTTPS certificate is not valid."
        return False, True, str(reason)[:120]


class Webhooks:
    """The webhooks kept in the server's database, and their deliveries."""

    def __init__(self, db):
        self.db = db
        db.executescript(SCHEMA)

    def all(self):
        rows = self.db.execute("SELECT id, label, url, events, paused, created_at, last_at, last_ok, last_msg FROM webhooks ORDER BY created_at").fetchall()
        return [{"id": r[0], "label": r[1], "url": r[2], "events": json.loads(r[3]), "paused": bool(r[4]), "created_at": r[5],
                 "last_at": r[6], "last_ok": None if r[7] is None else bool(r[7]), "last_msg": r[8]} for r in rows]

    def add(self, url, label, events):
        """(id, secret) of the new webhook; ValueError with the reason when it cannot be added."""
        url = url.strip()
        if not url.lower().startswith(("https://", "http://")) or " " in url or len(url) > 2000:
            raise ValueError("The URL has to start with https:// or http://.")
        events = [e for e in EVENTS if e in events]
        if not events:
            raise ValueError("Pick at least one event.")
        if len(self.all()) >= MAX_WEBHOOKS:
            raise ValueError(f"At most {MAX_WEBHOOKS} webhooks.")
        wid, secret = uuid.uuid4().hex[:12], "whsec_" + secrets.token_urlsafe(24)
        label = label.strip()[:60] or urllib.parse.urlsplit(url).netloc
        with self.db:
            self.db.execute("INSERT INTO webhooks (id, label, url, secret, events, created_at) VALUES (?,?,?,?,?,?)",
                            (wid, label, url, secret, json.dumps(events), time.time()))
        return wid, secret

    def remove(self, wid):
        with self.db:
            self.db.execute("DELETE FROM webhooks WHERE id = ?", (wid,))

    def pause(self, wid, paused):
        with self.db:
            self.db.execute("UPDATE webhooks SET paused = ? WHERE id = ?", (int(paused), wid))

    def _settle(self, wid, ok, msg):
        with self.db:
            self.db.execute("UPDATE webhooks SET last_at = ?, last_ok = ?, last_msg = ? WHERE id = ?", (time.time(), int(ok), msg, wid))

    def _send(self, wid, url, secret, env):
        for wait in (0, *RETRY_AFTER):
            time.sleep(wait)
            ok, retry, msg = post(url, secret, env)
            self._settle(wid, ok, msg)
            if ok or not retry:
                return ok

    def _targets(self, wid=None):
        q = "SELECT id, url, secret, events, created_at FROM webhooks WHERE paused = 0" + (" AND id = ?" if wid else "")
        return self.db.execute(q, (wid,) if wid else ()).fetchall()

    def dispatch(self, prev, nxt, now_ms=None):
        """Sends what is new in `nxt` to each webhook that wants it, in the background."""
        now_ms = now_ms or time.time() * 1000
        events = detect_events(prev, nxt, now_ms)
        if not events:
            return []
        jobs = []
        for wid, url, secret, wanted, created in self._targets():
            for ev in events:
                if ev["type"] in json.loads(wanted) and ev["at"] >= created * 1000:
                    jobs.append((wid, url, secret, envelope(uuid.uuid4().hex, ev["type"], event_data(ev, nxt), now_ms)))
        if jobs:
            threading.Thread(target=lambda: [self._send(*j) for j in jobs], daemon=True).start()
        return jobs

    def send_test(self, wid, type="workout.finished"):
        """One test delivery, right away (the dashboard waits for it): (ok, message)."""
        row = self.db.execute("SELECT url, secret FROM webhooks WHERE id = ?", (wid,)).fetchone()
        if not row:
            return False, "No such webhook."
        now = time.time() * 1000
        ok, _, msg = post(row[0], row[1], envelope(uuid.uuid4().hex, type, sample_data(type, now), now, test=True))
        self._settle(wid, ok, msg)
        return ok, msg

