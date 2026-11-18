"""python -m hexserver serve | pair | import <paths> | mcp"""
import argparse
import json
import os
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


if __name__ == "__main__":
    main()
