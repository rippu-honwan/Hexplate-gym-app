import Foundation
import JavaScriptCore

/// The openGym merge (frontend/src/lib/sync-merge.js mergeStates, sync-changes.js countChanges),
/// run as it is in JavaScriptCore from the bundle app/scripts/bundle-sync.sh writes
/// (Resources/sync.js). A wrong merge overwrites the server's copy, so Hexplate runs the exact
/// code every other openGym client runs; MergeGoldenTests checks the bundle against the JS.
///
/// ponytail: the JS bundled instead of ported (1300 lines, dozens of edge cases); a Swift port
/// is worth it only if the bundle's size or speed starts to matter.
public enum SyncMerge {
    public typealias Object = [String: JSONValue]

    public enum Failure: Error { case noBundle, script(String) }

    /// Both copies' entries kept, the newer copy deciding the rest (mergeStates(local, server)).
    /// Internal so external callers go through `HexMerge.merge`, which isolates Hexplate-only keys.
    static func merge(_ local: Object, _ server: Object) throws -> Object {
        let out = try call("merge", local, server)
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: Data(out.toString().utf8)) else { throw Failure.script("not an object") }
        return o
    }

    /// How many workouts, weigh-ins, routines and custom exercises `s` added, changed or removed
    /// compared with `since`, plus one when anything else changed (countChanges).
    /// Internal so external callers go through `HexMerge.changes`.
    static func changes(_ s: Object, since: Object) throws -> Int {
        Int(try call("changes", s, since).toInt32())
    }

    // Intentionally constructs a fresh JSContext per call (never a static JSContext) to keep
    // execution isolated and Swift 6 concurrency-safe.
    static func call(_ name: String, _ a: Object, _ b: Object) throws -> JSValue {
        guard let url = Bundle.module.url(forResource: "sync", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let ctx = JSContext() else { throw Failure.noBundle }
        var error: String?
        ctx.exceptionHandler = { _, e in error = e?.toString() }
        ctx.evaluateScript(source)
        // Sorted keys: countChanges hashes the JSON text, so both copies need one key order.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = { (o: Object) in String(decoding: try encoder.encode(JSONValue.object(o)), as: UTF8.self) }
        let fn = ctx.objectForKeyedSubscript("hexSync")?.objectForKeyedSubscript(name)
        let out = fn?.call(withArguments: [try text(a), try text(b)])
        if let error { throw Failure.script(error) }
        guard let out, !out.isUndefined else { throw Failure.script("no result") }
        return out
    }
}

/// What a sync does with the server's copy (frontend/src/store/useStore.js pullState), decided
/// from the revision this device last synced (`base`) and what the server holds now.
public enum SyncPlan: String, Sendable {
    case upToDate, push, adopt, merge

    /// The revision and write id of the server copy this device last held, and the local `_ts` then.
    public struct Base: Codable, Equatable, Sendable {
        public var rev: Int
        public var wid: String?
        public var ts: Double
        public init(rev: Int, wid: String?, ts: Double) { self.rev = rev; self.wid = wid; self.ts = ts }
    }

    /// `server` nil: the server has no document yet. A first sync always merges (the store's
    /// owed-copy path), so nothing on either side is pushed over.
    public static func decide(base: Base?, localTs: Double, rev: Int, server: [String: JSONValue]?) -> SyncPlan {
        guard let server else { return .push }
        guard let base else { return .merge }
        let wid = server["_wid"]?.stringValue
        let moved = rev != base.rev || (base.wid != nil && wid != nil && wid != base.wid)
        let changed = localTs > base.ts
        if !moved { return changed ? .push : .upToDate }
        let wids = server["_wids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let descends = base.wid == nil || wid == nil || wid == base.wid || wids.contains(base.wid!)
        return descends && !changed ? .adopt : .merge
    }
}
