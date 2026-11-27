"""Web AI settings (ai.py R1/R7/R11/R12) and the server-side web Coach (coach_web.py R3-R6, C1/C2/C6)."""
import asyncio
import copy
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import stat

import httpx
import pytest

from hexserver import ai, coach_web as cw
from hexserver.store import Conflict, Store

FIXTURES = Path(__file__).resolve().parents[2] / "app/HexplateCore/Tests/HexplateCoreTests/Fixtures"
ENV_VARS = (
    "HEX_AI_BASE_URL",
    "HEX_AI_MODEL",
    "HEX_AI_FALLBACK_MODEL",
    "HEX_AI_KEY",
    "HEX_AI_DAILY_TOKEN_CAP",
    "HEX_AI_RATE_LIMIT_PER_MIN",
)
SAVED_KEY = "sk-saved-provider-key-0001"


@pytest.fixture(autouse=True)
def _no_ai_env(monkeypatch):
    for var in ENV_VARS:
        monkeypatch.delenv(var, raising=False)


def _ok_completion(content="OK", tokens=(5, 1)):
    return httpx.Response(200, json={
        "choices": [{"message": {"content": content}}],
        "usage": {"prompt_tokens": tokens[0], "completion_tokens": tokens[1], "total_tokens": sum(tokens)},
    })


class Recorder:
    """An httpx MockTransport that records every request it is sent."""

    def __init__(self, reply=None):
        self.requests: list[httpx.Request] = []
        self.reply = reply or (lambda req: _ok_completion())

    def client(self):
        def handler(req):
            self.requests.append(req)
            return self.reply(req)

        return httpx.AsyncClient(transport=httpx.MockTransport(handler))


# MARK: - R1 / C2: a saved key is bound to its provider origin


def test_origin_of_rejects_userinfo_bad_port_and_missing_host():
    assert ai.origin_of("https://api.example.com/v1") == ("https", "api.example.com", 443)
    assert ai.origin_of("http://127.0.0.1:8080/v1") == ("http", "127.0.0.1", 8080)
    assert ai.origin_of("http://localhost") == ("http", "localhost", 80)
    assert ai.origin_of("HTTPS://API.Example.com:443/v1") == ("https", "api.example.com", 443)
    assert ai.origin_of("https://api.example.com@evil.example/v1") is None
    assert ai.origin_of("https://user:pw@api.example.com/v1") is None
    assert ai.origin_of("https://api.example.com:99999/v1") is None
    assert ai.origin_of("https:///v1") is None
    assert ai.origin_of("ftp://api.example.com") is None
    assert ai.origin_of(None) is None and ai.origin_of("") is None


def test_saved_key_is_never_sent_to_a_swapped_host(tmp_path):
    rec = Recorder()
    svc = ai.AIService(tmp_path, client=rec.client())
    svc.save_config(base_url="https://api.good.example/v1", model="m-1", api_key=SAVED_KEY)

    # Saving another host without a fresh key is refused, and the file still holds the good host.
    with pytest.raises(ai.AIBadRequestError) as exc:
        svc.save_config(base_url="https://evil.example/v1")
    assert exc.value.code == "key-required-for-new-host"
    assert svc.current_config().base_url == "https://api.good.example/v1"

    # Testing another host (or a userinfo / bad-port spelling of it) never reaches the network.
    for draft in ("https://evil.example/v1", "https://api.good.example:8443/v1"):
        with pytest.raises(ai.AIBadRequestError) as exc:
            asyncio.run(svc.test_connection(base_url=draft))
        assert exc.value.code == "key-required-for-new-host"
    for draft in ("https://api.good.example@evil.example/v1", "https://api.good.example:99999/v1"):
        with pytest.raises(ai.AIBadRequestError) as exc:
            asyncio.run(svc.test_connection(base_url=draft))
        assert exc.value.code == "invalid-base-url"
        with pytest.raises(ai.AIBadRequestError) as exc:
            svc.save_config(base_url=draft)
        assert exc.value.code == "invalid-base-url"
    assert rec.requests == []

    # A fresh draft key goes to the new host; the saved key goes only to its own origin.
    asyncio.run(svc.test_connection(base_url="https://evil.example/v1", api_key="sk-draft-only"))
    asyncio.run(svc.test_connection())
    asyncio.run(svc.test_connection(base_url="https://API.good.example:443/v2"))
    sent = [(r.url.host, r.headers["authorization"]) for r in rec.requests]
    assert sent == [
        ("evil.example", "Bearer sk-draft-only"),
        ("api.good.example", f"Bearer {SAVED_KEY}"),
        ("api.good.example", f"Bearer {SAVED_KEY}"),
    ]
    assert all(SAVED_KEY not in r.content.decode() for r in rec.requests)

    # Changing the host with a fresh key, or clearing the key, is allowed.
    svc.save_config(base_url="https://other.example/v1", clear_api_key=True)
    assert svc.current_config().api_key == ""
    svc.save_config(base_url="https://other2.example/v1", api_key="sk-other-key")
    assert svc.current_config().api_key == "sk-other-key"


def test_base_url_and_key_resolve_as_one_pair(tmp_path, monkeypatch):
    monkeypatch.setenv("HEX_AI_BASE_URL", "https://env.example/v1")
    monkeypatch.setenv("HEX_AI_KEY", "sk-env-key")
    monkeypatch.setenv("HEX_AI_MODEL", "env-model")
    svc = ai.AIService(tmp_path)
    assert svc.masked_config()["source"] == "env"

    # A file base_url never borrows the env key ...
    svc.save_config(base_url="https://file.example/v1")
    cfg = svc.current_config()
    assert (cfg.base_url, cfg.api_key, cfg.model) == ("https://file.example/v1", "", "env-model")
    assert not cfg.is_configured
    assert svc.masked_config()["source"] == "mixed"
    # ... and a file key never goes to the env host.
    ai.atomic_write_secret_json(svc.config_file, {"api_key": "sk-file-key"})
    cfg = svc.current_config()
    assert (cfg.base_url, cfg.api_key) == (None, "sk-file-key")

    # Model, cap and rate merge per field; reset_to_env drops the file.
    svc.save_config(reset_to_env=True)
    assert not svc.config_file.exists()
    svc.save_config(model="file-model", daily_token_cap=5000)
    cfg = svc.current_config()
    assert (cfg.base_url, cfg.api_key, cfg.model, cfg.daily_token_cap) == ("https://env.example/v1", "sk-env-key", "file-model", 5000)
    assert "sk-env-key" not in svc.config_file.read_text()


# MARK: - R7: 0600 atomic writes and capped, crash-proof reads


def test_secret_file_is_0600_and_corrupt_or_oversize_files_fall_back(tmp_path, monkeypatch):
    svc = ai.AIService(tmp_path)
    svc.save_config(base_url="https://api.good.example/v1", model="m", api_key=SAVED_KEY)
    assert stat.S_IMODE(os.stat(svc.config_file).st_mode) == 0o600
    assert not [p for p in tmp_path.iterdir() if p.name.endswith(".tmp")]

    monkeypatch.setenv("HEX_AI_BASE_URL", "https://env.example/v1")
    monkeypatch.setenv("HEX_AI_KEY", "sk-env-key")
    monkeypatch.setenv("HEX_AI_MODEL", "env-model")
    for broken in (b"{not json", b"[1, 2]", b"\xff\xfe", b"{" + b" " * ai.MAX_SECRET_FILE_BYTES + b"}"):
        svc.config_file.write_bytes(broken)
        assert ai.read_capped_json(svc.config_file) is None
        cfg = svc.current_config()
        assert (cfg.base_url, cfg.api_key) == ("https://env.example/v1", "sk-env-key")
    assert ai.read_capped_json(tmp_path / "missing.json") is None


# MARK: - R12: bounds and key hint


def test_bounds_and_key_hint(tmp_path):
    svc = ai.AIService(tmp_path)
    for bad in (0, ai.MAX_DAILY_TOKEN_CAP + 1, True, "5", 1.5, -3):
        with pytest.raises(ai.AIBadRequestError) as exc:
            svc.save_config(daily_token_cap=bad)
        assert exc.value.code == "invalid-config"
    for bad in (0, ai.MAX_RATE_LIMIT_PER_MIN + 1, False, "10"):
        with pytest.raises(ai.AIBadRequestError) as exc:
            svc.save_config(rate_limit_per_min=bad)
        assert exc.value.code == "invalid-config"
    masked = svc.save_config(daily_token_cap=ai.MAX_DAILY_TOKEN_CAP, rate_limit_per_min=ai.MAX_RATE_LIMIT_PER_MIN)
    assert (masked["dailyTokenCap"], masked["rateLimitPerMin"]) == (ai.MAX_DAILY_TOKEN_CAP, ai.MAX_RATE_LIMIT_PER_MIN)

    short = svc.save_config(base_url="https://api.good.example/v1", model="m", api_key="sk-short-15char")
    assert short["hasKey"] is True and short["keyHint"] is None
    full = svc.save_config(api_key=SAVED_KEY)
    assert full["keyHint"] == "\u2022\u2022\u2022\u2022" + SAVED_KEY[-4:]
    assert SAVED_KEY not in json.dumps(full)
    assert set(full) == {"configured", "source", "baseUrl", "model", "fallbackModel", "hasKey", "keyHint", "dailyTokenCap",
                         "rateLimitPerMin", "dailyTokensUsed", "envFallbackAvailable"}
    assert full["configured"] is True and full["source"] == "file" and full["envFallbackAvailable"] is False


# MARK: - R11: the web test is rate-limited and its usage is logged


def test_test_connection_is_rate_limited_and_logged(tmp_path):
    rec = Recorder()
    svc = ai.AIService(tmp_path, client=rec.client())
    svc.save_config(base_url="https://api.good.example/v1", model="m", api_key=SAVED_KEY, rate_limit_per_min=1)
    out = asyncio.run(svc.test_connection())
    assert out["ok"] is True and out["model"] == "m" and isinstance(out["elapsedMs"], int)
    assert SAVED_KEY not in json.dumps(out)
    body = json.loads(rec.requests[0].content)
    assert body["max_tokens"] == ai.TEST_CONNECTION_MAX_TOKENS and body["temperature"] == 0.0
    with pytest.raises(ai.AIRateLimitError):
        asyncio.run(svc.test_connection())
    lines = [json.loads(x) for x in svc.usage_file.read_text().splitlines()]
    assert [(x["endpoint"], x["total_tokens"]) for x in lines] == [("test", 6)]
    assert svc.daily_tokens_used() == 6


# MARK: - R4: golden parity with the Swift / JavaScript originals


def test_stamp_change_matches_the_golden_file():
    cases = json.loads((FIXTURES / "stamp-cases.json").read_text())
    golden = json.loads((FIXTURES / "stamp-golden.json").read_text())
    assert [c["name"] for c in cases] == [g["name"] for g in golden] and len(cases) > 15
    for case, gold in zip(cases, golden):
        nxt = copy.deepcopy(case["next"])
        nxt["_ts"] = cw.stamp_change(case["prev"], nxt, case["wall"])
        expected = gold["next"]
        for key in sorted(set(nxt) | set(expected)):
            assert cw._eq(nxt.get(key, cw._MISSING), expected.get(key, cw._MISSING)), f"{case['name']}: {key}"


def test_recovery_matches_the_golden_file():
    cases = json.loads((FIXTURES / "recovery-cases.json").read_text())
    golden = json.loads((FIXTURES / "recovery-golden.json").read_text())
    assert len(cases) == len(golden)
    checked = 0
    for case, gold in zip(cases, golden):
        if case["op"] != "fatigue":
            continue  # the `hint` cases cover Recovery.hint (the Home card), not loadSummary
        now = cw.day_noon_ms(case["today"]) + (case.get("hours") or 0) * 3_600_000
        got = cw.fatigue_map(case["workouts"], now, unit=case.get("unit"), bodyweight_kg=case.get("bodyweightKg"))
        assert set(got) == set(gold["result"]), gold["name"]
        for slug, want in gold["result"].items():
            assert abs(math.floor(got[slug] * 1e6 + 0.5) / 1e6 - want) <= 1.5e-6, f"{gold['name']}: {slug}"
        checked += 1
    assert checked == 8

    state = {"unit": "kg", "workouts": cases[0]["workouts"], "bodyweight": [{"d": "2026-11-01", "w": 80}]}
    summary = cw.compute_recovery(state, cw.day_noon_ms(cases[0]["today"]))
    assert set(summary) == {"muscles", "global"} and set(summary["global"]) == {"acute", "chronic", "ratio"}
    fatigue = {k: v["fatigue"] for k, v in summary["muscles"].items()}
    assert fatigue == pytest.approx(cw.fatigue_map(cases[0]["workouts"], cw.day_noon_ms(cases[0]["today"]), unit="kg", bodyweight_kg=80))
    assert all(v["hoursToRecovered"] >= 0 for v in summary["muscles"].values())


# MARK: - A live document for the Coach flow


def _today() -> str:
    return dt.datetime.now(dt.timezone.utc).date().isoformat()


def _state(today: str) -> dict:
    tomorrow, after = dt.date.fromisoformat(today) + dt.timedelta(days=1), dt.date.fromisoformat(today) + dt.timedelta(days=2)
    wd = lambda d: str((d.weekday() + 1) % 7)  # noqa: E731
    yesterday = (dt.date.fromisoformat(today) - dt.timedelta(days=1)).isoformat()
    return {
        "unit": "kg",
        "routines": [
            {"id": "rA", "name": "Upper", "ex": [{"id": "0025", "sets": 3, "reps": 8, "weight": 60, "_ts": 1}], "_ts": 1},
            {"id": "rB", "name": "Lower", "ex": [{"id": "0043", "sets": 3, "reps": 5, "weight": 100}], "_ts": 1},
        ],
        "week": {wd(dt.date.fromisoformat(today)): ["rA"], wd(tomorrow): ["rA"], wd(after): ["rB"]},
        "workouts": [{"id": "w1", "d": yesterday, "routineId": "rA", "name": "Upper", "entries": [
            {"id": "0025", "sets": [{"w": 60, "r": 8, "done": True}, {"w": 60, "r": 8, "done": True}]}]}],
        "meals": {"m1": {"date": today, "kcal": 600, "protein": 40}, "m2": {"deleted": True}},
        "nutritionGoals": {"kcal": 2500},
        "bodyweight": [{"d": yesterday, "w": 80, "t": 1}],
    }


class FakeBackup:
    def __init__(self):
        self.calls = 0

    def soon(self):
        self.calls += 1


@pytest.fixture
def live(tmp_path):
    store = Store(tmp_path)
    today = _today()
    store.put(_state(today))
    return store, FakeBackup(), today


def _coach_reply(context: dict, ops: list[dict]):
    def reply(req: httpx.Request):
        return _ok_completion(json.dumps({"answer": "Swapping bench for incline tomorrow.", "ops": ops}), tokens=(100, 40))

    return reply


def _aliases(context: dict) -> tuple[dict, dict]:
    return ({r["id"]: r["alias"] for r in context["routineAliases"]}, {e["id"]: e["alias"] for e in context["exerciseAliases"]})


def _svc(tmp_path, reply) -> tuple[ai.AIService, Recorder]:
    rec = Recorder(reply)
    svc = ai.AIService(tmp_path, client=rec.client(), config=ai.AIConfig(base_url="https://api.good.example/v1", model="m", api_key=SAVED_KEY))
    return svc, rec


# MARK: - R3 / C6: today is locked and must be the server's today


def test_context_locks_today_and_rejects_a_skewed_today(live):
    store, _, today = live
    _, state = store.current()
    built = cw.build_web_coach_context(state, today=today, timezone="UTC")
    ctx, summary = built["context"], built["summary"]
    assert ctx["plan"][0]["date"] == today and ctx["plan"][0]["locked"] == "active"
    assert all(p.get("locked") != "active" for p in ctx["plan"][1:])
    assert len(ctx["plan"]) == ai.COACH_WINDOW_DAYS + 1
    assert summary["todayLockedReason"] == "active" and summary["recentWorkoutsCount"] == 1
    assert summary["todayNutrition"]["hexplate"]["kcal"] == 600 and summary["todayNutrition"]["goals"]["protein"] == 160
    assert ctx["routineAliases"][0] == {"alias": "R1", "id": "rA", "name": "Upper"}
    assert {"0025", "0043"} <= {e["id"] for e in ctx["exerciseAliases"]}
    assert 2 < len(ctx["exerciseAliases"]) <= 2 + cw.MAX_CANDIDATE_EXERCISES
    ai.extract_semantic_context(ctx)  # the snapshot is a valid phone-shaped context

    # The phone's semantic validator refuses an op on today.
    ralias, ealias = _aliases(ctx)
    op = {"type": "set_sets", "date": today, "routineId": "rA", "slotIndex": 0, "exerciseId": "0025", "sets": 4}
    with pytest.raises(ai.AIBadRequestError) as exc:
        cw.preview_coach_ops(state, [op], snapshot=ctx, today=today)
    assert exc.value.code == "locked_date"

    far = (dt.date.fromisoformat(today) + dt.timedelta(days=2)).isoformat()
    for bad_today, tz in ((far, "UTC"), ("2026-02-30", "UTC"), ("not-a-day", "UTC")):
        with pytest.raises(ai.AIBadRequestError) as exc:
            cw.build_web_coach_context(state, today=bad_today, timezone=tz)
        assert exc.value.code == "invalid-today"
    near = (dt.date.fromisoformat(today) + dt.timedelta(days=1)).isoformat()
    cw.build_web_coach_context(state, today=near, timezone="Not/AZone")  # unknown zone falls back to UTC
    with pytest.raises(ai.AIBadRequestError) as exc:
        cw.build_web_coach_context(None, today=today, timezone="UTC")
    assert exc.value.code == "no-data"


# MARK: - R5 / R6 / C1: propose -> preview -> apply -> undo


def _propose(svc, store, today, ops_for):
    _, state = store.current()
    ctx = cw.build_web_coach_context(state, today=today, timezone="UTC")["context"]
    svc.client = Recorder(_coach_reply(ctx, ops_for(ctx))).client()
    return asyncio.run(cw.propose_coach_change(svc, store, message="Swap tomorrow's bench press", today=today, timezone="UTC"))


def _swap_tomorrow(today):
    tomorrow = (dt.date.fromisoformat(today) + dt.timedelta(days=1)).isoformat()

    def ops(ctx):
        ralias, ealias = _aliases(ctx)
        return [{"type": "swap_exercise", "date": tomorrow, "routineId": ralias["rA"], "slotIndex": 0,
                 "fromExerciseId": ealias["0025"], "toExerciseId": ealias["0043"], "sets": 4, "reps": None,
                 "reason": "Chest is still recovering"}]

    return tomorrow, ops


def test_propose_apply_and_undo_round_trip(live, tmp_path):
    store, backup, today = live
    svc, _ = _svc(tmp_path, None)
    tomorrow, ops = _swap_tomorrow(today)
    rev0, before = store.current()

    proposal = _propose(svc, store, today, ops)
    assert proposal["hasChanges"] is True and proposal["touchedDates"] == [tomorrow]
    assert proposal["baseRev"] == rev0 and proposal["baseWid"] == before["_wid"]
    assert proposal["changes"][0]["routineId"] == "rA" and proposal["changes"][0]["toExerciseId"] == "0043"
    diff = proposal["dayDiffs"][0]
    assert diff["before"]["routineName"] == "Upper" and diff["after"]["isAIClone"] is True
    assert diff["slotChanges"][0]["kind"] == "swapped" and diff["slotChanges"][0]["sets"] == 4
    assert diff["slotChanges"][0]["toName"] == "Barbell Full Squat" and diff["reasons"] == ["Chest is still recovering"]
    assert store.current()[0] == rev0  # proposing never writes
    usage = [json.loads(x) for x in svc.usage_file.read_text().splitlines()]
    assert [u["endpoint"] for u in usage] == ["web-coach"]

    applied = cw.apply_coach_preview(store, backup, tmp_path, ops=proposal["changes"], base_rev=proposal["baseRev"],
                                     base_wid=proposal["baseWid"], expected_digests=proposal["expectedDigests"],
                                     today=today, timezone="UTC")
    rev1, after = store.current()
    assert applied["ok"] is True and applied["rev"] == rev1 == rev0 + 1 and backup.calls == 1
    clone_id = after["dayPlan"][tomorrow]
    clone = next(r for r in after["routines"] if r["id"] == clone_id)
    assert clone_id.startswith(f"ai-{tomorrow}-") and clone["aiClone"] is True and clone["cloneOf"] == "rA"
    assert clone["ephemeralDate"] == tomorrow and clone["ex"][0]["id"] == "0043" and clone["ex"][0]["sets"] == 4
    assert clone["ex"][0]["reps"] == 8  # carried from the reps slot it replaced
    assert after["edited"][f"dayPlan.{tomorrow}"] == after["_ts"] and clone["_ts"] == after["_ts"]
    assert after["_ts"] > cw.highest_stamp(before)
    assert next(r for r in after["routines"] if r["id"] == "rA") == next(r for r in before["routines"] if r["id"] == "rA")

    undo_file = tmp_path / cw.UNDO_FILE
    assert stat.S_IMODE(os.stat(undo_file).st_mode) == 0o600
    record = json.loads(undo_file.read_text())
    assert record["dayPlanDiffs"] == {tomorrow: {"before": None, "after": clone_id}}
    assert set(record["createdClones"]) == {clone_id} and "_ts" not in record["createdClones"][clone_id]
    assert record["tokenId"] not in json.dumps(after)  # the undo record never lives inside the document
    status = cw.get_undo_status(store, tmp_path, today=today)
    assert status["status"] == "available" and status["tokenId"] == applied["undo"]["tokenId"]

    undone = cw.undo_coach_batch(store, backup, tmp_path, token_id=record["tokenId"], today=today, timezone="UTC")
    rev2, restored = store.current()
    assert undone["rev"] == rev2 == rev1 + 1 and undone["restoredDates"] == [tomorrow]
    assert undone["removedCloneIds"] == [clone_id] and backup.calls == 2
    assert tomorrow not in restored.get("dayPlan", {}) and all(r["id"] != clone_id for r in restored["routines"])
    assert restored["deleted"]["routines"][clone_id] == restored["_ts"]
    assert restored["edited"][f"dayPlan.{tomorrow}"] == restored["_ts"]
    assert not undo_file.exists() and cw.get_undo_status(store, tmp_path, today=today) is None
    with pytest.raises(ai.AIError) as exc:
        cw.undo_coach_batch(store, backup, tmp_path, token_id=record["tokenId"], today=today, timezone="UTC")
    assert exc.value.code == "undo-not-found" and exc.value.status_code == 404


def test_apply_rejects_stale_previews_and_conflicts(live, tmp_path, monkeypatch):
    store, backup, today = live
    svc, _ = _svc(tmp_path, None)
    tomorrow, ops = _swap_tomorrow(today)
    proposal = _propose(svc, store, today, ops)
    args = dict(ops=proposal["changes"], base_rev=proposal["baseRev"], base_wid=proposal["baseWid"],
                expected_digests=proposal["expectedDigests"], today=today, timezone="UTC")

    for override in ({"base_rev": proposal["baseRev"] + 1}, {"base_wid": "someone-else"},
                     {"expected_digests": {tomorrow: "0" * 16}}, {"expected_digests": {}}):
        with pytest.raises(cw.CoachConflictError) as exc:
            cw.apply_coach_preview(store, backup, tmp_path, **{**args, **override})
        assert exc.value.code == "stale-preview" and exc.value.status_code == 409

    # The plan moved on the phone after the preview: same digest check, new rev -> stale.
    rev, state = store.current()
    week = dict(state["week"])
    week[str((dt.date.fromisoformat(tomorrow).weekday() + 1) % 7)] = ["rB"]
    store.put({**state, "week": week}, base_rev=rev, base_wid=state["_wid"])
    with pytest.raises(cw.CoachConflictError) as exc:
        cw.apply_coach_preview(store, backup, tmp_path, **{**args, "base_rev": rev + 1, "base_wid": None})
    assert exc.value.code == "stale-preview"

    # A write that loses the race maps to `conflict` and leaves no undo record behind.
    proposal = _propose(svc, store, today, lambda ctx: [{
        "type": "skip", "date": tomorrow, "reason": None}])
    def racing_put(*a, **k):
        raise Conflict(99, {})
    monkeypatch.setattr(store, "put", racing_put)
    with pytest.raises(cw.CoachConflictError) as exc:
        cw.apply_coach_preview(store, backup, tmp_path, ops=proposal["changes"], base_rev=proposal["baseRev"],
                               base_wid=proposal["baseWid"], expected_digests=proposal["expectedDigests"],
                               today=today, timezone="UTC")
    assert exc.value.code == "conflict"
    assert not (tmp_path / cw.UNDO_FILE).exists() and backup.calls == 0

    # Untrusted ops are schema-checked and semantically checked server-side.
    monkeypatch.undo()
    bad_ops = [{"type": "skip", "date": tomorrow, "evil": 1}]
    with pytest.raises(ai.AIBadRequestError) as exc:
        cw.apply_coach_preview(store, backup, tmp_path, **{**args, "ops": bad_ops, "base_rev": store.current()[0],
                                                           "base_wid": None, "expected_digests": {}})
    assert exc.value.code == "invalid_schema"
    with pytest.raises(ai.AIBadRequestError) as exc:
        cw.apply_coach_preview(store, backup, tmp_path, **{**args, "today": "1999-01-01"})
    assert exc.value.code == "invalid-today"


def test_undo_conflict_keeps_the_undo_record(live, tmp_path, monkeypatch):
    store, backup, today = live
    svc, _ = _svc(tmp_path, None)
    tomorrow, ops = _swap_tomorrow(today)
    p = _propose(svc, store, today, ops)
    cw.apply_coach_preview(store, backup, tmp_path, ops=p["changes"], base_rev=p["baseRev"], base_wid=p["baseWid"],
                           expected_digests=p["expectedDigests"], today=today, timezone="UTC")
    token = json.loads((tmp_path / cw.UNDO_FILE).read_text())["tokenId"]

    def racing_put(*a, **k):
        raise Conflict(99, {})
    monkeypatch.setattr(store, "put", racing_put)
    with pytest.raises(cw.CoachConflictError) as exc:
        cw.undo_coach_batch(store, backup, tmp_path, token_id=token, today=today, timezone="UTC")
    assert exc.value.code == "conflict" and (tmp_path / cw.UNDO_FILE).exists()

    # A workout logged on a touched day blocks the undo.
    monkeypatch.undo()
    rev, state = store.current()
    store.put({**state, "workouts": state["workouts"] + [{"id": "w2", "d": tomorrow, "entries": []}]},
              base_rev=rev, base_wid=state["_wid"])
    assert cw.get_undo_status(store, tmp_path, today=today)["status"] == "blockedByLoggedWorkout"
    with pytest.raises(cw.CoachConflictError) as exc:
        cw.undo_coach_batch(store, backup, tmp_path, token_id=token, today=today, timezone="UTC")
    assert exc.value.code == "undo-blocked-logged"


def test_coach_web_module_is_english_only():
    source = Path(cw.__file__).read_text(encoding="utf-8")
    assert not re.search(r"[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]", source)


def test_fallback_model_failover_on_429_503_and_never_on_401(tmp_path):
    models_called: list[str] = []
    max_tokens_seen: list[int] = []

    def handler(req: httpx.Request) -> httpx.Response:
        body = json.loads(req.content)
        m = body["model"]
        models_called.append(m)
        max_tokens_seen.append(body["max_tokens"])
        if m == "gemini-4-hydrogen":
            return httpx.Response(429, json={"error": {"code": 429, "message": "daily free-tier limit exceeded"}})
        return _ok_completion(content="OK", tokens=(12, 3))

    svc = ai.AIService(tmp_path, client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    masked = svc.save_config(
        base_url="https://generativelanguage.googleapis.com/v1beta/openai",
        model="gemini-4-hydrogen",
        fallback_model="gemini-flash-lite-latest",
        api_key=SAVED_KEY,
    )
    assert masked["model"] == "gemini-4-hydrogen"
    assert masked["fallbackModel"] == "gemini-flash-lite-latest"

    res = asyncio.run(svc.test_connection())
    assert res["ok"] is True
    assert res["model"] == "gemini-flash-lite-latest"
    assert models_called == ["gemini-4-hydrogen", "gemini-flash-lite-latest"]
    assert max_tokens_seen == [ai.TEST_CONNECTION_MAX_TOKENS, ai.TEST_CONNECTION_MAX_TOKENS]
    assert ai.TEST_CONNECTION_MAX_TOKENS == 64

    # Usage log records the fallback model that actually served the completion.
    logged = [json.loads(x) for x in svc.usage_file.read_text().splitlines()]
    assert logged[-1]["model"] == "gemini-flash-lite-latest"
    assert logged[-1]["total_tokens"] == 15

    # Saving without fallback_model preserves it on the same origin; setting fallback == model clears it.
    assert svc.save_config(daily_token_cap=300_000)["fallbackModel"] == "gemini-flash-lite-latest"
    assert svc.save_config(fallback_model="gemini-4-hydrogen")["fallbackModel"] == ""
    svc.save_config(fallback_model="gemini-flash-lite-latest")

    # Upstream 401/403 authentication errors never fall back to a second request.
    auth_calls: list[str] = []

    def auth_fail(req: httpx.Request) -> httpx.Response:
        auth_calls.append(json.loads(req.content)["model"])
        return httpx.Response(401, text="bad key")

    svc.client = httpx.AsyncClient(transport=httpx.MockTransport(auth_fail))
    with pytest.raises(ai.AIUpstreamAuthError):
        asyncio.run(svc.test_connection())
    assert auth_calls == ["gemini-4-hydrogen"]
