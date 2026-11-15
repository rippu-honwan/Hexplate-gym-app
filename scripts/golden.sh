#!/bin/bash
# Regenerates the golden file the Swift tests compare against, from the original JavaScript.
#   native/scripts/golden.sh [state.json] [golden.json]
# Defaults to the committed fixture. Needs `npm install` in frontend/ (Node 22).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$ROOT/native/HexplateCore/Tests/HexplateCoreTests/Fixtures"
export IN=${1:-$FIX/history-state.json}
export OUT=${2:-$FIX/history-golden.json}
export STAMP_IN="$FIX/stamp-cases.json" STAMP_OUT="$FIX/stamp-golden.json"
export SCHEDULE_IN="$FIX/schedule-cases.json" SCHEDULE_OUT="$FIX/schedule-golden.json"
export ROUTINE_IN="$FIX/routine-cases.json" ROUTINE_OUT="$FIX/routine-golden.json"
export SESSION_IN="$FIX/session-cases.json" SESSION_OUT="$FIX/session-golden.json"
export STATS_IN="$FIX/stats-cases.json" STATS_OUT="$FIX/stats-golden.json"
export RECOVERY_IN="$FIX/recovery-cases.json" RECOVERY_OUT="$FIX/recovery-golden.json"
export CSV_OUT="$FIX/history-golden.csv"
export WATCH_IN="$FIX/watch-cases.json" WATCH_OUT="$FIX/watch-golden.json"
export CATALOGUE_OUT="$ROOT/native/HexplateCore/Sources/HexplateCore/Resources/exercises.json"
mkdir -p "$(dirname "$CATALOGUE_OUT")"
cd "$ROOT/frontend"
npx vitest run --root . --globals --environment node --dir "$ROOT/native/scripts" "$ROOT/native/scripts/golden.test.mjs"
echo "wrote $OUT"
