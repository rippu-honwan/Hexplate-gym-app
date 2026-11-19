#!/bin/bash
# Regenerates the golden file the Swift tests compare against, from the original JavaScript.
#   app/scripts/golden.sh [state.json] [golden.json]
# Defaults to the committed fixture. Reads the openGym JS: link its frontend/ into the repo root
# first (`ln -s <openGym checkout>/frontend frontend`, git-ignored) and run `npm install` there (Node 22).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$ROOT/app/HexplateCore/Tests/HexplateCoreTests/Fixtures"
export IN=${1:-$FIX/history-state.json}
export OUT=${2:-$FIX/history-golden.json}
export STAMP_IN="$FIX/stamp-cases.json" STAMP_OUT="$FIX/stamp-golden.json"
export SCHEDULE_IN="$FIX/schedule-cases.json" SCHEDULE_OUT="$FIX/schedule-golden.json"
export ROUTINE_IN="$FIX/routine-cases.json" ROUTINE_OUT="$FIX/routine-golden.json"
export SESSION_IN="$FIX/session-cases.json" SESSION_OUT="$FIX/session-golden.json"
export STATS_IN="$FIX/stats-cases.json" STATS_OUT="$FIX/stats-golden.json"
export RECOVERY_IN="$FIX/recovery-cases.json" RECOVERY_OUT="$FIX/recovery-golden.json"
export EDIT_IN="$FIX/edit-cases.json" EDIT_OUT="$FIX/edit-golden.json"
export WEDIT_IN="$FIX/workout-edit-cases.json" WEDIT_OUT="$FIX/workout-edit-golden.json"
export COPY_IN="$FIX/copy-cases.json" COPY_OUT="$FIX/copy-golden.json"
export BACKFILL_IN="$FIX/backfill-cases.json" BACKFILL_OUT="$FIX/backfill-golden.json"
export PROG_IN="$FIX/programme-cases.json" PROG_OUT="$FIX/programme-golden.json"
export WIDGET_IN="$FIX/widget-cases.json" WIDGET_OUT="$FIX/widget-golden.json"
export CSV_OUT="$FIX/history-golden.csv"
export WATCH_IN="$FIX/watch-cases.json" WATCH_OUT="$FIX/watch-golden.json"
export LIVE_IN="$FIX/live-cases.json" LIVE_OUT="$FIX/live-golden.json"
export MERGE_IN="$FIX/merge-cases.json" MERGE_OUT="$FIX/merge-golden.json"
export CSVR_IN="$FIX/csv-cases.json" CSVR_OUT="$FIX/csv-golden.json"
export CHAL_IN="$FIX/challenge-cases.json" CHAL_OUT="$FIX/challenge-golden.json"
export WRAP_IN="$FIX/wrapped-cases.json" WRAP_OUT="$FIX/wrapped-golden.json"
export REMIND_IN="$FIX/reminder-cases.json" REMIND_OUT="$FIX/reminder-golden.json"
export REPORT_IN="$FIX/report-cases.json" REPORT_OUT="$FIX/report-golden.json"
export TREND_IN="$FIX/trend-cases.json" TREND_OUT="$FIX/trend-golden.json"
export CATALOGUE_OUT="$ROOT/app/HexplateCore/Sources/HexplateCore/Resources/exercises.json"
mkdir -p "$(dirname "$CATALOGUE_OUT")"
"$ROOT/app/scripts/bundle-sync.sh"
cd "$ROOT/frontend"
npx vitest run --root . --globals --environment node --dir "$ROOT/app/scripts" "$ROOT/app/scripts/golden.test.mjs"
echo "wrote $OUT"
