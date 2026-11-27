"""The root React dashboard build: served read-only from dashboard/dist, only on this Mac."""
import pytest
from fastapi.testclient import TestClient

from hexserver.app import create_app

SAME = {"Origin": "http://testserver", "Sec-Fetch-Site": "same-origin"}


@pytest.fixture
def dist(tmp_path, monkeypatch):
    d = tmp_path / "dist"
    (d / "assets").mkdir(parents=True)
    (d / "index.html").write_text('<!doctype html><div id="root"></div><script src="/assets/app.js"></script>')
    (d / "assets" / "app.js").write_text("console.log('hexplate')")
    secret = tmp_path / "secret.txt"
    secret.write_text("outside the build")
    (d / "leak.txt").symlink_to(secret)
    monkeypatch.setenv("HEXPLATE_ANALYTICS", str(d))
    return d


@pytest.fixture
def app(tmp_path, dist):
    return create_app(tmp_path / "data")


def test_serves_root_build_spa_fallback_and_legacy_analytics_redirects(app):
    c = TestClient(app)
    r = c.get("/")
    assert r.status_code == 200 and "text/html" in r.headers["content-type"] and 'id="root"' in r.text
    assert r.headers.get("cache-control") == "no-cache"

    r = c.get("/assets/app.js")
    assert r.status_code == 200 and "javascript" in r.headers["content-type"] and "hexplate" in r.text

    spa = c.get("/sessions")
    assert spa.status_code == 200 and 'id="root"' in spa.text and spa.headers.get("cache-control") == "no-cache"

    assert c.get("/assets/missing.js").status_code == 404  # a missing file is not the shell

    for legacy in ("/analytics", "/analytics/", "/analytics/sessions"):
        redir = c.get(legacy, follow_redirects=False)
        assert redir.status_code == 307 and redir.headers["location"] == "/", legacy


def test_never_serves_outside_the_build(app, tmp_path):
    c = TestClient(app)
    abs_target = f"/%2F{str(tmp_path).lstrip('/')}/secret.txt"
    for path in ("/%2e%2e/secret.txt", "/..%2fsecret.txt", abs_target, "/leak.txt"):
        r = c.get(path)
        assert r.status_code == 404, path
        assert "outside the build" not in r.text, path


def test_only_on_this_mac_and_api_isolation(app):
    remote = TestClient(app, client=("100.64.0.22", 50001))
    for path in ("/", "/assets/app.js", "/analytics/", "/data/latest.json", "/api"):
        assert remote.get(path).status_code == 403, path

    # Remote clients hitting unknown /api/* routes (including encoded traversal) get JSON 404, never SPA HTML/JS.
    for method in ("get", "post", "delete"):
        r = getattr(remote, method)("/api/does-not-exist")
        assert r.status_code == 404, method
        assert r.json() == {"detail": "Not Found"}, method
        assert 'id="root"' not in r.text, method

    for path in ("/api/%2e%2e/index.html", "/api/..%2fassets/app.js"):
        r = remote.get(path)
        assert r.status_code == 404, path
        assert r.json() == {"detail": "Not Found"}, path
        assert 'id="root"' not in r.text and "hexplate" not in r.text, path

    assert remote.get("/api/health").status_code == 200  # the phone's API is unaffected

    # Local clients hitting unknown /analytics/api* paths across methods get JSON 404, never redirect or SPA shell.
    local = TestClient(app)
    for path in ("/analytics/api", "/analytics/api/does-not-exist"):
        for method in ("get", "post", "delete"):
            hdrs = {} if method == "get" else SAME
            r = getattr(local, method)(path, headers=hdrs, follow_redirects=False)
            assert r.status_code == 404, (method, path)
            assert r.json() == {"error": "Not found"}, (method, path)
            assert 'id="root"' not in r.text, (method, path)


def test_missing_build_is_a_clear_404(tmp_path, monkeypatch):
    monkeypatch.setenv("HEXPLATE_ANALYTICS", str(tmp_path / "nowhere"))
    c = TestClient(create_app(tmp_path / "data"))
    r = c.get("/")
    assert r.status_code == 404
    assert "npm run build" in r.text
    assert "python -m hexserver pair" in r.text
    assert c.get("/api/health").status_code == 200
