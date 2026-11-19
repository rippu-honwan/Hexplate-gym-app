import json
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

from hexserver import webhooks
from hexserver.webhooks import Webhooks, detect_events, envelope, event_data, sample_data, signature

GOLDEN = json.loads((Path(__file__).parent / "fixtures/webhook-golden.json").read_text())


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda c: c["name"])
def test_events_match_opengym(case):
    """Same events and payloads as openGym's api/integrations/events.js (scripts/webhook-golden.mjs)."""
    got = [{"type": e["type"], "entity": e["entity"], "at": e["at"], "data": event_data(e, case["next"])}
           for e in detect_events(case["prev"], case["next"], GOLDEN["now"])]
    assert json.loads(json.dumps(got)) == case["events"]


def test_envelope_test_data_and_signature_match_opengym():
    for t, want in GOLDEN["test"].items():
        assert sample_data(t, GOLDEN["now"]) == want
    assert envelope("d1", "workout.finished", {"a": 1}, GOLDEN["now"], test=True) == GOLDEN["envelope"]
    s = GOLDEN["signature"]
    assert signature(s["secret"], s["body"], s["ts"]) == s["header"]


@pytest.fixture
def receiver():
    """A local HTTP receiver: answers `status`, keeps what it got."""
    got, status = [], [200]

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            got.append((dict(self.headers), self.rfile.read(int(self.headers["Content-Length"])).decode()))
            self.send_response(status[0])
            self.end_headers()

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_port}/hook", got, status
    srv.shutdown()


def test_a_finished_workout_reaches_the_webhook_signed(phone, receiver, monkeypatch):
    url, got, _ = receiver
    hooks = phone.app.state.webhooks
    wid, secret = hooks.add(url, "", ["workout.finished", "weighin.logged"])
    with pytest.raises(ValueError):
        hooks.add("ftp://x", "", ["workout.finished"])
    with pytest.raises(ValueError):
        hooks.add(url, "", [])
    now = time.time() * 1000
    w = {"id": "new", "d": time.strftime("%Y-%m-%d"), "start": now - 3600e3, "end": now, "prs": ["0025"],
         "entries": [{"id": "0025", "sets": [{"w": 60, "r": 8, "done": True}]}]}
    assert phone.put("/api/data", json={"state": {"unit": "kg", "workouts": []}}).status_code == 200
    assert phone.put("/api/data", json={"state": {"unit": "kg", "workouts": [w]}, "baseRev": 1}).status_code == 200
    for _ in range(50):
        if got:
            break
        time.sleep(0.05)
    assert len(got) == 1   # workout.pr is not one it asked for
    headers, body = got[0]
    assert headers["X-Hexplate-Event"] == "workout.finished"
    t = headers["X-Hexplate-Signature"].split(",")[0][2:]
    assert headers["X-Hexplate-Signature"] == signature(secret, body, int(t))
    assert json.loads(body)["data"]["workout"]["totals"] == {"exercises": 1, "sets": 1, "reps": 8, "volume": 480}
    assert hooks.all()[0]["last_ok"] is True


def test_test_event_pause_and_failures(phone, receiver, monkeypatch):
    url, got, status = receiver
    hooks = phone.app.state.webhooks
    wid, _ = hooks.add(url, "Home Assistant", ["workout.finished"])
    assert hooks.send_test(wid)[0] and json.loads(got[0][1])["test"] is True
    status[0] = 404
    ok, msg = hooks.send_test(wid)
    assert not ok and "404" in msg and hooks.all()[0]["last_ok"] is False
    status[0] = 503
    monkeypatch.setattr(webhooks, "RETRY_AFTER", (0, 0))
    hooks._send(wid, url, "s", envelope("d", "workout.finished", {}, 0))
    assert len(got) == 5   # two tests, then three tries of a busy receiver
    hooks.pause(wid, True)
    assert hooks.dispatch({}, {"workouts": [{"id": "x", "d": time.strftime("%Y-%m-%d"), "end": time.time() * 1000}]}) == []
    hooks.remove(wid)
    assert hooks.all() == []
