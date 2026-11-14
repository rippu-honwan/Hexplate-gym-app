import HexplateCore
import SwiftUI
import UniformTypeIdentifiers

/// Phase 2 screen: shows what is stored and imports an openGym backup.
struct ImportView: View {
    @Environment(AppModel.self) private var model

    private enum Source { case file, legacy }
    @State private var pending: Source?
    @State private var pickingFile = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section("Your data") {
                    if let summary = model.document?.summary {
                        LabeledContent("Workouts", value: summary.workoutCount.formatted())
                        LabeledContent("Routines", value: summary.routineCount.formatted())
                        if let first = summary.firstDate, let last = summary.lastDate {
                            LabeledContent("From", value: first)
                            LabeledContent("To", value: last)
                        }
                        if summary.unreadableWorkouts > 0 {
                            LabeledContent("Unreadable workouts", value: summary.unreadableWorkouts.formatted())
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("Nothing imported yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Import backup file", systemImage: "square.and.arrow.down") { start(.file) }
                    if model.hasLegacyData {
                        Button("Import from previous app", systemImage: "arrow.triangle.2.circlepath") { start(.legacy) }
                    }
                } footer: {
                    Text("Importing replaces everything in Hexplate. A copy of the current data is kept first. The previous app's data is only read, never changed.")
                }
            }
            .navigationTitle("Hexplate")
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Replace the data in Hexplate?", isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Replace", role: .destructive) { if let pending { run(pending) } }
        } message: {
            Text("A copy of the current data is kept in the app's backups folder.")
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): model.importFile(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("Import failed", isPresented: .init(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Asks first only when there is something to replace.
    private func start(_ source: Source) {
        if model.document == nil { run(source) } else { pending = source }
    }

    private func run(_ source: Source) {
        pending = nil
        switch source {
        case .file: pickingFile = true
        case .legacy: model.importLegacy()
        }
    }
}
