"""python -m hexserver serve | pair | import <state.json>"""
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
    i = sub.add_parser("import", help="store an openGym / Hexplate JSON backup as the next revision")
    i.add_argument("file", type=Path)
    a = p.parse_args()

    app = create_app()
    store = app.state.store
    if a.cmd == "serve":
        import uvicorn
        uvicorn.run(app, host=a.host, port=a.port)
    elif a.cmd == "pair":
        print(store.new_pair_code())
    elif a.cmd == "import":
        saved = store.put(json.loads(a.file.read_text()))
        print(f"rev {saved['_rev']}: {len(saved.get('workouts') or [])} workouts")


if __name__ == "__main__":
    main()
