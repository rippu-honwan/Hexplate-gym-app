#!/bin/sh
# Runs the Hexplate server in the background on this Mac, from login on, restarted if it stops
# (a per-user LaunchAgent, no admin rights).
#   server/launchd.sh install     write the agent and start it
#   server/launchd.sh uninstall   stop it and remove the agent
# Logs: server/data/server.log. Needs the venv (see README.md).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
LABEL=app.hexplate.server
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
case "$1" in
install)
  [ -x "$DIR/.venv/bin/python" ] || { echo "no venv: see server/README.md" >&2; exit 1; }
  mkdir -p "$DIR/data" "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$DIR/.venv/bin/python</string><string>-m</string><string>hexserver</string><string>serve</string>
  </array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/data/server.log</string>
  <key>StandardErrorPath</key><string>$DIR/data/server.log</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "running: http://127.0.0.1:8765 (dashboard), http://$(scutil --get LocalHostName).local:8765 (phone)"
  ;;
uninstall)
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "stopped and removed"
  ;;
*) echo "usage: $0 install | uninstall" >&2; exit 2 ;;
esac
