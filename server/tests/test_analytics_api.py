"""Tests for `/analytics/api/*`, DNS-rebinding Host allowlist (R2), CSRF broadening,
unshadowable `/analytics/api/*` (R8), analytics-dir isolation & Cache-Control (R12),
i18n placeholder parity (C3), and end-to-end Web AI Coach / Settings flows.
"""
import datetime as dt
import json
import re
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from hexserver import i18n
from hexserver.app import create_app

SAME = {"Origin": "http://testserver", "Sec-Fetch-Site": "same-origin"}


def _sample_state(today: str) -> dict:
    t = dt.date.fromisoformat(today)
    d_prev = (t - dt.timedelta(days=2)).isoformat()
    d_tom = (t + dt.timedelta(days=1)).isoformat()
    wd_tom = str((dt.date.fromisoformat(d_tom).weekday() + 1) % 7)
    start_ms = int(dt.datetime.fromisoformat(d_prev + "T10:00:00+00:00").timestamp() * 1000)
    return {
        "unit": "kg",
        "weekStart": 1,
        "bwGoal": 78.0,
        "nutritionGoals": {"kcal": 2500, "protein": 160, "carbs": 290, "fat": 75},
        "bodyweight": [
            {"d": (t - dt.timedelta(days=40)).isoformat(), "w": 81.5, "t": start_ms - 86400_000 * 38},
            {"d": d_prev, "w": 80.2, "t": start_ms},
        ],
        "measurements": [
            {"d": d_prev, "bodyFat": 15.2, "waist": 82.0, "t": start_ms},
        ],
        "meals": {
            "m1": {"id": "m1", "date": today, "name": "Chicken Bowl", "kcal": 720, "protein": 58, "carbs": 75, "fat": 18, "_ts": start_ms + 1000},
            "m_del": {"id": "m_del", "date": today, "deleted": True, "kcal": 999, "_ts": start_ms + 2000},
        },
        "routines": [
            {
                "id": "r-push",
                "name": "Push A",
                "ex": [
                    {"id": "0025", "sets": 4, "reps": 8, "weight": 80, "mode": "reps", "restSec": 120},
                    {"id": "0289", "sets": 3, "reps": 10, "weight": 24, "mode": "reps"},
                ],
            },
            {
                "id": "r-pull",
                "name": "Pull A",
                "ex": [
                    {"id": "0027", "sets": 4, "reps": 8, "weight": 70, "mode": "reps"},
                ],
            },
        ],
        "week": {wd_tom: ["r-push"]},
        "workouts": [
            {
                "id": "w1",
                "d": d_prev,
                "name": "Push A",
                "routineId": "r-push",
                "start": start_ms,
                "end": start_ms + 52 * 60_000,
                "vol": 4200,
                "bw": 80.2,
                "prs": ["0025"],
                "note": "Felt strong",
                "entries": [
                    {
                        "id": "0025",
                        "sets": [
                            {"w": 40, "r": 10, "done": True, "phase": "warmup"},
                            {"w": 80, "r": 8, "done": True, "rir": 2, "hr": {"avg": 132}},
                            {"w": 80, "r": 8, "done": True, "rir": 1, "hr": {"avg": 138}},
                        ],
                    }
                ],
            }
        ],
    }


@pytest.fixture
def env_clean(monkeypatch):
    for k in ("HEX_AI_BASE_URL", "HEX_AI_MODEL", "HEX_AI_KEY", "HEX_AI_DAILY_TOKEN_CAP", "HEX_AI_RATE_LIMIT_PER_MIN"):
        monkeypatch.delenv(k, raising=False)


@pytest.fixture
def app(tmp_path, monkeypatch, env_clean):
    dist = tmp_path / "dist"
    dist.mkdir()
    (dist / "index.html").write_text('<!doctype html><div id="root"></div>')
    monkeypatch.setenv("HEXPLATE_ANALYTICS", str(dist))
    application = create_app(tmp_path / "data")
    today = dt.date.today().isoformat()
    application.state.store.put(_sample_state(today))
    return application


# MARK: - Security Guards (R2, R8, R12)


def test_dns_rebinding_host_blocked_on_get_and_post(app):
    c = TestClient(app)
    evil = {"Host": "evil.example:8765", "Origin": "http://evil.example:8765", "Sec-Fetch-Site": "same-origin"}
    assert c.get("/analytics/api/dataset", headers=evil).status_code == 403
    assert c.post("/analytics/api/settings/ai", headers=evil, json={"baseUrl": "https://evil.example"}).status_code == 403
    assert c.get("/analytics/", headers={"Host": "evil.example"}).status_code == 403
    assert c.get("/", headers={"Host": "evil.example"}).status_code == 403
    # Valid loopback host variants still pass
    for ok_host in ("127.0.0.1:8765", "localhost:8765", "[::1]:8765", "testserver"):
        assert c.get("/analytics/api/bootstrap", headers={"Host": ok_host}).status_code == 200


def test_csrf_blocks_delete_and_mismatched_origin(app):
    c = TestClient(app)
    assert c.delete("/analytics/api/connect/webhooks/abc").status_code == 403
    bad_origin = {"Host": "testserver", "Sec-Fetch-Site": "same-origin", "Origin": "http://evil.example"}
    assert c.post("/analytics/api/settings/lang", headers=bad_origin, json={"lang": "zh"}).status_code == 403


def test_unknown_analytics_api_returns_json_404_not_spa_shell(app):
    c = TestClient(app)
    r = c.get("/analytics/api/nope")
    assert r.status_code == 404
    assert r.headers["content-type"].startswith("application/json")
    assert "root" not in r.text


def test_analytics_dir_overlapping_store_folder_refused(tmp_path, monkeypatch, env_clean):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    (data_dir / "index.html").write_text("should never serve")
    (data_dir / "ai-config.json").write_text('{"api_key":"secret"}')
    monkeypatch.setenv("HEXPLATE_ANALYTICS", str(data_dir))
    c = TestClient(create_app(data_dir))
    assert c.get("/analytics/").status_code == 403
    assert c.get("/analytics/ai-config.json").status_code == 403


def test_cache_control_no_store_on_ai_and_bootstrap(app):
    c = TestClient(app)
    for path in ("/analytics/api/bootstrap", "/analytics/api/settings/ai", "/analytics/api/ai/coach/context"):
        r = c.get(path)
        assert r.status_code == 200
        assert r.headers.get("cache-control") == "no-store"


# MARK: - C3 i18n placeholder parity


def test_dashboard_zh_placeholder_parity():
    ph = re.compile(r"\{[a-zA-Z0-9_]+(?::[^}]+)?\}")
    for en_key, zh_val in i18n.DASHBOARD_ZH.items():
        assert set(ph.findall(en_key)) == set(ph.findall(zh_val)), f"Placeholder mismatch for {en_key!r}: {zh_val!r}"
    assert "Overview" in i18n.dashboard_zh_strings()
    # SSR ZH remains unaffected by DASHBOARD_ZH additions
    assert "AI Coach & API" not in i18n.ZH


# MARK: - Full-Parity Data, Detail, Connect & Settings Endpoints


def test_bootstrap_dataset_details_and_report(app):
    c = TestClient(app)
    today = dt.date.today().isoformat()

    boot = c.get(f"/analytics/api/bootstrap?today={today}").json()
    assert boot["hasData"] is True
    assert boot["lang"] == "en"
    assert boot["mcp"]["tools"] and len(boot["mcp"]["tools"]) == 5

    ds = c.get(f"/analytics/api/dataset?today={today}").json()
    assert ds["source"] == "local"
    assert len(ds["sessions"]) == 1
    assert ds["sessions"][0]["id"] == "w1"
    assert ds["sessions"][0]["prs"] == 1
    assert ds["nutrition"] and ds["nutrition"][0]["totals"]["kcal"] == 720  # tombstone excluded
    assert ds["plan"]["routines"][0]["name"] == "Push A"
    assert len(ds["exercises"]) == 1
    assert ds["body"]["latest"]["w"] == 80.2
    assert len(ds["stats"]["heatmap"]) == 371

    w = c.get("/analytics/api/workouts/w1").json()
    assert w["name"] == "Push A"
    assert w["note"] == "Felt strong"
    assert len(w["entries"][0]["sets"]) == 3

    ex = c.get("/analytics/api/exercises/0025").json()
    assert ex["sessionsCount"] == 1
    assert ex["bestE1rm"]["w"] == 80

    rep = c.get(f"/analytics/api/report?range=4w&today={today}").json()
    assert rep["current"]["workouts"] == 1
    assert len(rep["records"]) == 1


def test_sync_webhooks_and_language_settings(app):
    c = TestClient(app)
    # Language toggle returns ZH dictionary immediately
    r = c.post("/analytics/api/settings/lang", headers=SAME, json={"lang": "zh"})
    assert r.status_code == 200
    body = r.json()
    assert body["lang"] == "zh"
    assert "Overview" in body["strings"]

    # Pairing code + version list
    p = c.post("/analytics/api/data/pair", headers=SAME)
    assert p.status_code == 200 and len(p.json()["code"]) >= 6
    assert p.headers.get("cache-control") == "no-store"
    d = c.get("/analytics/api/data").json()
    assert len(d["versions"]) == 1

    # Webhook add -> pause -> delete
    added = c.post(
        "/analytics/api/connect/webhooks",
        headers=SAME,
        json={"label": "HA", "url": "https://hooks.example.com/abc", "events": ["workout.finished"]},
    )
    assert added.status_code == 200
    assert added.headers.get("cache-control") == "no-store"
    wid = added.json()["id"]
    assert added.json()["secret"].startswith("whsec_")

    conn = c.get("/analytics/api/connect").json()
    assert len(conn["webhooks"]) == 1
    assert "secret" not in conn["webhooks"][0]

    assert c.post(f"/analytics/api/connect/webhooks/{wid}/pause", headers=SAME, json={"paused": True}).status_code == 200
    assert c.delete(f"/analytics/api/connect/webhooks/{wid}", headers=SAME).status_code == 200
    assert c.get("/analytics/api/connect").json()["webhooks"] == []


def test_ai_settings_and_web_coach_propose_apply_undo(app):
    today = dt.date.today().isoformat()
    tom = (dt.date.fromisoformat(today) + dt.timedelta(days=1)).isoformat()
    day2 = (dt.date.fromisoformat(today) + dt.timedelta(days=2)).isoformat()

    def handler(req: httpx.Request) -> httpx.Response:
        payload = json.loads(req.content.decode())
        if payload.get("max_tokens") == 16:
            return httpx.Response(200, json={"choices": [{"message": {"content": "OK"}}], "usage": {"total_tokens": 5}})
        reply = {
            "answer": "Moved Push A by one day so you can recover.",
            "ops": [{"type": "move_day", "from": tom, "to": day2, "collision": "swap", "reason": "Extra rest"}],
        }
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": json.dumps(reply)}}], "usage": {"prompt_tokens": 50, "completion_tokens": 30, "total_tokens": 80}},
        )

    app.state.ai.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    c = TestClient(app)

    # Save AI config
    saved = c.post(
        "/analytics/api/settings/ai",
        headers=SAME,
        json={
            "baseUrl": "https://api.example.com/v1",
            "model": "gpt-4o-mini",
            "apiKey": "sk-test-1234567890abcdef",
            "dailyTokenCap": 50000,
            "rateLimitPerMin": 20,
        },
    )
    assert saved.status_code == 200
    assert saved.json()["configured"] is True
    assert saved.json()["keyHint"].endswith("cdef")
    assert "sk-test" not in saved.text

    # Host swap without new key rejected (R1)
    bad_swap = c.post(
        "/analytics/api/settings/ai",
        headers=SAME,
        json={"baseUrl": "https://other.example.com/v1"},
    )
    assert bad_swap.status_code == 400 and bad_swap.json()["code"] == "key-required-for-new-host"

    # Test connection works
    tested = c.post("/analytics/api/settings/ai/test", headers=SAME, json={})
    assert tested.status_code == 200 and tested.json()["ok"] is True

    # Coach propose -> diff -> apply -> undo
    prop = c.post(
        "/analytics/api/ai/coach",
        headers=SAME,
        json={"message": "Move tomorrow's workout to the day after tomorrow", "today": today, "timezone": "UTC", "lang": "en"},
    )
    assert prop.status_code == 200
    pdata = prop.json()
    assert pdata["hasChanges"] is True
    assert pdata["touchedDates"] == [tom, day2]

    applied = c.post(
        "/analytics/api/ai/coach/apply",
        headers=SAME,
        json={
            "ops": pdata["changes"],
            "baseRev": pdata["baseRev"],
            "baseWid": pdata["baseWid"],
            "expectedDigests": pdata["expectedDigests"],
            "today": today,
            "timezone": "UTC",
        },
    )
    assert applied.status_code == 200
    adata = applied.json()
    assert adata["ok"] is True and adata["undo"]["status"] == "available"

    # Re-applying stale preview returns 409
    stale = c.post(
        "/analytics/api/ai/coach/apply",
        headers=SAME,
        json={
            "ops": pdata["changes"],
            "baseRev": pdata["baseRev"],
            "baseWid": pdata["baseWid"],
            "expectedDigests": pdata["expectedDigests"],
            "today": today,
            "timezone": "UTC",
        },
    )
    assert stale.status_code == 409

    # Undo restores cleanly
    undone = c.post(
        "/analytics/api/ai/coach/undo",
        headers=SAME,
        json={"tokenId": adata["undo"]["tokenId"], "today": today, "timezone": "UTC"},
    )
    assert undone.status_code == 200
    assert undone.json()["restoredDates"] == [tom, day2]


# MARK: - Polish & Language Switch Hardening Tests (P1, P6, RC5, RC9)


def test_workout_detail_numbers_warmups_null_and_working_sets_from_one(app):
    today = dt.date.today().isoformat()
    _, state = app.state.store.current()
    state["workouts"][0]["entries"][0]["sets"].append(
        {
            "sides": {
                "L": {"w": 30, "r": 12, "done": True},
                "R": {"w": 30, "r": 12, "done": True},
            }
        }
    )
    app.state.store.put(state)
    c = TestClient(app)
    w = c.get("/analytics/api/workouts/w1").json()
    sets = w["entries"][0]["sets"]
    # Warm-up -> index None; working sets -> 1, 2; unilateral L & R -> both share 3.
    assert [(s["warmup"], s["index"], s["side"]) for s in sets] == [
        (True, None, None),
        (False, 1, None),
        (False, 2, None),
        (False, 3, "L"),
        (False, 3, "R"),
    ]
    assert w["date"] <= today


def test_coach_context_exposes_is_ai_clone_after_set_sets_apply(app):
    today = dt.date.today().isoformat()
    tom = (dt.date.fromisoformat(today) + dt.timedelta(days=1)).isoformat()

    def handler(req: httpx.Request) -> httpx.Response:
        reply = {
            "answer": "Reduced bench press to 3 sets tomorrow.",
            "ops": [
                {
                    "type": "set_sets",
                    "date": tom,
                    "routineId": "R1",
                    "slotIndex": 0,
                    "exerciseId": "E1",
                    "sets": 3,
                    "reps": 8,
                    "reason": "Manage fatigue",
                }
            ],
        }
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": json.dumps(reply)}}], "usage": {"total_tokens": 60}},
        )

    app.state.ai.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    c = TestClient(app)
    c.post(
        "/analytics/api/settings/ai",
        headers=SAME,
        json={"baseUrl": "https://api.example.com/v1", "model": "gpt-4o-mini", "apiKey": "sk-test-1234567890abcdef"},
    )

    before = c.get(f"/analytics/api/ai/coach/context?today={today}&timezone=UTC").json()
    tom_before = next(d for d in before["summary"]["plannedNext7d"] if d["date"] == tom)
    assert tom_before["isAIClone"] is False

    prop = c.post(
        "/analytics/api/ai/coach",
        headers=SAME,
        json={"message": "Drop 1 set of bench press tomorrow", "today": today, "timezone": "UTC", "lang": "en"},
    ).json()
    assert prop["hasChanges"] is True

    applied = c.post(
        "/analytics/api/ai/coach/apply",
        headers=SAME,
        json={
            "ops": prop["changes"],
            "baseRev": prop["baseRev"],
            "baseWid": prop["baseWid"],
            "expectedDigests": prop["expectedDigests"],
            "today": today,
            "timezone": "UTC",
        },
    )
    assert applied.status_code == 200

    after = c.get(f"/analytics/api/ai/coach/context?today={today}&timezone=UTC").json()
    tom_after = next(d for d in after["summary"]["plannedNext7d"] if d["date"] == tom)
    assert tom_after["isAIClone"] is True
    unmodified = [d for d in after["summary"]["plannedNext7d"] if d["date"] != tom]
    assert all(d["isAIClone"] is False for d in unmodified)


def test_origin_normalization_and_negative_csrf_and_ssr_lang_switch(app):
    c = TestClient(app)

    # Mixed-case Host, default port (:80), and IPv6 loopback accepted when matching Origin.
    assert c.post(
        "/analytics/api/settings/lang",
        headers={"Host": "Localhost:8765", "Origin": "http://localhost:8765", "Sec-Fetch-Site": "same-origin"},
        json={"lang": "zh"},
    ).status_code == 200
    assert c.post(
        "/analytics/api/settings/lang",
        headers={"Host": "localhost:80", "Origin": "http://localhost", "Sec-Fetch-Site": "same-origin"},
        json={"lang": "en"},
    ).status_code == 200
    assert c.post(
        "/analytics/api/settings/lang",
        headers={"Host": "[::1]:8765", "Origin": "http://[::1]:8765", "Sec-Fetch-Site": "same-origin"},
        json={"lang": "zh"},
    ).status_code == 200

    # Negative CSRF cases all rejected with 403.
    bad_headers = [
        {"Host": "localhost:8765", "Origin": "null", "Sec-Fetch-Site": "same-origin"},
        {"Host": "localhost:8765", "Origin": "null"},
        {"Host": "localhost:8765", "Origin": "http://user@localhost:8765", "Sec-Fetch-Site": "same-origin"},
        {"Host": "localhost:8765", "Origin": "http://localhost:9999", "Sec-Fetch-Site": "same-origin"},
        {"Host": "localhost:8765", "Origin": "http://localhost:8765/path", "Sec-Fetch-Site": "same-origin"},
        {"Host": "localhost:8765", "Origin": "http://localhost:8765?q=1", "Sec-Fetch-Site": "same-origin"},
        {"Host": "localhost:8765", "Origin": "http://localhost:8765#frag", "Sec-Fetch-Site": "same-origin"},
        {"Host": "localhost:8765", "Origin": "http://evil.example:8765", "Sec-Fetch-Site": "same-origin"},
    ]
    for hdrs in bad_headers:
        assert c.post("/analytics/api/settings/lang", headers=hdrs, json={"lang": "en"}).status_code == 403, hdrs

    # Legacy SSR POST /settings/lang returns 303 redirect and persists setting.
    ssr_zh = c.post(
        "/settings/lang",
        headers={"Host": "Localhost:8765", "Origin": "http://localhost:8765", "Sec-Fetch-Site": "same-origin"},
        data={"lang": "zh"},
        follow_redirects=False,
    )
    assert ssr_zh.status_code == 303
    assert ssr_zh.headers["location"] == "/settings"
    assert app.state.store.setting("lang") == "zh"

    ssr_en = c.post(
        "/settings/lang",
        headers={"Host": "127.0.0.1:8765", "Origin": "http://127.0.0.1:8765", "Sec-Fetch-Site": "same-origin"},
        data={"lang": "en"},
        follow_redirects=False,
    )
    assert ssr_en.status_code == 303
    assert ssr_en.headers["location"] == "/settings"
    assert app.state.store.setting("lang") == "en"


def test_analytics_index_html_returns_no_cache_on_all_branches(app):
    c = TestClient(app)
    for path in ("/analytics/", "/analytics/index.html", "/analytics/some-spa-route"):
        r = c.get(path)
        assert r.status_code == 200, path
        assert r.headers.get("cache-control") == "no-cache", path
