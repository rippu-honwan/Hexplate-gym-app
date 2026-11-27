"""Localhost-only web dashboard hosting, security guard, and export downloads.

The phone's sync routes (`/api/*`) stay reachable on the local network or Tailscale Serve; every
other route is guarded to loopback clients, loopback `Host` headers (DNS-rebinding protection),
and same-origin CSRF checks on mutating methods.

The UI is the React build compiled on a Mac into `dashboard/dist/` (or `$HEXPLATE_ANALYTICS`) and
served read-only at root `/`, backed by `/analytics/api/*` and the `/data/*` download endpoints.
"""
import csv
import datetime as dt
import io
import os
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, RedirectResponse, Response

from . import analytics_api
from . import stats as S
from .ai import origin_of
from .i18n import LANG

_ALLOWED_HOSTS = frozenset({"127.0.0.1", "localhost", "::1", "testserver"})
_ALL_METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
_NO_STORE = {"Cache-Control": "no-store"}


def _host_allowed(raw_host: str | None) -> bool:
    """Allows only local loopback Host headers (plus TestClient's `testserver`) to block DNS rebinding."""
    if not raw_host:
        return False
    host = raw_host.strip().lower()
    if not host or "/" in host or "@" in host or " " in host:
        return False
    if host.startswith("["):
        end = host.find("]")
        if end < 0:
            return False
        hostname = host[1:end]
        rest = host[end + 1 :]
        if rest and not (rest.startswith(":") and rest[1:].isdigit()):
            return False
    else:
        hostname, sep, port = host.partition(":")
        if sep and not port.isdigit():
            return False
    return hostname in _ALLOWED_HOSTS


def _origin_matches_host(origin: str | None, scheme: str, raw_host: str) -> bool:
    """Checks that an HTTP `Origin` matches `(scheme, raw_host)` via `ai.origin_of`,
    rejecting `null`, userinfo, mismatched ports, or any path/query/fragment."""
    if not origin:
        return False
    text = origin.strip()
    if not text or text.lower() == "null":
        return False
    parsed = urlsplit(text)
    if parsed.path or parsed.query or parsed.fragment:
        return False
    got = origin_of(text)
    expected = origin_of(f"{scheme}://{raw_host}")
    return got is not None and got == expected


def install(app, store):
    @app.middleware("http")
    async def guard(req: Request, call_next):
        # ponytail: remote IP enforcement behind Tailscale Serve relies on uvicorn's default
        # proxy_headers=True and FORWARDED_ALLOW_IPS=127.0.0.1,::1 (never run with
        # --forwarded-allow-ips='*' or --no-proxy-headers).
        if not req.url.path.startswith("/api/"):
            if req.client and req.client.host not in ("127.0.0.1", "::1", "testclient"):
                return PlainTextResponse("The dashboard only opens on this Mac.", status_code=403)
            raw_host = req.headers.get("host") or req.url.netloc
            if not _host_allowed(raw_host):
                return PlainTextResponse("Refused: invalid Host header.", status_code=403)
            if req.method not in ("GET", "HEAD", "OPTIONS"):
                site = req.headers.get("sec-fetch-site")
                origin = req.headers.get("origin")
                if site:
                    same = site in ("same-origin", "none") and (
                        not origin or _origin_matches_host(origin, req.url.scheme, raw_host)
                    )
                else:
                    same = _origin_matches_host(origin, req.url.scheme, raw_host)
                if not same:
                    return PlainTextResponse("Refused: this request did not come from the dashboard.", status_code=403)
            # Your choice in Settings, else the browser's first language.
            lang = store.setting("lang") or ("zh" if req.headers.get("accept-language", "").lower().startswith("zh") else "en")
            LANG.set(lang)
        return await call_next(req)

    def doc():
        return store.current()[1] or {}

    def download(state, name):
        if state is None:
            return PlainTextResponse("No such version.", status_code=404, headers=_NO_STORE)
        return JSONResponse(state, headers={"Content-Disposition": f'attachment; filename="{name}"', **_NO_STORE})

    # MARK: Data exports (linked directly by SyncDataView; localhost-only via guard)

    @app.get("/data/latest.json")
    async def latest():
        return download(store.current()[1], f"hexplate-{dt.date.today()}.json")

    @app.get("/data/rev/{rev}.json")
    async def version(rev: int):
        return download(store.document(rev), f"hexplate-rev{rev}.json")

    @app.get("/data/sets.csv")
    async def sets_csv():
        state = doc()
        buf = io.StringIO()
        out = csv.writer(buf)
        out.writerow(["date", "workout", "exercise_id", "exercise", "set", "warmup", "done", "weight", "reps", "rir", "hr_avg", "unit"])
        u = S.unit(state)
        for w in reversed(S.workouts(state)):
            for e in S.entries(w):
                for i, x in enumerate(S.sets(e), 1):
                    hr = x.get("hr") if isinstance(x.get("hr"), dict) else {}
                    out.writerow([
                        S.day(w),
                        w.get("name") or "",
                        e.get("id"),
                        S.name_of(e.get("id"), state),
                        i,
                        int(S.is_warmup(x)),
                        int(x.get("done") is True),
                        x.get("w", ""),
                        x.get("r", ""),
                        x.get("rir", ""),
                        hr.get("avg", ""),
                        u,
                    ])
        return Response(
            buf.getvalue(),
            media_type="text/csv",
            headers={"Content-Disposition": f'attachment; filename="hexplate-sets-{dt.date.today()}.csv"', **_NO_STORE},
        )

    # MARK: Dashboard JSON API (registered BEFORE API 404 isolation, redirects, and root SPA)

    analytics_api.install(app, store)

    # MARK: Structural API 404 isolation (unknown API paths never fall through to the SPA shell)

    @app.api_route("/api/{path:path}", methods=_ALL_METHODS, include_in_schema=False)
    async def unknown_phone_api(path: str):
        raise HTTPException(status_code=404)

    @app.api_route("/analytics/api", methods=_ALL_METHODS, include_in_schema=False)
    @app.api_route("/analytics/api/{path:path}", methods=_ALL_METHODS, include_in_schema=False)
    async def unknown_analytics_api(path: str = ""):
        return JSONResponse({"error": "Not found"}, status_code=404)

    # MARK: Legacy /analytics redirects (non-api paths only)

    @app.get("/analytics", include_in_schema=False)
    @app.get("/analytics/{path:path}", include_in_schema=False)
    async def legacy_analytics_redirect(path: str = ""):
        return RedirectResponse("/", status_code=307)

    # MARK: Root React SPA (compiled on the Mac into dashboard/dist: this machine runs no Node)

    analytics = Path(os.environ.get("HEXPLATE_ANALYTICS") or Path(__file__).resolve().parents[2] / "dashboard" / "dist").resolve()
    store_root = store.folder.resolve()
    analytics_isolated = not (
        analytics == store_root
        or analytics.is_relative_to(store_root)
        or store_root.is_relative_to(analytics)
    )

    def _serve_spa(path: str):
        # Defense-in-depth prefix backstop alongside the structural isolation routes above.
        if path == "api" or path.startswith("api/") or path == "analytics/api" or path.startswith("analytics/api/"):
            return JSONResponse({"error": "Not found"}, status_code=404)
        if not analytics_isolated:
            return PlainTextResponse("Refused: analytics directory overlaps the server data directory.", status_code=403)
        index = analytics / "index.html"
        if not index.is_file():
            return PlainTextResponse(
                "The dashboard is not built. Run `npm run build` in dashboard/. To pair a phone without it: `python -m hexserver pair`.",
                status_code=404,
            )

        def _index_response() -> FileResponse:
            return FileResponse(index, headers={"Cache-Control": "no-cache"})

        if not path or path == "index.html":
            return _index_response()
        candidate = Path(path)
        if candidate.is_absolute() or ".." in candidate.parts:
            return PlainTextResponse("Not found", status_code=404)
        raw = analytics / candidate
        f = raw.resolve()
        if f == index:
            return _index_response()
        if f.is_relative_to(analytics) and f.is_file():
            return FileResponse(f)
        # ponytail: the app keeps its view in memory (no client router), so only the root is linked;
        # anything without a file extension falls back to the app shell, a missing file or escaped symlink is a 404.
        if raw.is_symlink() or candidate.suffix:
            return PlainTextResponse("Not found", status_code=404)
        return _index_response()

    @app.get("/", include_in_schema=False)
    async def spa_root():
        return _serve_spa("")

    @app.get("/{path:path}", include_in_schema=False)
    async def spa_path(path: str):
        return _serve_spa(path)
