import HexplateCore
import SwiftUI

@main
struct HexplateApp: App {
    @State private var model = AppModel()
    @State private var timer = RestTimer()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                // One accent everywhere, switches included (their default is green).
                .tint(Color.accentColor)
                .environment(model)
                .environment(timer)
                .environment(\.locale, Theme.locale)
                // The day may have changed while the app was in the background.
                .onChange(of: phase) { if phase == .active { model.today = Day.today() } }
        }
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Tab("Today", systemImage: "house.fill") { HomeView() }
            Tab("Plan", systemImage: "calendar") { PlanView() }
            Tab("Exercises", systemImage: "dumbbell") { LibraryView() }
            Tab("History", systemImage: "clock.arrow.circlepath") { HistoryView() }
            Tab("Stats", systemImage: "chart.xyaxis.line") { StatsView() }
        }
        .modifier(WorkoutAccessory())
        .fullScreenCover(isPresented: $model.showWorkout) { WorkoutView().tint(Color.accentColor) }
        .alert("Something went wrong", isPresented: .init(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// While a session runs, a bar above the tabs brings it back (iOS 26.1 and later).
private struct WorkoutAccessory: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: model.active != nil) {
                Button { model.showWorkout = true } label: {
                    HStack {
                        Image(systemName: "figure.strengthtraining.traditional").foregroundStyle(.tint)
                        Text(model.active?["name"]?.stringValue ?? "Workout").lineLimit(1)
                        Spacer()
                        if let start = model.active?["start"]?.numberValue {
                            Text(Date(timeIntervalSince1970: start / 1000), style: .timer).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Resume workout")
            }
        } else {
            content
        }
    }
}
