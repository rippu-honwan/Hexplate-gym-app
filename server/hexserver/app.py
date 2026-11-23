"""The HTTP API Hexplate's phone app talks to (app/Hexplate/ServerSync.swift).

The routes and answers are the ones openGym's server gives the phone (pair, me, data, data/rev,
motion), so the app syncs with this server unchanged. One user, on your own Mac.

ponytail: handlers are `async` with blocking SQLite calls inside, so requests run one at a time on
the event loop; for one person's phone and dashboard that is plenty, and it keeps the database
single-threaded.
"""
import os
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from . import dashboard
from .backup import Backup
from .signing import Signing
from .store import Conflict, Store
from .webhooks import Webhooks

USER = {"id": "me", "name": "Hexplate"}


def create_app(folder: Path | None = None) -> FastAPI:
    store = Store(folder or Path(os.environ.get("HEXPLATE_DATA", Path(__file__).resolve().parents[1] / "data")))
    app = FastAPI(title="Hexplate server", docs_url=None, redoc_url=None)
    app.state.store = store
    app.state.webhooks = webhooks = Webhooks(store.db)
    # A data folder given (the tests) keeps its backup beside it, never in your iCloud Drive.
    app.state.backup = backup = Backup(store, Path(folder) / "backup" if folder else None)
    app.state.signing = Signing(store, derived_dir=Path(folder) / "signing-build" if folder else None)

    def err(status, message, **extra):
        return JSONResponse({"error": message, **extra}, status_code=status)

    def signed_in(req: Request) -> bool:
        auth = req.headers.get("authorization", "")
        return auth.startswith("Bearer ") and store.token_ok(auth[7:].strip())

    async def body(req: Request):
        try:
            b = await req.json()
        except ValueError:
            return None
        return b if isinstance(b, dict) else None

    @app.get("/api/health")
    async def health():
        return {"ok": True}

    @app.post("/api/pair/redeem")
    async def redeem(req: Request):
        b = await body(req) or {}
        token = store.redeem(str(b.get("code") or ""))
        if not token:
            return err(400, "invalid or expired code", code="pair-invalid")
        return {"token": token, "user": USER}

    @app.get("/api/me")
    async def me(req: Request):
        # ponytail: tokens do not expire, so there is never a renewed one to hand back.
        return {"user": USER} if signed_in(req) else err(401, "not signed in")

    @app.get("/api/data")
    async def data(req: Request):
        if not signed_in(req):
            return err(401, "not signed in")
        rev, state = store.current()
        return {"state": state, "rev": rev}

    @app.get("/api/data/rev")
    async def data_rev(req: Request):
        if not signed_in(req):
            return err(401, "not signed in")
        rev, state = store.current()
        return {"rev": rev, **({"wid": state["_wid"]} if state and state.get("_wid") else {})}

    @app.put("/api/data")
    async def put_data(req: Request):
        if not signed_in(req):
            return err(401, "not signed in")
        b = await body(req)
        state = (b or {}).get("state")
        # The shapes openGym refuses: no document, nothing of the profile in it, lists that are not lists.
        if not isinstance(state, dict) or not any(k not in ("_rev", "_ts") for k in state):
            return err(400, "state required")
        if any(state.get(k) is not None and not isinstance(state.get(k), list) for k in ("workouts", "routines")):
            return err(400, "invalid state")
        base_rev = b.get("baseRev")
        _, prev = store.current()
        try:
            saved = store.put(state, base_rev if isinstance(base_rev, int) else None, b.get("baseWid"))
        except Conflict as c:
            return err(409, "conflict", rev=c.rev, state=c.state)
        webhooks.dispatch(prev, saved)   # what is new since the last copy, sent in the background
        backup.soon()
        return {"ok": True, "ts": saved.get("_ts"), "rev": saved["_rev"], "wid": saved["_wid"]}

    @app.put("/api/motion")
    async def motion(req: Request):
        if not signed_in(req):
            return err(401, "not signed in")
        b = await body(req) or {}
        name, csv = b.get("name"), b.get("csv")
        if not isinstance(name, str) or not isinstance(csv, str) or not store.save_motion(name, csv):
            return err(400, "bad motion file")
        # The phone deletes its copy only when this is true: the file is here and in the backup.
        return {"ok": True, "canDelete": backup.can_delete(name)}

    dashboard.install(app, store)
    return app
