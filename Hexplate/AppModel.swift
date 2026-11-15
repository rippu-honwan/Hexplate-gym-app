import Foundation
import HexplateCore
import Observation

/// The app's state: the loaded document and what the screens show of it.
@MainActor
@Observable
final class AppModel {
    private let store = StateStore(directory: URL.applicationSupportDirectory.appending(path: "Hexplate"))

    private(set) var document: StateDocument?
    private(set) var history: History?
    /// The History list: one section per month, newest first.
    private(set) var months: [Month] = []
    var errorMessage: String?

    struct Month: Identifiable {
        let id: String        // "2026-11"
        let title: String     // "November 2026"
        var items: [Item]
    }

    /// One workout as the History list shows it, worked out once.
    struct Item: Identifiable {
        let id: String
        let workout: Workout
        let weekday: String   // "SAT"
        let day: String       // "14"
        let dateSpoken: String
        let metrics: [String]
    }

    /// The device's day, refreshed when the app comes to the front.
    var today = Day.today()
    /// The live workout screen is up (it can be minimised while the session runs).
    var showWorkout = false

    init() {
        load(store.load())
    }

    // MARK: Reading

    var root: [String: JSONValue] { document?.root ?? [:] }
    var catalog: ExerciseCatalog { history?.catalog ?? .builtIn }
    var settings: ProfileSettings { history?.settings ?? ProfileSettings([:]) }

    /// A routine as the plan screens show it; `slots` are its planned exercises as stored.
    struct Routine: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let slots: [[String: JSONValue]]
    }

    var routines: [Routine] {
        (root["routines"]?.arrayValue ?? []).compactMap { v in
            guard let r = v.object, let id = r["id"]?.stringValue else { return nil }
            return Routine(
                id: id,
                name: r["name"]?.stringValue ?? "",
                symbol: Glyph.symbol(r["emoji"]?.stringValue),
                slots: (r["ex"]?.arrayValue ?? []).compactMap(\.object)
            )
        }
    }

    func routine(_ id: String) -> Routine? { routines.first { $0.id == id } }

    // MARK: Writing

    /// A profile that has nothing in it yet.
    // ponytail: only the keys Hexplate reads; the Capacitor app's freshState() has every default.
    private static let empty = try! StateDocument(data: Data(
        #"{"unit":"kg","workouts":[],"routines":[],"week":{},"dayPlan":{},"bodyweight":[],"measurements":[],"customEx":[]}"#.utf8))

    /// Every change to the profile goes through here: stamped for sync, saved, then shown.
    // ponytail: rebuilds the whole history after each change; narrow it when a profile is large
    // enough for an edit to feel slow.
    /// One automatic copy of the document a day (Application Support/Hexplate/backups).
    func backupIfDue() { try? store.autoBackup(today: today) }

    func change(_ mutate: (inout [String: JSONValue]) -> Void) {
        var doc = document ?? Self.empty
        doc.change(mutate)
        guard doc != document else { return }
        do {
            try store.save(doc)
            load(doc)
        } catch {
            errorMessage = "The change could not be saved. \(error.localizedDescription)"
        }
    }

    /// Changes one routine in place.
    func changeRoutine(_ id: String, _ mutate: (inout [String: JSONValue]) -> Void) {
        change { s in
            guard var list = s["routines"]?.arrayValue,
                  let i = list.firstIndex(where: { $0.object?["id"] == .string(id) }), var r = list[i].object else { return }
            mutate(&r)
            list[i] = .object(r)
            s["routines"] = .array(list)
        }
    }

    var now: Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    private func load(_ new: StateDocument?) {
        document = new
        history = new.map { History(document: $0) }
        months = []
        guard let history else { return }
        for w in history.workouts {
            let date = Day.date(w.date)
            let item = Item(
                id: w.id,
                workout: w,
                weekday: date?.formatted(.dateTime.weekday(.abbreviated).locale(Theme.locale)).uppercased() ?? "",
                day: date?.formatted(.dateTime.day().locale(Theme.locale)) ?? "?",
                dateSpoken: date?.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Theme.locale)) ?? w.date,
                metrics: [history.durationText(w), Self.sets(history.setsDone(w)), history.volumeText(w)].compactMap { $0 }
            )
            let key = String(w.date.prefix(7))
            if months.last?.id == key {
                months[months.count - 1].items.append(item)
            } else {
                let title = date?.formatted(.dateTime.month(.wide).year().locale(Theme.locale)) ?? key
                months.append(Month(id: key, title: title, items: [item]))
            }
        }
    }

    static func sets(_ n: Int) -> String { n == 1 ? "1 set" : "\(n) sets" }

    func workout(id: String) -> Workout? { history?.workouts.first { $0.id == id } }

    /// The Capacitor app's state file is still in this app's Documents folder.
    var hasLegacyData: Bool { LegacyState.load(documents: .documentsDirectory) != nil }

    func importFile(_ url: URL) {
        // A file picked outside the app's own folders needs this access window to be readable.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            adopt(try StateDocument(data: try Data(contentsOf: url)))
        } catch let error as StateDocument.ReadError {
            errorMessage = switch error {
            case .notJSON: "This file is not valid JSON. Pick the file from \"Export backup (JSON)\"."
            case .notAnObject, .missingWorkouts: "This JSON file is not an openGym backup."
            }
        } catch {
            errorMessage = "The file could not be read. \(error.localizedDescription)"
        }
    }

    func importLegacy() {
        guard let legacy = LegacyState.load(documents: .documentsDirectory) else {
            errorMessage = "No data from the previous app was found."
            return
        }
        adopt(legacy)
    }

    private func adopt(_ new: StateDocument) {
        do {
            try store.replace(with: new)
            load(new)
        } catch {
            errorMessage = "The data could not be saved. Nothing was changed. \(error.localizedDescription)"
        }
    }
}
