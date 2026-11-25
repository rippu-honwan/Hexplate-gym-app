import Foundation

/// Hexplate's state-document merge wrapper around the golden-tested openGym `SyncMerge`.
///
/// Strips Hexplate-only CRDT maps (`meals`) before calling bundled `sync.js`, merges them in Swift
/// with per-entry LWW + inline deletion tombstones, reattaches them, and bumps top-level `_ts`
/// without inflating entry-level stamps.
///
/// Compatibility note: legacy openGym web/Capacitor clients do not understand Hexplate keys
/// (`meals`, `nutritionGoals`, `aiClone` metadata) and must not sync against a document carrying
/// them.
public enum HexMerge {
    public typealias Object = [String: JSONValue]

    /// Top-level keys stripped before calling `SyncMerge` and merged directly in Swift.
    public static let isolatedKeys: Set<String> = ["meals"]

    /// Tombstones older than 90 days are pruned on merge.
    /// ponytail: known GC ceiling — a device offline for more than 90 days can resurrect meals
    /// deleted while it was away.
    public static let mealTombstoneTTLMs: Double = 90 * 86_400_000

    /// Merges `local` and `server` while preserving openGym merge semantics for shared keys and
    /// applying Swift per-entry LWW for `meals`.
    public static func merge(
        _ local: Object,
        _ server: Object,
        now: Double = (Date().timeIntervalSince1970 * 1000).rounded()
    ) throws -> Object {
        let localMeals = local["meals"]?.object
        let serverMeals = server["meals"]?.object
        let localReset = local["resetAt"]?.num ?? 0
        let serverReset = server["resetAt"]?.num ?? 0
        let localResetIds = local["resetIds"]?.object
        let serverResetIds = server["resetIds"]?.object

        let strippedLocal = stripIsolated(local)
        let strippedServer = stripIsolated(server)
        var merged = try SyncMerge.merge(strippedLocal, strippedServer)

        if localMeals != nil || serverMeals != nil {
            let mergedMeals = mergeMeals(
                local: localMeals ?? [:],
                server: serverMeals ?? [:],
                localReset: localReset,
                serverReset: serverReset,
                localResetIds: localResetIds,
                serverResetIds: serverResetIds,
                now: now
            )
            merged["meals"] = .object(mergedMeals)
        }

        let inputFloor = max(local["_ts"]?.num ?? 0, server["_ts"]?.num ?? 0)
        finalize(&merged, floor: inputFloor)
        return merged
    }

    /// Counts changes between `since` and `s`, combining openGym's `SyncMerge.changes` with
    /// per-entry `meals` diffs.
    public static func changes(_ s: Object, since: Object) throws -> Int {
        let base = try SyncMerge.changes(stripIsolated(s), since: stripIsolated(since))
        let curMeals = s["meals"]?.object ?? [:]
        let oldMeals = since["meals"]?.object ?? [:]
        let mealDiffs = Set(curMeals.keys).union(oldMeals.keys).filter { curMeals[$0] != oldMeals[$0] }.count
        return base + mealDiffs
    }

    /// Sets top-level `_ts` strictly above every stamp in the merged copy without modifying any
    /// entry-level `_ts`, `edited`, or `deleted` stamp.
    ///
    /// The `+ 1` is load-bearing: `sync.js` sets `_ts = max(local._ts, server._ts)`, which on a
    /// non-descending merge with no local edits can equal `base.ts`. If the immediate `PUT` then
    /// fails, the next sync would see `!moved && !changed`, classify as `.upToDate`, and drop the
    /// merged entries.
    public static func finalize(_ merged: inout Object, floor: Double = 0) {
        let highest = max(floor, SyncStamps.highestStamp(merged), HexStamps.highestMealTs(merged))
        merged["_ts"] = .number(highest + 1)
    }

    // MARK: Internals

    private static func stripIsolated(_ s: Object) -> Object {
        var copy = s
        for k in isolatedKeys { copy[k] = nil }
        return copy
    }

    private static func mergeMeals(
        local: Object,
        server: Object,
        localReset: Double,
        serverReset: Double,
        localResetIds: Object?,
        serverResetIds: Object?,
        now: Double
    ) -> Object {
        var a = local
        var b = server
        // Mirror both branches of sync.js `kn(e, t, resetIds)`:
        // - When the winning side carries a `resetIds` object, drop only the listed meal IDs
        //   (no time filter) so a selective reset never wipes unrelated meals.
        // - Only when `resetIds` is absent does the reset fall back to `_ts <= resetAt`.
        if localReset > serverReset {
            b = applyReset(b, resetAt: localReset, resetIds: localResetIds)
        } else if serverReset > localReset {
            a = applyReset(a, resetAt: serverReset, resetIds: serverResetIds)
        }

        var out: Object = [:]
        for id in Set(a.keys).union(b.keys) {
            let winner: JSONValue
            switch (a[id], b[id]) {
            case let (lhs?, rhs?):
                winner = pickMeal(lhs, rhs)
            case let (lhs?, nil):
                winner = lhs
            case let (nil, rhs?):
                winner = rhs
            case (nil, nil):
                continue
            }
            if isPrunableTombstone(winner, now: now) { continue }
            out[id] = winner
        }
        return out
    }

    private static func applyReset(_ meals: Object, resetAt: Double, resetIds: Object?) -> Object {
        if let resetIds {
            let dropped = Set((resetIds["meals"]?.arrayValue ?? []).filter { $0 != .null }.map(SyncStamps.key))
            if dropped.isEmpty { return meals }
            return meals.filter { !dropped.contains($0.key) }
        }
        return meals.filter { _, value in (value.object?["_ts"]?.num ?? 0) > resetAt }
    }

    /// Commutative, order-independent LWW picker for a single meal ID.
    private static func pickMeal(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        let aTs = a.object?["_ts"]?.num ?? 0
        let bTs = b.object?["_ts"]?.num ?? 0
        if aTs != bTs { return aTs > bTs ? a : b }
        let aDel = a.object?["deleted"] == .bool(true)
        let bDel = b.object?["deleted"] == .bool(true)
        if aDel != bDel { return aDel ? a : b }
        return canonicalJSON(a) >= canonicalJSON(b) ? a : b
    }

    private static func isPrunableTombstone(_ v: JSONValue, now: Double) -> Bool {
        guard let o = v.object, o["deleted"] == .bool(true) else { return false }
        let ts = o["_ts"]?.num ?? 0
        return ts > 0 && (now - ts) > mealTombstoneTTLMs
    }

    private static func canonicalJSON(_ v: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(v) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Per-entry stamping for Hexplate-only CRDT maps (`meals`), running alongside `SyncStamps` inside
/// `StateDocument.change`.
public enum HexStamps {
    public typealias Object = [String: JSONValue]

    /// Latest `_ts` carried by any entry in `s["meals"]` (0 when absent).
    public static func highestMealTs(_ s: Object) -> Double {
        var highest = 0.0
        for value in s["meals"]?.object?.values ?? [:].values {
            highest = max(highest, abs(value.object?["_ts"]?.num ?? 0))
        }
        return highest
    }

    /// Stamps only meal entries added or changed between `prev` and `next` with `now`, preserves
    /// unchanged entries' `_ts`, and auto-tombstones removed live meals while allowing removal of
    /// already-tombstoned entries (for 90-day GC).
    static func stampMeals(prev: Object, next: inout Object, now: Double) {
        let prevMeals = prev["meals"]?.object ?? [:]
        let hadNextMeals = next["meals"] != nil
        var nextMeals = next["meals"]?.object ?? [:]
        guard !prevMeals.isEmpty || hadNextMeals else { return }

        var mutated = false

        for (id, value) in nextMeals {
            guard var entry = value.object else { continue }
            let old = prevMeals[id]?.object
            if let old, sameMealContent(old, entry) {
                if let oldTs = old["_ts"], oldTs != .null {
                    if entry["_ts"] != oldTs {
                        entry["_ts"] = oldTs
                        nextMeals[id] = .object(entry)
                        mutated = true
                    }
                } else if entry["_ts"] != nil {
                    entry["_ts"] = nil
                    nextMeals[id] = .object(entry)
                    mutated = true
                }
            } else {
                entry["_ts"] = .number(now)
                nextMeals[id] = .object(entry)
                mutated = true
            }
        }

        for (id, oldValue) in prevMeals where nextMeals[id] == nil {
            guard let oldObj = oldValue.object else { continue }
            // Only live meals are converted to inline tombstones; already-tombstoned entries can
            // be pruned cleanly.
            if oldObj["deleted"] != .bool(true) {
                nextMeals[id] = .object(["deleted": .bool(true), "_ts": .number(now)])
                mutated = true
            }
        }

        if mutated || hadNextMeals {
            next["meals"] = .object(nextMeals)
        }
    }

    private static func sameMealContent(_ a: Object, _ b: Object) -> Bool {
        a.filter { $0.key != "_ts" } == b.filter { $0.key != "_ts" }
    }
}
