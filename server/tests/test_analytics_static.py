"""The /analytics React build: served read-only from dashboard/dist, only on this Mac."""
import pytest
from fastapi.testclient import TestClient

from hexserver.app import create_app


@pytest.fixture
def dist(tmp_path, monkeypatch):
    d = tmp_path / "dist"
    (d / "assets").mkdir(parents=True)
    (d / "index.html").write_text('<!doctype html><div id="root"></div><script src="./assets/app.js"></script>')
    (d / "assets" / "app.js").write_text("console.log('hexplate')")
    (tmp_path / "secret.txt").write_text("outside the build")
    monkeypatch.setenv("HEXPLATE_ANALYTICS", str(d))
    return d


@pytest.fixture
def app(tmp_path, dist):
    return create_app(tmp_path / "data")


def test_serves_the_build_and_falls_back_to_the_shell(app):
    c = TestClient(app)
    r = c.get("/analytics", follow_redirects=False)
    assert r.status_code in (307, 308) and r.headers["location"] == "/analytics/"
    r = c.get("/analytics/")
    assert r.status_code == 200 and "text/html" in r.headers["content-type"] and 'id="root"' in r.text
    r = c.get("/analytics/assets/app.js")
    assert r.status_code == 200 and "javascript" in r.headers["content-type"] and "hexplate" in r.text
    assert 'id="root"' in c.get("/analytics/sessions").text            # SPA fallback
    assert c.get("/analytics/assets/missing.js").status_code == 404     # a missing file is not the shell


def test_never_serves_outside_the_build(app):
    c = TestClient(app)
    for path in ("/analytics/%2e%2e/secret.txt", "/analytics/..%2fsecret.txt"):
        r = c.get(path)
        assert "outside the build" not in r.text


def test_only_on_this_mac(app):
    remote = TestClient(app, client=("100.64.0.22", 50001))
    assert remote.get("/analytics/").status_code == 403
    assert remote.get("/analytics/assets/app.js").status_code == 403
    assert remote.get("/api/health").status_code == 200   # the phone's API is unaffected


def test_existing_pages_still_answer(app):
    c = TestClient(app)
    for path in ("/", "/history", "/settings", "/api/health"):
        assert c.get(path).status_code == 200, path


def test_missing_build_is_a_clear_404(tmp_path, monkeypatch):
    monkeypatch.setenv("HEXPLATE_ANALYTICS", str(tmp_path / "nowhere"))
    r = TestClient(create_app(tmp_path / "data")).get("/analytics/")
    assert r.status_code == 404 and "npm run build" in r.text
