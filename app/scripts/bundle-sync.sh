#!/bin/bash
# Bundles the openGym merge (frontend/src/lib/sync-merge.js, sync-changes.js) into one script that
# HexplateCore runs in JavaScriptCore (SyncMerge.swift). Rerun after the JS changes; golden.sh
# runs it too. Needs `npm install` in frontend/ (Node 22).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/app/HexplateCore/Sources/HexplateCore/Resources/sync.js"
cd "$ROOT/frontend"
OUT="$OUT" ENTRY="$ROOT/app/scripts/sync-entry.mjs" node -e "
require('rolldown').build({ input: process.env.ENTRY, platform: 'neutral', logLevel: 'silent',
  transform: { define: { 'import.meta.env': '{}' } },
  output: { file: process.env.OUT, format: 'iife', minify: true } })
  .catch(e => { console.error(e.message); process.exit(1) })"
echo "wrote $OUT"
