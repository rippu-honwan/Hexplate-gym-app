import ActivityKit
import AppIntents
import Foundation
import UserNotifications

/*
 * The running workout's Live Activity: what it carries, and its buttons (Log set, and Next exercise
 * or Skip rest beside it), moved from frontend/ios/App/App/WorkoutActivity.swift. Compiled into the
 * app and the widget extension: the extension draws it (LiveActivityViews.swift), the app starts
 * and updates it (Hexplate/LiveActivitySync.swift) and runs the buttons' intents.
 *
 * The state is HexplateCore LiveActivity.state, field for field. Text only, no exercise media.
 * ponytail: no Stop auto (Hexplate has no auto-hold chain) and no paused clocks.
 */
struct WorkoutActivityAttributes: ActivityAttributes {
    struct Labels: Codable, Hashable {
        var done = String(localized: "Log set")
        var rest = String(localized: "Rest")
        var hold = String(localized: "Hold")
        var allDone = String(localized: "All sets done")
        var restOver = String(localized: "Rest is over")
        var nextExercise = String(localized: "Next exercise")
        var skipRest = String(localized: "Skip rest")
        var openApp = String(localized: "Open Hexplate for the next set")
    }

    /// One set as the activity shows it, with the rest that follows it.
    struct SetInfo: Codable, Hashable {
        var exId: String
        var entryIdx: Int
        var setIdx: Int
        var exName: String
        var setLine: String
        var target: String
        var restAfter: Int
        /// The first entry of its superset unit: Next exercise leaves this unit.
        var unit: Int?

        var unitKey: Int { unit ?? entryIdx }
    }

    struct ContentState: Codable, Hashable {
        var name: String
        /// The set to do now; nil once every set is ticked.
        var cur: SetInfo?
        /// The few sets after it, so Log set can move on while the app sleeps.
        var ahead: [SetInfo]
        /// A running rest's end, in milliseconds since 1970.
        var restEndsAt: Double?
        var restLeft: Double?
        var restTotal: Double?
        var done: Int
        var total: Int
        /// The first open set of the next few exercises, so Next exercise works while the app sleeps.
        var unitStarts: [SetInfo]?
        /// A hold counting down: its end in ms since 1970.
        var holdEndsAt: Double?
        var holdLeft: Double?
        var holdTotal: Double?
        var holdKind: String?

        var resting: Bool { restEndsAt != nil || restLeft != nil }
        var holding: Bool { holdEndsAt != nil || holdLeft != nil }

        var holdRange: ClosedRange<Date>? { Self.range(holdEndsAt, holdTotal) }
        var restRange: ClosedRange<Date>? { Self.range(restEndsAt, restTotal) }

        static func range(_ end: Double?, _ total: Double?) -> ClosedRange<Date>? {
            guard let end else { return nil }
            let until = Date(timeIntervalSince1970: end / 1000)
            return until.addingTimeInterval(-max(1, total ?? 1))...until
        }

        /// Where Next exercise goes: the first open set of the next exercise, or nil.
        var nextUnitStart: SetInfo? {
            guard let cur else { return nil }
            return (unitStarts ?? []).first { $0.unitKey != cur.unitKey }
        }

        /// The starts after the unit `set` is in, once the activity moved into it.
        func startsAfter(_ set: SetInfo?) -> [SetInfo]? {
            guard let starts = unitStarts else { return nil }
            guard let set else { return [] }
            guard let i = starts.firstIndex(where: { $0.unitKey == set.unitKey }) else { return starts }
            return Array(starts[(i + 1)...])
        }
    }

    var wid: String
    var start: Double?
    var accent = "#40C8E0"
    var ink = "#000000"
    var labels = Labels()
}

/**
 * The taps (Log set, Next exercise, Skip rest) the app has not applied yet, oldest first, in the
 * App Group. The intents add to it; LiveActivitySync applies them and takes them out.
 */
enum LiveActivityQueue {
    static let key = "liveActivityEvents"
    /// Set by the app: applies the queued taps and sends its own state. The intents wait for it,
    /// since iOS suspends the app as soon as an intent returns. Nil in the widget extension.
    nonisolated(unsafe) static var onEvent: (@Sendable () async -> Void)?
    private static let lock = NSLock()

    static func all() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    static func append(_ event: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var list = read()
        list.append(event)
        // A queue nobody drained for a long time keeps its newest taps.
        if list.count > 200 { list.removeFirst(list.count - 200) }
        write(list)
    }

    static func remove(ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        write(read().filter { !ids.contains(($0["id"] as? String) ?? "") })
    }

    private static func read() -> [[String: Any]] {
        guard let data = OpenGymGroup.defaults.data(forKey: key),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    private static func write(_ list: [[String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: list) { OpenGymGroup.defaults.set(data, forKey: key) }
    }
}

/// Log set. iOS runs it in the app, awake or not: the tap is queued for the app, and the activity
/// moves on to the next set and its rest right away. The app's own state, sent after, wins.
struct DoneSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Log set"
    static let isDiscoverable = false

    @Parameter(title: "Workout") var wid: String
    @Parameter(title: "Exercise") var exId: String
    @Parameter(title: "Entry") var entryIdx: Int
    @Parameter(title: "Set") var setIdx: Int

    init() {}

    init(wid: String, exId: String, entryIdx: Int, setIdx: Int) {
        self.wid = wid
        self.exId = exId
        self.entryIdx = entryIdx
        self.setIdx = setIdx
    }

    func perform() async throws -> some IntentResult {
        await LiveActivityTick.tick(wid: wid, exId: exId, entryIdx: entryIdx, setIdx: setIdx)
        return .result()
    }
}

/// Next exercise: on to the next exercise without logging anything.
struct NextExerciseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Next exercise"
    static let isDiscoverable = false

    @Parameter(title: "Workout") var wid: String
    @Parameter(title: "Entry") var entryIdx: Int

    init() {}

    init(wid: String, entryIdx: Int) {
        self.wid = wid
        self.entryIdx = entryIdx
    }

    func perform() async throws -> some IntentResult {
        await LiveActivityTick.nextExercise(wid: wid, entryIdx: entryIdx)
        return .result()
    }
}

/// Skip rest, the rest bar's Skip.
struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip rest"
    static let isDiscoverable = false

    @Parameter(title: "Workout") var wid: String

    init() {}

    init(wid: String) { self.wid = wid }

    func perform() async throws -> some IntentResult {
        await LiveActivityTick.skipRest(wid: wid)
        return .result()
    }
}

enum LiveActivityTick {
    /// RestTimer's notification id: the app's own rest-over alert and this one replace each other.
    static let restRequestId = "rest"

    static func activity(_ wid: String) -> Activity<WorkoutActivityAttributes>? {
        Activity<WorkoutActivityAttributes>.activities.first { $0.attributes.wid == wid }
    }

    static func stamp(_ now: Date) -> Double { (now.timeIntervalSince1970 * 1000).rounded() }

    static func tick(wid: String, exId: String, entryIdx: Int, setIdx: Int, now: Date = Date()) async {
        guard let activity = activity(wid) else { return }
        let state = activity.content.state
        // A button from a state already moved on (two quick taps): that set is ticked already.
        guard let cur = state.cur, cur.exId == exId, cur.entryIdx == entryIdx, cur.setIdx == setIdx else { return }
        LiveActivityQueue.append(["id": UUID().uuidString, "type": "setDone", "wid": wid, "exId": exId,
                                  "entryIdx": entryIdx, "setIdx": setIdx, "at": stamp(now)])
        var next = state
        next.cur = state.ahead.first
        next.ahead = Array(state.ahead.dropFirst())
        next.done = min(state.total, state.done + 1)
        next.unitStarts = state.startsAfter(next.cur)
        next.restLeft = nil
        next.holdEndsAt = nil
        next.holdLeft = nil
        next.holdTotal = nil
        next.holdKind = nil
        if cur.restAfter > 0, next.cur != nil {
            let end = now.addingTimeInterval(TimeInterval(cur.restAfter))
            next.restEndsAt = end.timeIntervalSince1970 * 1000
            next.restTotal = Double(cur.restAfter)
            bookRestOver(at: end, title: activity.attributes.labels.restOver)
        } else {
            next.restEndsAt = nil
            next.restTotal = nil
        }
        await activity.update(ActivityContent(state: next, staleDate: nil))
        await LiveActivityQueue.onEvent?()
    }

    /// Next exercise: the activity moves to the next exercise's first open set, nothing is ticked.
    static func nextExercise(wid: String, entryIdx: Int, now: Date = Date()) async {
        guard let activity = activity(wid) else { return }
        let state = activity.content.state
        guard let cur = state.cur, cur.entryIdx == entryIdx, let target = state.nextUnitStart else { return }
        LiveActivityQueue.append(["id": UUID().uuidString, "type": "next", "wid": wid, "fromEntryIdx": entryIdx, "at": stamp(now)])
        var next = state
        if let i = state.ahead.firstIndex(where: { $0.unitKey == target.unitKey }) {
            next.cur = state.ahead[i]
            next.ahead = Array(state.ahead[(i + 1)...])
        } else {
            next.cur = target
            next.ahead = []
        }
        next.unitStarts = state.startsAfter(next.cur)
        await activity.update(ActivityContent(state: next, staleDate: nil))
        await LiveActivityQueue.onEvent?()
    }

    /// Skip rest: the rest ends now, and so does its rest-over notification.
    static func skipRest(wid: String, now: Date = Date()) async {
        guard let activity = activity(wid) else { return }
        let state = activity.content.state
        guard state.resting else { return }
        LiveActivityQueue.append(["id": UUID().uuidString, "type": "restSkip", "wid": wid, "at": stamp(now)])
        var next = state
        next.restEndsAt = nil
        next.restLeft = nil
        next.restTotal = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [restRequestId])
        center.removeDeliveredNotifications(withIdentifiers: [restRequestId])
        await activity.update(ActivityContent(state: next, staleDate: nil))
        await LiveActivityQueue.onEvent?()
    }

    private static func bookRestOver(at: Date, title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(localized: "Next set.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: restRequestId, content: content, trigger: trigger))
    }
}
