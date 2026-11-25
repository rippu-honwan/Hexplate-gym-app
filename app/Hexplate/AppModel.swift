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
    /// The year "Your year" shows full screen (WrappedStory), nil when closed.
    var wrappedYear: Int?
    enum GymSegment: String {
        case plan, programmes, exercises
    }

    /// The tab on screen.
    var tab = "today"
    /// Active segment inside the Gym tab.
    var gymSegment: GymSegment = .plan
    /// Incremented by Gym deep links so GymView pops its NavigationStack even if gymSegment did not change.
    var gymResetToken = 0
    /// Presents the Body weight entry sheet on the Profile tab.
    var presentWeightSheet = false
    /// Set when opengym://weigh-in arrived while a RootView fullScreenCover was open; promoted in cover onDismiss.
    var pendingCoverWeighIn = false
    /// Consumed by ProfileView once no modal sheet is open (dismissing Settings/Import/LogPast first if needed).
    var weighInRequested = false
    /// True while a sheet owned by NutritionView is presented; cleared ONLY in the sheet's `onDismiss`
    /// so ProfileView waits for dismissal animation completion before presenting `WeightEntry`.
    var nutritionSheetOpen = false
    /// True while a sheet owned by HomeView is presented; cleared ONLY in the sheet's `onDismiss`
    /// so ProfileView waits for dismissal animation completion before presenting `WeightEntry`.
    var homeSheetOpen = false
    /// MyGym: Start set pressed on the phone, and the set the watch says it records.
    var watchStart: WatchSet?
    var watchDone: WatchSet?
    var watchRecording: WatchSet?

    /// The watch's active calories so far for the running workout (its id), from Apple Health.
    var watchKcal: (wid: String, kcal: Double)?

    struct WatchSet: Equatable {
        let entryIdx: Int
        let setIdx: Int
        let at: Double
    }

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
        let isAIClone: Bool
        let cloneOf: String?
    }

    private func parseRoutine(_ v: JSONValue) -> Routine? {
        guard let r = v.object, let id = r["id"]?.stringValue else { return nil }
        return Routine(
            id: id,
            name: r["name"]?.stringValue ?? "",
            symbol: Glyph.symbol(r["emoji"]?.stringValue),
            slots: (r["ex"]?.arrayValue ?? []).compactMap(\.object),
            isAIClone: RoutineOps.isAIClone(r),
            cloneOf: r["cloneOf"]?.stringValue
        )
    }

    /// User-visible routines only (ephemeral `aiClone` routines are hidden from lists/pickers).
    var routines: [Routine] {
        (root["routines"]?.arrayValue ?? []).compactMap(parseRoutine).filter { !$0.isAIClone }
    }

    /// Looks up any routine by ID, including ephemeral `aiClone` routines pinned in `dayPlan`.
    func routine(_ id: String) -> Routine? {
        (root["routines"]?.arrayValue ?? []).first { $0.object?["id"]?.stringValue == id }.flatMap(parseRoutine)
    }

    // MARK: Writing

    /// A profile that has nothing in it yet.
    // ponytail: only the keys Hexplate reads; the Capacitor app's freshState() has every default.
    private static let empty = try! StateDocument(data: Data(
        #"{"unit":"kg","workouts":[],"routines":[],"week":{},"dayPlan":{},"bodyweight":[],"measurements":[],"customEx":[]}"#.utf8))

    /// Every change to the profile goes through here: stamped for sync, saved, then shown.
    // ponytail: rebuilds the whole history after each change; narrow it when a profile is large
    // enough for an edit to feel slow.
    /// Removes a saved workout from the history for good (sheets.jsx deleteWorkout).
    func deleteWorkout(id: String) {
        change { s in s["workouts"] = .array((s["workouts"]?.arrayValue ?? []).filter { $0.object?["id"]?.stringValue != id }) }
    }

    /// Inserts or updates a meal locally and enqueues its HealthKit write outbox op.
    func upsertMeal(_ meal: Nutrition.Meal) {
        change { _ = Nutrition.upsertMeal(&$0, meal) }
        if let stamped = Nutrition.meal(root, id: meal.id) {
            HealthService.shared.enqueueMealUpsert(stamped, root: root)
        }
    }

    /// Tombstones a meal locally and enqueues its HealthKit delete outbox op (local meal photos
    /// remain on disk until safe orphan GC after tombstone retention).
    func deleteMeal(id: String) {
        change { _ = Nutrition.deleteMeal(&$0, id: id) }
        if let ts = root["meals"]?.object?[id]?.object?["_ts"]?.numberValue, ts > 0 {
            HealthService.shared.enqueueMealDelete(mealId: id, ts: ts, root: root)
        }
    }

    /// Saves nutrition goal overrides (or `{}` on reset so whole-key LWW propagates across devices).
    func setNutritionGoals(_ goals: Nutrition.Goals) {
        change { Nutrition.setGoals(&$0, goals) }
    }

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
        // Before the screens read the names (Settings → Units & language → English exercise names).
        ExerciseNames.style = ExerciseNames.style(language: Theme.language, profile: new?.root ?? [:])
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
                day: date.map { String(Calendar.current.component(.day, from: $0)) } ?? "?",
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

    static func sets(_ n: Int) -> String { n == 1 ? String(localized: "1 set") : String(localized: "\(n) sets") }

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

    /// The server's copy taken as this device's own, stamps and all (not a change made here), with
    /// the workout running here kept (ServerSync).
    func takeServerCopy(_ server: [String: JSONValue]) {
        var s = server
        s["active"] = root["active"]
        do {
            let doc = try StateDocument(data: JSONEncoder().encode(JSONValue.object(s)))
            try store.save(doc)
            load(doc)
        } catch {
            errorMessage = "The server's copy could not be saved. Nothing was changed. \(error.localizedDescription)"
        }
    }

    /// Adopts a merged document from `HexMerge.merge` without restamping merged entries (except
    /// Gyms-derived inventory deltas when a remote device switched `activeEquipId`), keeping the
    /// running local workout (`active`).
    ///
    /// Deliberate departure from openGym's post-merge full restamping: preserves entry-level `_ts`,
    /// `edited`, and `deleted` stamps untouched so cross-device HealthKit sync versions and meal
    /// LWW stamps never inflate on merge, and never enqueues local HealthKit write-outbox items.
    func takeMergedCopy(_ merged: [String: JSONValue]) throws {
        var s = merged
        s["active"] = root["active"]
        do {
            var doc = try StateDocument(root: s)
            // Runs Gyms.sync(prev: s) so a remote `activeEquipId` change updates top-level
            // inventories and stamps only Gyms-derived deltas; strict no-op otherwise.
            doc.change { _ in }
            try store.save(doc)
            load(doc)
        } catch {
            errorMessage = "The merged copy could not be saved. Nothing was changed. \(error.localizedDescription)"
            throw error
        }
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
