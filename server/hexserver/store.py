"""The server's SQLite database.

Every document the phone pushes is kept whole (`documents`, one row per revision), so any earlier
copy can be taken back. The latest one is also split into tables for analysis (`workouts`, `sets`,
`bodyweight`), rebuilt on every write. Motion files live on disk; `motion_files` lists them.
"""
import hashlib
import json
import re
import secrets
import sqlite3
import time
import unicodedata
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS documents (
    rev INTEGER PRIMARY KEY, wid TEXT NOT NULL, ts REAL, received_at REAL NOT NULL, body TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS tokens (hash TEXT PRIMARY KEY, created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS pair_codes (code TEXT PRIMARY KEY, expires_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS workouts (
    id TEXT PRIMARY KEY, date TEXT, start_ms REAL, end_ms REAL, name TEXT, routine_id TEXT,
    volume REAL, body_weight REAL, session_effort REAL);
CREATE TABLE IF NOT EXISTS sets (
    workout_id TEXT, entry_idx INTEGER, set_idx INTEGER, exercise_id TEXT, weight REAL, reps REAL,
    done INTEGER, warmup INTEGER, rir REAL, hr REAL, at_ms REAL, started_at_ms REAL, checked INTEGER,
    raw TEXT, PRIMARY KEY (workout_id, entry_idx, set_idx));
CREATE TABLE IF NOT EXISTS bodyweight (date TEXT, time TEXT, weight REAL, PRIMARY KEY (date, time));
CREATE TABLE IF NOT EXISTS motion_files (
    name TEXT PRIMARY KEY, recorded_at TEXT, exercise TEXT, set_no INTEGER, kind TEXT,
    bytes INTEGER, received_at REAL NOT NULL);
"""

# Same rule as openGym's server (api/server.js MOTION_NAME): `20261118-120000_<exercise>_s<set>.csv`.
MOTION_NAME = re.compile(r"^(\d{8}-\d{6})_([A-Za-z0-9_-]{1,40})_s(\d{1,3})\.csv$")
WID_KEEP = 50          # earlier write ids a document carries (`_wids`), as openGym keeps
PAIR_SECONDS = 300


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


class Conflict(Exception):
    """A push over a document the device never saw: carries the current one."""
    def __init__(self, rev, state):
        self.rev, self.state = rev, state


class Store:
    def __init__(self, folder: Path):
        self.folder = Path(folder)
        self.motion_dir = self.folder / "motion"
        self.motion_dir.mkdir(parents=True, exist_ok=True)
        # ponytail: one connection, used from FastAPI's threadpool under SQLite's own locking;
        # a pool only if the dashboard ever makes this slow.
        self.db = sqlite3.connect(self.folder / "hexplate.sqlite3", check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)

    # MARK: pairing

    def new_pair_code(self) -> str:
        code = "".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(8))
        with self.db:
            self.db.execute("DELETE FROM pair_codes")   # one live code: the newest one on screen
            self.db.execute("INSERT INTO pair_codes VALUES (?, ?)", (code, time.time() + PAIR_SECONDS))
        return code

    def redeem(self, code: str):
        """The code's token, once; None when the code is wrong or older than five minutes."""
        # As typed on any keyboard: full-width letters (a Chinese or Japanese input method), spaces, dashes.
        code = "".join(c for c in unicodedata.normalize("NFKC", code).upper() if c.isalnum())
        with self.db:
            row = self.db.execute("SELECT expires_at FROM pair_codes WHERE code = ?", (code,)).fetchone()
            self.db.execute("DELETE FROM pair_codes WHERE code = ?", (code,))
            if not row or row[0] < time.time():
                return None
            token = secrets.token_urlsafe(32)
            self.db.execute("INSERT INTO tokens VALUES (?, ?)", (_hash(token), time.time()))
        return token

    def token_ok(self, token: str) -> bool:
        return self.db.execute("SELECT 1 FROM tokens WHERE hash = ?", (_hash(token),)).fetchone() is not None

    def tokens(self):
        """Paired phones: (hash, created_at), newest first."""
        return self.db.execute("SELECT hash, created_at FROM tokens ORDER BY created_at DESC").fetchall()

    def revoke(self, token_hash: str):
        with self.db:
            self.db.execute("DELETE FROM tokens WHERE hash = ?", (token_hash,))

    # MARK: the document

    def current(self):
        """(rev, state) of the latest document; (0, None) before the first push."""
        row = self.db.execute("SELECT rev, body FROM documents ORDER BY rev DESC LIMIT 1").fetchone()
        return (row[0], json.loads(row[1])) if row else (0, None)

    def versions(self, limit=30):
        """(rev, received_at, workouts, bytes) of the latest `limit` documents, newest first."""
        return self.db.execute("""SELECT rev, received_at, json_array_length(body, '$.workouts'), length(body)
                                  FROM documents ORDER BY rev DESC LIMIT ?""", (limit,)).fetchall()

    def document(self, rev: int):
        row = self.db.execute("SELECT body FROM documents WHERE rev = ?", (rev,)).fetchone()
        return json.loads(row[0]) if row else None

    def restore(self, rev: int):
        """An earlier document stored again as the newest revision (nothing is deleted). The phone
        takes it on its next sync, and merges in anything it changed meanwhile."""
        old = self.document(rev)
        return self.put(old) if old else None

    def put(self, state: dict, base_rev=None, base_wid=None):
        """Stores `state` as the next revision. A `base_rev` (and `base_wid`) that is not the
        current document's raises Conflict, as openGym's PUT /api/data does; none overwrites."""
        with self.db:   # one transaction: the compare and the write cannot interleave
            self.db.execute("BEGIN IMMEDIATE")
            rev, cur = self.current()
            wid = cur.get("_wid") if cur else None
            if base_rev is not None and (base_rev != rev or (isinstance(base_wid, str) and wid and base_wid != wid)):
                raise Conflict(rev, cur)
            state.pop("active", None)   # the running workout stays on the phone
            wids = [x for x in (cur or {}).get("_wids", []) if isinstance(x, str)] + ([wid] if wid else [])
            state["_wids"] = wids[-WID_KEEP:]
            state["_wid"] = secrets.token_hex(8)
            state["_rev"] = rev + 1
            self.db.execute("INSERT INTO documents VALUES (?, ?, ?, ?, ?)",
                            (rev + 1, state["_wid"], _num(state.get("_ts")), time.time(), json.dumps(state)))
            self._split(state)
        return state

    def _split(self, s: dict):
        """The analysis tables, rebuilt from the latest document."""
        for t in ("workouts", "sets", "bodyweight"):
            self.db.execute(f"DELETE FROM {t}")
        for w in s.get("workouts") or []:
            if not isinstance(w, dict) or w.get("id") is None:
                continue
            wid = str(w["id"])
            self.db.execute("INSERT OR REPLACE INTO workouts VALUES (?,?,?,?,?,?,?,?,?)", (
                wid, w.get("d"), _num(w.get("start")), _num(w.get("end")), w.get("name"), w.get("routineId"),
                _num(w.get("vol")), _num(w.get("bw")), _num(w.get("sessionEffort"))))
            for i, e in enumerate(w.get("entries") or []):
                for j, x in enumerate((e or {}).get("sets") or []):
                    if not isinstance(x, dict):
                        continue
                    self.db.execute("INSERT OR REPLACE INTO sets VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                        wid, i, j, str(e.get("id")), _num(x.get("w")), _num(x.get("r")), int(bool(x.get("done"))),
                        int(x.get("phase") == "warmup" or x.get("type") == "warmup"), _num(x.get("rir")),
                        _num(x.get("hr")), _num(x.get("at")), _num(x.get("startedAt")), int(bool(x.get("checked"))),
                        json.dumps(x)))
        for b in s.get("bodyweight") or []:
            if isinstance(b, dict) and b.get("d"):
                self.db.execute("INSERT OR REPLACE INTO bodyweight VALUES (?,?,?)", (b["d"], b.get("t") or "", _num(b.get("w"))))

    # MARK: motion

    def motion_meta(self):
        """Each set file's JSON header, newest first: the watch's own count `auto`, the final `reps`,
        `checked`, `exId`, `w`, `end`. Set files carry no `kind`; the heart-rate, sync and watch logs
        do. ponytail: reads every file's first line per call; store the header in motion_files if
        the folder grows into the thousands."""
        out = []
        for (name,) in self.db.execute("SELECT name FROM motion_files WHERE kind IS NULL ORDER BY recorded_at DESC"):
            try:
                with open(self.motion_dir / name) as f:
                    meta = json.loads(f.readline()[2:])
            except (OSError, ValueError):
                continue
            out.append({**meta, "file": name})
        return out

    def save_motion(self, name: str, csv: str, received_at: float | None = None) -> bool:
        m = MOTION_NAME.match(name)
        if not m or not csv.startswith("# {"):
            return False
        path = self.motion_dir / name
        tmp = path.with_suffix(".part")
        tmp.write_text(csv)
        tmp.replace(path)   # a crash never leaves half a file under the real name
        try:
            kind = json.loads(csv.split("\n", 1)[0][2:]).get("kind")
        except ValueError:
            kind = None
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO motion_files VALUES (?,?,?,?,?,?,?)",
                            (name, m.group(1), m.group(2), int(m.group(3)), kind, len(csv.encode()), received_at or time.time()))
        return True
