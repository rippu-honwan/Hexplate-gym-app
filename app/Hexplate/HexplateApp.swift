import HexplateCore
import UIKit
import SwiftUI

@main
struct HexplateApp: App {
    @State private var model = AppModel()
    @State private var timer = RestTimer()
    @AppStorage("appearance") private var appearance = "system"
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
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onChange(of: phase) {
                    if phase == .active { model.today = Day.today(); WatchBridge.shared.drain(); LiveActivitySync.drain(model, timer); ServerSync.shared.run(model); ReminderSync.sync(model) }
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
                    ReminderSync.sync(model)
                    LiveActivitySync.start(model: model, timer: timer)
                    ServerSync.shared.start(model)
                }
                // The watch follows every change of the document and of the rest timer.
                .onChange(of: model.root) { WatchBridge.shared.send(); WidgetSync.write(model); LiveActivitySync.update(model, timer); ServerSync.shared.changed(model); ReminderSync.sync(model) }
                .onChange(of: model.today) { WidgetSync.write(model); ReminderSync.sync(model) }
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
