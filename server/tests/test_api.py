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
    assert phone.put("/api/motion", json={"name": "20261118-120000_0025_s1.csv", "csv": csv}).json() == {"ok": True}
    assert (tmp_path / "motion/20261118-120000_0025_s1.csv").read_text() == csv
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


def test_overview_page(client):
    assert "No workouts yet" in client.get("/").text
    client.app.state.store.put(state())
    html = client.get("/").text
    assert "Weekly volume" in html and "Upper" in html and "kg" in html


def test_pages_and_data_actions(client, tmp_path):
    store = client.app.state.store
    store.put(state())
    (tmp_path / "motion").mkdir(exist_ok=True)
    head = '# {"auto":9,"reps":10,"checked":true,"exId":"0025","w":20,"end":1794984800412}\nt\n'
    store.save_motion("20261118-120000_0025_s1.csv", head)
    for path in ("/history", "/plan", "/exercises", "/body", "/stats", "/report", "/connect", "/stats?range=1y", "/report?range=3m"):
        assert client.get(path).status_code == 200, path
    wid = state()["workouts"][0]["id"]
    assert "Working sets" in client.get(f"/history/{wid}").text
    ex = client.get("/exercises").text.split('href="/exercises/')[1].split('"')[0]
    assert "Estimated 1RM per session" in client.get(f"/progress?ex={ex}").text   # old links still land
    assert client.get("/data/sets.csv").text.startswith("date,workout,exercise_id")
    reps = client.get("/reps").text
    assert "0 of 1 counted right" in reps and "+0" not in reps and "-1" in reps
    assert "New pairing code" in client.get("/data").text

    same = {"Origin": "http://testserver"}
    page = client.post("/data/pair", headers=same).text
    code = page.split('<div class="code">')[1].split("<")[0]
    assert client.post("/api/pair/redeem", json={"code": code}).status_code == 200
    (h, _), = store.tokens()
    assert client.post("/data/restore", data={"rev": "1"}, headers=same, follow_redirects=False).status_code == 303
    assert store.current()[0] == 2 and store.document(2)["workouts"] == store.document(1)["workouts"]
    client.post("/data/revoke", data={"h": h}, headers=same)
    assert store.tokens() == []
    assert client.get("/data/rev/1.json").json()["_rev"] == 1

    # Another website open on this Mac cannot post to the dashboard.
    assert client.post("/data/pair", headers={"Origin": "https://evil.example"}).status_code == 403
    assert client.post("/data/pair", headers={"Sec-Fetch-Site": "cross-site"}).status_code == 403


def test_dashboard_is_local_only(tmp_path):
    other = TestClient(create_app(tmp_path), client=("192.168.1.20", 50000))
    assert other.get("/").status_code == 403 and other.get("/data/latest.json").status_code == 403
    assert other.get("/api/health").status_code == 200   # the phone's API stays reachable


def test_code_typed_with_another_keyboard(client):
    code = client.app.state.store.new_pair_code()
    wide = "".join(chr(ord(c) + 0xFEE0) for c in code.lower())   # full-width, as a Chinese keyboard types it
    assert client.post("/api/pair/redeem", json={"code": f" {wide[:4]}-{wide[4:]} "}).status_code == 200
