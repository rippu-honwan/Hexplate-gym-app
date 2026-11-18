// Bundled by native/scripts/bundle-sync.sh into HexplateCore's sync.js: the openGym merge, run
// as it is inside JavaScriptCore (HexplateCore SyncMerge.swift).
import { mergeStates } from '../../frontend/src/lib/sync-merge.js'
import { countChanges, syncFingerprint } from '../../frontend/src/lib/sync-changes.js'
globalThis.hexSync = {
  merge: (a, b) => JSON.stringify(mergeStates(JSON.parse(a), JSON.parse(b))),
  changes: (a, b) => countChanges(JSON.parse(a), syncFingerprint(JSON.parse(b))),
}
