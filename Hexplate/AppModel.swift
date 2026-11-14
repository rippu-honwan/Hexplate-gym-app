import Foundation
import HexplateCore
import Observation

/// The app's state: the loaded document and what the import screen needs.
@MainActor
@Observable
final class AppModel {
    private let store = StateStore(directory: URL.applicationSupportDirectory.appending(path: "Hexplate"))

    private(set) var document: StateDocument?
    var errorMessage: String?

    init() {
        document = store.load()
    }

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
            document = new
        } catch {
            errorMessage = "The data could not be saved. Nothing was changed. \(error.localizedDescription)"
        }
    }
}
