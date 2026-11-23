"""python -m hexserver serve | pair | import <paths> | mcp | sign | set-signing"""
import argparse
import json
import os
import sys
from pathlib import Path

from .app import create_app


def main():
    p = argparse.ArgumentParser(prog="hexserver")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="run the server (reachable from the phone on your Wi-Fi)")
    s.add_argument("--host", default="0.0.0.0")
    s.add_argument("--port", type=int, default=int(os.environ.get("HEXPLATE_PORT", 8765)))
    sub.add_parser("pair", help="print a one-time pairing code for the phone (5 minutes)")
    i = sub.add_parser("import", help="bring in JSON backups (each the next revision) and folders of motion CSVs")
    i.add_argument("paths", type=Path, nargs="+")
    sub.add_parser("mcp", help="the read-only MCP server for an AI assistant (stdio)")
    sg = sub.add_parser("sign", help="refresh Apple ID signing on this Mac and reinstall on paired iPhone")
    sg.add_argument("--json", action="store_true", dest="as_json", help="print result as JSON")
    ss = sub.add_parser("set-signing", help="record synced signing metadata or clear stale signing error")
    ss.add_argument("--at", type=float)
    ss.add_argument("--expires", type=float)
    ss.add_argument("--device")
    ss.add_argument("--error")
    ss.add_argument("--clear-error", action="store_true")
    ss.add_argument("--stdin", action="store_true", help="read JSON payload {at, expires, device, error} from stdin")
    a = p.parse_args()

    if a.cmd == "mcp":   # opens the database read-only, so it never creates or changes anything
        from .mcp_server import build
        build(Path(os.environ.get("HEXPLATE_DATA", Path(__file__).resolve().parents[1] / "data"))).run("stdio")
        return

    app = create_app()
    store = app.state.store
    if a.cmd == "serve":
        import uvicorn
        uvicorn.run(app, host=a.host, port=a.port)
    elif a.cmd == "pair":
        print(store.new_pair_code())
    elif a.cmd == "import":
        for path in a.paths:
            if path.is_dir():
                files = sorted(path.glob("*.csv"))
                ok = sum(store.save_motion(f.name, f.read_text(), f.stat().st_mtime) for f in files)
                print(f"{path.name}: {ok} of {len(files)} motion files")
            else:
                saved = store.put(json.loads(path.read_text()))
                print(f"{path.name}: rev {saved['_rev']}, {len(saved.get('workouts') or [])} workouts")
    elif a.cmd == "sign":
        ok, err = app.state.signing.refresh_sync()
        st = app.state.signing.status()
        if a.as_json:
            print(json.dumps({"ok": ok, "error": err or None, "at": st["at"], "expires": st["expires"], "device": st["device"]}))
        elif ok:
            print(f"Refreshed signing for {st['device'] or 'iPhone'} (expires={st['expires']})")
        else:
            print(err or "Signing refresh failed.", file=sys.stderr)
        if not ok:
            raise SystemExit(1)
    elif a.cmd == "set-signing":
        payload = json.load(sys.stdin) if a.stdin else {}
        at = payload.get("at") if "at" in payload else a.at
        expires = payload.get("expires") if "expires" in payload else a.expires
        device = payload.get("device") if "device" in payload else a.device
        error = None if a.clear_error else (payload.get("error") if "error" in payload else a.error)
        st = app.state.signing.record_result(at=at, expires=expires, device=device, error=error)
        print(json.dumps({"ok": True, "at": st["at"], "expires": st["expires"], "device": st["device"], "error": st["error"]}))


if __name__ == "__main__":
    main()
