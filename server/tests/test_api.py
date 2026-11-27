import json
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from hexserver.app import create_app

FIXTURE = Path(__file__).resolve().parents[2] / "app/HexplateCore/Tests/HexplateCoreTests/Fixtures/history-state.json"


def state():
    return json.loads(FIXTURE.read_text())


def test_pair_code_works_once_and_expires(client):
    store = client.app.state.store
    code = store.new_pair_code()
    assert client.post("/api/pair/redeem", json={"code": code}).status_code == 200
    assert client.post("/api/pair/redeem", json={"code": code}).json()["code"] == "pair-invalid"
    code = store.new_pair_code()
    store.db.execute("UPDATE pair_codes SET expires_at = ?", (time.time() - 1,))
    assert client.post("/api/pair/redeem", json={"code": code}).status_code == 400


def test_everything_needs_the_token(client):
    for method, path in [("get", "/api/me"), ("get", "/api/data"), ("get", "/api/data/rev"), ("put", "/api/data"), ("put", "/api/motion")]:
        assert getattr(client, method)(path, headers={"Authorization": "Bearer nope"}).status_code == 401


def test_push_pull_and_conflict(phone):
    assert phone.get("/api/data").json() == {"state": None, "rev": 0}
    s = state()
    s["active"] = {"entries": []}
    r = phone.put("/api/data", json={"state": s, "stamped": True, "baseRev": 0}).json()
    assert r["rev"] == 1
    got = phone.get("/api/data").json()
    assert got["rev"] == 1 and "active" not in got["state"] and got["state"]["_wid"] == r["wid"]
    assert phone.get("/api/data/rev").json() == {"rev": 1, "wid": r["wid"]}

    # A device that last read rev 0 is refused, and gets the current document to merge.
    c = phone.put("/api/data", json={"state": state(), "baseRev": 0})
    assert c.status_code == 409 and c.json()["rev"] == 1 and c.json()["state"]["_wid"] == r["wid"]
    # Same number, different document (the server went back in time): refused too.
    assert phone.put("/api/data", json={"state": state(), "baseRev": 1, "baseWid": "other"}).status_code == 409

    r2 = phone.put("/api/data", json={"state": state(), "baseRev": 1, "baseWid": r["wid"]}).json()
    doc = phone.get("/api/data").json()["state"]
    assert r2["rev"] == 2 and doc["_wids"] == [r["wid"]]


def test_refuses_what_openGym_refuses(phone):
    for b in [{}, {"state": {}}, {"state": {"_rev": 3}}, {"state": {"workouts": {}}}, {"state": []}]:
        assert phone.put("/api/data", json=b).status_code == 400


def test_tables_follow_the_latest_document(phone):
    s = state()
    phone.put("/api/data", json={"state": s})
    db = phone.app.state.store.db
    n = lambda t: db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
    sets = sum(len(e.get("sets", [])) for w in s["workouts"] for e in w.get("entries", []))
    assert (n("workouts"), n("sets"), n("bodyweight")) == (len(s["workouts"]), sets, len(s["bodyweight"]))
    assert db.execute("SELECT warmup FROM sets WHERE workout_id = 'wA' AND entry_idx = 0 AND set_idx = 0").fetchone()[0] == 1
    s["workouts"] = s["workouts"][:1]
    phone.put("/api/data", json={"state": s})
    assert n("workouts") == 1 and n("documents") == 2   # every version kept


def test_motion_files(phone, tmp_path):
    csv = '# {"kind":"set","v":1}\nt,ax\n0,1\n'
    assert phone.put("/api/motion", json={"name": "20261118-120000_0025_s1.csv", "csv": csv}).json() == {"ok": True, "canDelete": True}
    assert (tmp_path / "motion/20261118-120000_0025_s1.csv").read_text() == csv
    assert (tmp_path / "backup/motion/20261118-120000_0025_s1.csv").read_text() == csv   # backed up before the answer
    row = phone.app.state.store.db.execute("SELECT recorded_at, exercise, set_no, kind FROM motion_files").fetchone()
    assert row == ("20261118-120000", "0025", 1, "set")
    for name, body in [("../x.csv", csv), ("20261118-120000_0025_s1.txt", csv), ("20261118-120000_0025_s1.csv", "t,ax\n")]:
        assert phone.put("/api/motion", json={"name": name, "csv": body}).status_code == 400


def test_import_command(tmp_path, monkeypatch, capsys):
    from hexserver.__main__ import main
    data, motion = tmp_path / "data", tmp_path / "old-motion"
    motion.mkdir()
    (motion / "20261118-120000_0025_s1.csv").write_text('# {"kind":"set"}\nt\n')
    (motion / "notes.csv").write_text("not a motion file")
    monkeypatch.setenv("HEXPLATE_DATA", str(data))
    monkeypatch.setattr("sys.argv", ["hexserver", "import", str(FIXTURE), str(motion)])
    main()
    assert "rev 1, 4 workouts" in capsys.readouterr().out
    store = create_app(data).state.store
    assert store.current()[0] == 1 and (data / "motion/20261118-120000_0025_s1.csv").exists()
    assert store.db.execute("SELECT COUNT(*) FROM motion_files").fetchone()[0] == 1


def test_bootstrap_and_dataset_reflect_empty_and_populated_state(client):
    empty_boot = client.get("/analytics/api/bootstrap").json()
    assert empty_boot["hasData"] is False and empty_boot["hasDocument"] is False
    empty_ds = client.get("/analytics/api/dataset").json()
    assert empty_ds["hasData"] is False and empty_ds["sessions"] == []

    client.app.state.store.put(state())
    boot = client.get("/analytics/api/bootstrap").json()
    assert boot["hasData"] is True and boot["unit"] == "kg"
    ds = client.get("/analytics/api/dataset").json()
    assert ds["hasData"] is True and len(ds["sessions"]) == len(state()["workouts"])
    assert any(s["routine"] == "Upper" for s in ds["sessions"])
    assert len(ds["stats"]["weeklyVolume"]) == 16


def test_analytics_endpoints_downloads_and_data_actions(client, tmp_path):
    store = client.app.state.store
    store.put(state())
    (tmp_path / "motion").mkdir(exist_ok=True)
    head = '# {"auto":9,"reps":10,"checked":true,"exId":"0025","w":20,"end":1794984800412}\nt\n'
    store.save_motion("20261118-120000_0025_s1.csv", head)

    ds = client.get("/analytics/api/dataset").json()
    wid = state()["workouts"][0]["id"]
    ex = ds["exercises"][0]["id"]
    for path in (
        f"/analytics/api/workouts/{wid}",
        f"/analytics/api/exercises/{ex}",
        "/analytics/api/report?range=3m",
        "/analytics/api/data",
        "/analytics/api/connect",
    ):
        assert client.get(path).status_code == 200, path

    reps = ds["reps"]
    assert reps["exact"] == 0 and reps["confirmed"] == 1 and reps["mae"] == 1.0
    assert reps["latest"][0]["off"] == -1

    csv_res = client.get("/data/sets.csv")
    assert csv_res.status_code == 200 and csv_res.text.startswith("date,workout,exercise_id")
    assert csv_res.headers.get("cache-control") == "no-store"

    latest_res = client.get("/data/latest.json")
    assert latest_res.status_code == 200 and latest_res.headers.get("cache-control") == "no-store"

    rev1 = client.get("/data/rev/1.json")
    assert rev1.status_code == 200 and rev1.json()["_rev"] == 1
    assert rev1.headers.get("cache-control") == "no-store"

    missing_rev = client.get("/data/rev/999.json")
    assert missing_rev.status_code == 404 and missing_rev.headers.get("cache-control") == "no-store"

    same = {"Origin": "http://testserver", "Sec-Fetch-Site": "same-origin"}
    pair = client.post("/analytics/api/data/pair", headers=same)
    assert pair.status_code == 200 and pair.headers.get("cache-control") == "no-store"
    code = pair.json()["code"]
    assert client.post("/api/pair/redeem", json={"code": code}).status_code == 200
    (h, _), = store.tokens()

    restored = client.post("/analytics/api/data/restore", json={"rev": 1}, headers=same)
    assert restored.status_code == 200 and restored.json()["rev"] == 2
    assert store.current()[0] == 2 and store.document(2)["workouts"] == store.document(1)["workouts"]

    revoked = client.post("/analytics/api/data/revoke", json={"hash": h}, headers=same)
    assert revoked.status_code == 200 and store.tokens() == []

    # Another website open on this Mac cannot post to the dashboard.
    assert client.post("/analytics/api/data/pair", headers={"Origin": "https://evil.example"}).status_code == 403
    assert client.post("/analytics/api/data/pair", headers={"Sec-Fetch-Site": "cross-site"}).status_code == 403


def test_dashboard_is_local_only(tmp_path):
    other = TestClient(create_app(tmp_path), client=("192.168.1.20", 50000))
    assert other.get("/").status_code == 403 and other.get("/data/latest.json").status_code == 403
    assert other.get("/api/health").status_code == 200   # the phone's API stays reachable


def test_code_typed_with_another_keyboard(client):
    code = client.app.state.store.new_pair_code()
    wide = "".join(chr(ord(c) + 0xFEE0) for c in code.lower())   # full-width, as a Chinese keyboard types it
    assert client.post("/api/pair/redeem", json={"code": f" {wide[:4]}-{wide[4:]} "}).status_code == 200


def test_backup_gates_the_phones_delete(phone, tmp_path):
    csv = '# {"kind":"set","v":1}\nt,ax\n0,1\n'
    backup, store = phone.app.state.backup, phone.app.state.store
    (tmp_path / "backup").write_text("not a folder")   # the backup cannot be written
    r = phone.put("/api/motion", json={"name": "20261118-120000_0025_s2.csv", "csv": csv}).json()
    assert r == {"ok": True, "canDelete": False} and store.setting("backup_error")   # the phone keeps its copy
    store.set_setting("backup", "off")                   # switched off: the server's copy is enough
    assert phone.put("/api/motion", json={"name": "20261118-120000_0025_s3.csv", "csv": csv}).json()["canDelete"] is True
    (tmp_path / "backup").unlink()
    store.set_setting("backup", "on")
    copied, ok = backup.everything()
    assert ok and copied == 2 and store.setting("backup_error") is None
    copy, = (tmp_path / "backup").glob("hexplate-*")   # one file, no -wal or -shm beside it
    import sqlite3
    assert sqlite3.connect(f"file:{copy}?mode=ro", uri=True).execute("PRAGMA journal_mode").fetchone()[0] == "delete"
    assert backup.status()["motion"] == 2


def test_language_and_backup_settings_api(client):
    store = client.app.state.store
    store.put(state())
    same = {"Origin": "http://testserver", "Sec-Fetch-Site": "same-origin"}

    assert client.get("/analytics/api/bootstrap").json()["lang"] == "en"  # English unless chosen
    zh_browser = client.get("/analytics/api/bootstrap", headers={"Accept-Language": "zh-TW,zh"}).json()
    assert zh_browser["lang"] == "zh" and "Overview" in zh_browser["strings"]

    set_zh = client.post("/analytics/api/settings/lang", json={"lang": "zh"}, headers=same).json()
    assert set_zh["lang"] == "zh" and "Overview" in set_zh["strings"]
    assert client.get("/analytics/api/bootstrap").json()["lang"] == "zh"

    set_en = client.post("/analytics/api/settings/lang", json={"lang": "en"}, headers=same).json()
    assert set_en["lang"] == "en" and set_en["strings"] == {}
    assert client.get("/analytics/api/bootstrap").json()["lang"] == "en"

    bk = client.post("/analytics/api/settings/backup", json={"on": False}, headers=same).json()
    assert store.setting("backup") == "off" and bk["backup"]["on"] is False
    assert client.get("/analytics/api/bootstrap").json()["backup"]["on"] is False


def test_unknown_hexplate_keys_preserved_across_write_paths(phone, client, tmp_path, monkeypatch):
    """Store.put, PUT /api/data, Store.restore, and CLI import preserve unknown Hexplate keys
    (meals, nutritionGoals, hexSchema, aiClone routine metadata) as deep-equal JSON values."""
    from hexserver.__main__ import main

    s = state()
    s["hexSchema"] = 1
    s["nutritionGoals"] = {"kcal": 2400, "proteinPerKg": 2.0, "carbs": 260, "fat": 70}
    s["meals"] = {
        "m1": {
            "id": "m1", "date": "2026-11-25", "time": "12:30", "name": "Chicken Rice",
            "kcal": 620, "protein": 48, "carbs": 72, "fat": 14, "source": "manual", "_ts": 1795500001000,
        },
        "m2": {"deleted": True, "_ts": 1795500002000},
    }
    s["routines"] = list(s.get("routines") or []) + [{
        "id": "ai-2026-11-25-x", "name": "Upper", "emoji": "figureStrength",
        "ex": [{"id": "0025", "sets": 2, "reps": 8}],
        "aiClone": True, "cloneOf": s["routines"][0]["id"], "ephemeralDate": "2026-11-25",
    }]

    def strip_server_meta(doc):
        return {k: v for k, v in doc.items() if k not in ("_rev", "_wid", "_wids", "active")}

    # 1. PUT /api/data -> GET /api/data
    res = phone.put("/api/data", json={"state": {**s, "active": {"id": "live"}}, "stamped": True})
    assert res.status_code == 200
    fetched = phone.get("/api/data").json()["state"]
    assert strip_server_meta(fetched) == strip_server_meta(s)

    # 2. Store.restore preserves deep-equal JSON values across revisions
    store = phone.app.state.store
    store.put({**s, "meals": {}})
    restored = store.restore(1)
    assert strip_server_meta(restored) == strip_server_meta(s)

    # 3. CLI import preserves deep-equal JSON values
    src = tmp_path / "hexplate-state.json"
    src.write_text(json.dumps(s))
    cli_data = tmp_path / "cli-data"
    monkeypatch.setenv("HEXPLATE_DATA", str(cli_data))
    monkeypatch.setattr("sys.argv", ["hexserver", "import", str(src)])
    main()
    _, imported = create_app(cli_data).state.store.current()
    assert strip_server_meta(imported) == strip_server_meta(s)


def test_plan_page_hides_ai_clones_from_list_but_resolves_pinned_day_name(client):
    import datetime as dt

    s = state()
    today_iso = dt.date.today().isoformat()
    parent_id = s["routines"][0]["id"]
    parent_name = s["routines"][0]["name"]
    s["routines"] = list(s["routines"]) + [{
        "id": "ai-clone-today",
        "name": parent_name,
        "ex": [{"id": "0025", "sets": 2, "reps": 8}],
        "aiClone": True,
        "cloneOf": parent_id,
        "ephemeralDate": today_iso,
    }]
    s["dayPlan"] = {today_iso: "ai-clone-today"}
    client.app.state.store.put(s)

    plan = client.get(f"/analytics/api/dataset?today={today_iso}").json()["plan"]
    # Routine list excludes the ephemeral aiClone.
    assert len(plan["routines"]) == len(state()["routines"])
    assert all(r["id"] != "ai-clone-today" for r in plan["routines"])
    # Pinned day still displays the routine's name on the weekly schedule.
    today_entry = next(d for d in plan["weekDays"] if d["date"] == today_iso)
    assert parent_name in today_entry["routineNames"] and today_entry["isAIClone"] is True
