#!/bin/sh
# After each session (rep counter, Stage B): copy the phone's motion files and state into data/
# (git-ignored: motion data is personal data), then label and check them with motion_check.py.
# Needed until the app uploads them itself (Stage C). Run from the repo root, iPhone unlocked.
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp)
xcrun devicectl list devices --json-output "$tmp" >/dev/null
# The first paired physical iPhone (no device id kept in the repo).
dev=$(python3 -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw = d.get("hardwareProperties", {})
    if hw.get("deviceType") == "iPhone" and hw.get("reality") == "physical":
        print(d["identifier"]); break
' "$tmp")
rm -f "$tmp"
[ -n "$dev" ] || { echo "no iPhone found" >&2; exit 1; }
pull() { xcrun devicectl device copy from --device "$dev" --domain-type appDataContainer \
  --domain-identifier com.rippuhonwan.mygym --source "$1" --destination "$2" >/dev/null; }
mkdir -p data/motion-phone
pull Documents/motion data/motion-phone
pull "Library/Application Support/Hexplate/state.json" data/phone-state.json
echo "pulled $(ls data/motion-phone | wc -l | tr -d ' ') files"
# The server's copy (files the old app uploaded) is checked too, with the server's state.
set -- --state data/phone-state.json
for s in data/state-*.json; do [ -f "$s" ] && set -- "$@" --state "$s"; done
python3 analysis/motion_check.py "$@" data/motion-phone data/motion
