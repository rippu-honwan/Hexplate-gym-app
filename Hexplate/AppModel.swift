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

    init() {
        load(store.load())
    }

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
