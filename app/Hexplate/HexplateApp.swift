import HexplateCore
import UIKit
import SwiftUI

@main
struct HexplateApp: App {
    @State private var model = AppModel()
    @State private var timer = RestTimer()
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var phase

    init() {
        Theme.applyLanguage(Theme.language)
        // Made at launch: a gym region entered with the app closed relaunches it in the background.
        _ = GymReminder.shared
    }

    /// What follows the profile: exercise names (English names), the gym reminder's rules.
    private func followProfile() {
        ExerciseNames.style = ExerciseNames.style(language: Theme.language, profile: model.root)
        GymReminder.remember(model.root, today: model.today)
    }

    /// Settings → Keep screen awake: the screen stays on while a workout runs.
    private func keepAwake() {
        UIApplication.shared.isIdleTimerDisabled = model.active != nil && model.root["keepAwake"] != .bool(false)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // One accent everywhere, switches included (their default is green).
                .tint(Theme.accent)
                .environment(model)
                .environment(timer)
                .environment(\.locale, Theme.locale)
                // The day may have changed while the app was in the background.
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onChange(of: phase) {
                    if phase == .active { model.today = Day.today(); WatchBridge.shared.drain(); LiveActivitySync.drain(model, timer); ServerSync.shared.run(model); ReminderSync.sync(model); WrappedNotify.sync(model) }
                    if phase == .background {
                        model.backupIfDue()
                        // What is waiting goes to the server before iOS suspends the app.
                        let id = UIApplication.shared.beginBackgroundTask()
                        Task { await ServerSync.shared.run(model)?.value; UIApplication.shared.endBackgroundTask(id) }
                    }
                }
                .task {
                    model.backupIfDue()
                    KeyboardDismisser.install()
                    WatchBridge.shared.start(model: model, timer: timer)
                    WidgetSync.write(model)
                    ReminderSync.sync(model); WrappedNotify.sync(model)
                    keepAwake()
                    followProfile()
                    GymReminder.shared.register()
                    LiveActivitySync.start(model: model, timer: timer)
                    ServerSync.shared.start(model)
                }
                // The watch follows every change of the document and of the rest timer.
                .onChange(of: model.root) { keepAwake(); followProfile(); WatchBridge.shared.send(); WidgetSync.write(model); LiveActivitySync.update(model, timer); ServerSync.shared.changed(model); ReminderSync.sync(model); WrappedNotify.sync(model) }
                .onChange(of: model.today) { followProfile(); WidgetSync.write(model); ReminderSync.sync(model); WrappedNotify.sync(model) }
                .onOpenURL { WidgetSync.open($0, model) }
                .onChange(of: timer.end) { WatchBridge.shared.send(); LiveActivitySync.update(model, timer) }
        }
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Today", systemImage: "house.fill", value: "today") { HomeView() }
            Tab("Plan", systemImage: "calendar", value: "plan") { PlanView() }
            Tab("Exercises", systemImage: "dumbbell", value: "exercises") { LibraryView() }
            Tab("History", systemImage: "clock.arrow.circlepath", value: "history") { HistoryView() }
            Tab("Stats", systemImage: "chart.xyaxis.line", value: "stats") { StatsView() }
        }
        .modifier(WorkoutAccessory())
        .fullScreenCover(isPresented: $model.showWorkout) { WorkoutView().tint(Theme.accent) }
        .fullScreenCover(item: $model.wrappedYear) { WrappedStory(year: $0).tint(Theme.accent) }
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
