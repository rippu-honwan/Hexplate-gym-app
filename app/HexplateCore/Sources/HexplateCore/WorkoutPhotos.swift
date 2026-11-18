import Foundation

/// The photos and videos of a logged workout (workout-media.js, media-refs.js). The record holds
/// MediaRefs `{kind, hash, mime, size, width, height, at}`; the bytes live in a local store.
/// Each change stamps the record, as any edit of a saved workout does.
public enum WorkoutPhotos {
    public typealias Object = [String: JSONValue]
    public static let max = 6

    static let mimes: [String: String] = ["image/jpeg": "image", "image/png": "image", "image/webp": "image", "image/gif": "gif",
                                          "video/mp4": "video", "video/quicktime": "video", "video/webm": "video"]
    public static func ext(_ mime: String) -> String {
        ["image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif", "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm"][mime] ?? "bin"
    }

    /// A well-formed ref, or nil (media-refs.js normalizeMediaRef, without posters and codecs).
    public static func normalize(_ v: JSONValue?) -> Object? {
        guard let r = v?.object, let mime = r["mime"]?.stringValue, let kind = mimes[mime], r["kind"]?.stringValue == kind,
              let hash = r["hash"]?.stringValue, hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        func int(_ k: String, _ hi: Double) -> Double? {
            guard case .number(let d)? = r[k], d == d.rounded(), d >= 1, d <= hi else { return nil }
            return d
        }
        guard let size = int("size", 200 * 1024 * 1024), let w = int("width", 16384), let h = int("height", 16384) else { return nil }
        var out: Object = ["kind": .string(kind), "hash": .string(hash), "mime": .string(mime), "size": .number(size), "width": .number(w), "height": .number(h)]
        if let at = r["at"]?.numberValue { out["at"] = .number(at) }
        return out
    }

    /// What a workout shows: well-formed refs, each file once, at most `max`.
    public static func of(_ w: Object?) -> [Object] {
        var seen = Set<String>(), out: [Object] = []
        for v in w?["media"]?.arrayValue ?? [] {
            guard let m = normalize(v), let h = m["hash"]?.stringValue, seen.insert(h).inserted else { continue }
            out.append(m)
            if out.count >= max { break }
        }
        return out
    }

    public enum Added: Equatable { case added, gone, invalid, dup, full }

    /// Puts `ref` on the end of the saved workout `key`. The list is written as stored, never as read.
    public static func add(_ list: inout [JSONValue], key: String, _ ref: Object, now: Double) -> Added {
        guard let i = list.firstIndex(where: { $0.object.map(WorkoutEdit.key) == key }), var rec = list[i].object else { return .gone }
        guard let m = normalize(.object(ref)) else { return .invalid }
        let raw = rec["media"]?.arrayValue ?? []
        if raw.contains(where: { $0.object?["hash"] == m["hash"] }) { return .dup }
        if of(rec).count >= max { return .full }
        rec["media"] = .array(raw + [.object(m)])
        rec["_ts"] = .number(now)
        list[i] = .object(rec)
        return .added
    }

    /// Takes the file `hash` off the saved workout `key`. Whether anything changed.
    @discardableResult
    public static func remove(_ list: inout [JSONValue], key: String, hash: String, now: Double) -> Bool {
        guard let i = list.firstIndex(where: { $0.object.map(WorkoutEdit.key) == key }), var rec = list[i].object else { return false }
        let raw = rec["media"]?.arrayValue ?? []
        let left = raw.filter { $0.object?["hash"]?.stringValue != hash }
        if left.count == raw.count { return false }
        rec["media"] = left.isEmpty ? nil : .array(left)
        rec["_ts"] = .number(now)
        list[i] = .object(rec)
        return true
    }

    /// The replaced workout's media after the new one's own (sync-merge.js mergeWorkoutMedia).
    static func merge(into w: inout Object, from old: Object) {
        let mine = w["media"]?.arrayValue ?? []
        var seen = Set(mine.compactMap { $0.object?["hash"]?.stringValue })
        let extra = (old["media"]?.arrayValue ?? []).filter { v in v.object?["hash"]?.stringValue.map { seen.insert($0).inserted } ?? false }
        if !extra.isEmpty { w["media"] = .array(mine + extra) }
    }
}
