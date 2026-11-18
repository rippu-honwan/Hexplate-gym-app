import Foundation

/// The settings in the document that change how a logged workout reads.
public struct ProfileSettings: Equatable, Sendable {
    /// "kg" or "lb".
    public let unit: String
    /// 1 or 2: how many decimals a weight is shown with (`wdec`).
    public let weightDecimals: Int
    public let countWarmups: Bool
    public let countBodyweight: Bool
    /// "kmh" or "mph".
    public let speedUnit: String

    public init(_ root: [String: JSONValue]) {
        unit = root["unit"] == .string("lb") ? "lb" : "kg"
        weightDecimals = root["wdec"] == .number(2) ? 2 : 1
        countWarmups = root["volumeWarmups"] == .bool(true)
        countBodyweight = root["volumeBodyweight"] == .bool(true)
        if case .string(let s) = root["speedUnit"], s == "mph" || s == "kmh" { speedUnit = s }
        else { speedUnit = unit == "lb" ? "mph" : "kmh" }
    }
}

/// The workout history of a document, ready for a screen: everything the History list and the
/// workout detail show, read once.
public struct History: Sendable {
    public let settings: ProfileSettings
    public let catalog: ExerciseCatalog
    public let weighIns: [WeighIn]
    /// Newest day first; within a day, the workout stored later comes first (views/History.jsx
    /// historyRows).
    public let workouts: [Workout]

    public init(document: StateDocument, catalog: ExerciseCatalog = .builtIn) {
        let root = document.root
        settings = ProfileSettings(root)
        let custom = (root["customEx"]?.arrayValue ?? []).compactMap { try? $0.decoded(as: Exercise.self) }
        self.catalog = catalog.adding(custom: custom)
        weighIns = (root["bodyweight"]?.arrayValue ?? []).compactMap { try? $0.decoded(as: WeighIn.self) }
        workouts = document.workouts().items.enumerated()
            .sorted { a, b in a.element.date != b.element.date ? a.element.date > b.element.date : a.offset > b.offset }
            .map(\.element)
    }

    public func setsDone(_ w: Workout) -> Int { WorkoutMath.setsDone(w) }

    public func volume(_ w: Workout) -> Double {
        WorkoutMath.volume(w, settings: settings, catalog: catalog, weighIns: weighIns)
    }

    /// "6,186.8 kg"
    public func volumeText(_ w: Workout) -> String {
        Format.number(volume(w), decimals: settings.weightDecimals) + " " + settings.unit
    }

    /// "1h 5m", nil when the session has no believable duration.
    public func durationText(_ w: Workout) -> String? {
        Format.duration(milliseconds: WorkoutMath.duration(w))
    }

    /// The exercise's name, or what the entry saved for one that no longer exists.
    public func name(of e: WorkoutEntry) -> String {
        catalog[e.exerciseId]?.displayName ?? e.savedName ?? e.exerciseId
    }

    /// The sets that were done, as the detail lists them.
    public func rows(of e: WorkoutEntry) -> [SetRow] {
        e.sets.filter(\.hasCompletedWork).map { s in
            SetRow(
                label: SetLabel.text(exerciseId: e.exerciseId, set: s, target: e.target, catalog: catalog, settings: settings),
                heartRate: SetLabel.heartRateValues(s).map { SetRow.HeartRate(avg: $0.avg, max: $0.max) },
                isWarmup: s.isWarmup
            )
        }
    }

    public struct SetRow: Equatable, Sendable {
        public struct HeartRate: Equatable, Sendable {
            public let avg: Int
            public let max: Int
        }
        public let label: String
        public let heartRate: HeartRate?
        public let isWarmup: Bool
    }

    /// Entries done as a superset stay together: adjacent entries sharing a group
    /// (history.js supersetUnits). Each unit is a run of entry indices.
    public func units(of w: Workout) -> [[Int]] {
        var units: [[Int]] = []
        for (i, e) in w.entries.enumerated() {
            if let g = e.supersetGroup, !g.isEmpty, let last = units.last?.last, w.entries[last].supersetGroup == g {
                units[units.count - 1].append(i)
            } else {
                units.append([i])
            }
        }
        return units
    }
}
