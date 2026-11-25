import HexplateCore
import SwiftUI

/// The Profile tab: Settings, motivation cards, body weight, latest workout, and workout history.
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var settings = false
    @State private var importing = false
    @State private var logging = false
    @State private var deleting: AppModel.Item?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                if Modules.isOn(model.root, "motivation") {
                    WrappedHomeSection()
                    StreakPartySection()
                    ChallengesSection()
                }

                // Look & Home -> Body weight (S.showWeightCard, Body module): latest weigh-in and one-tap logging.
                if Modules.isOn(model.root, "body"), model.root["showWeightCard"] != .bool(false) {
                    Section {
                        let last = BodyData.weights(model.root).last
                        LabeledContent("Body weight") {
                            Text(last.map { "\(Format.number($0.weight)) \(model.settings.unit)" } ?? "–").monospacedDigit()
                        }
                        Button(last?.day == model.today ? "Change today’s weight" : "Log weight", systemImage: "scalemass") {
                            model.presentWeightSheet = true
                        }
                    }
                }

                if let latest = model.months.first?.items.first {
                    Section("Latest workout") {
                        NavigationLink(value: WorkoutLink(id: latest.id)) { WorkoutRow(item: latest) }
                    }
                }

                HistoryContent(deleting: $deleting, importing: $importing)
            }
            .navigationTitle("Profile")
            .workoutDestination()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Log a past workout", systemImage: "calendar.badge.plus") { logging = true }
                            .disabled(model.active != nil)
                        Button("Import data", systemImage: "square.and.arrow.down") { importing = true }
                    }
                }
            }
            .sheet(isPresented: $settings, onDismiss: drainWeighInRequest) { SettingsView() }
            .sheet(isPresented: $model.presentWeightSheet) { WeightEntry() }
            .sheet(isPresented: $importing, onDismiss: drainWeighInRequest) { ImportView() }
            .sheet(isPresented: $logging, onDismiss: {
                if model.isBackfill {
                    model.showWorkout = true
                } else {
                    drainWeighInRequest()
                }
            }) { LogPastWorkoutSheet() }
            .alert("Delete this workout?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { item in
                Button("Delete", role: .destructive) { model.deleteWorkout(id: item.id) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("\(item.workout.name ?? "This workout") is removed from your history for good.")
            }
            .onAppear(perform: drainWeighInRequest)
            .onChange(of: model.weighInRequested) { drainWeighInRequest() }
        }
    }

    private func drainWeighInRequest() {
        guard model.weighInRequested, !model.showWorkout, model.wrappedYear == nil else { return }
        if model.presentWeightSheet {
            model.weighInRequested = false
            return
        }
        if settings || importing || logging {
            settings = false
            importing = false
            logging = false
            return
        }
        model.weighInRequested = false
        model.presentWeightSheet = true
    }
}
