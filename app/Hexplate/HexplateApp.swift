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
                .environment(HealthService.shared)
                .environment(\.locale, Theme.locale)
                // The day may have changed while the app was in the background.
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onChange(of: phase) {
                    if phase == .active {
                        model.today = Day.today()
                        WatchBridge.shared.drain()
                        LiveActivitySync.drain(model, timer)
                        ServerSync.shared.run(model)
                        ReminderSync.sync(model)
                        WrappedNotify.sync(model)
                        if model.document != nil && UIApplication.shared.isProtectedDataAvailable {
                            MealPhotos.pruneOrphans(keeping: Nutrition.referencedPhotoIds(model.root))
                        }
                        HealthService.shared.scheduleForegroundSync(model: model)
                    }
                    if phase == .background {
                        model.backupIfDue()
                        // What is waiting goes to the server before iOS suspends the app.
                        let id = UIApplication.shared.beginBackgroundTask()
                        Task { await ServerSync.shared.run(model)?.value; UIApplication.shared.endBackgroundTask(id) }
                    }
                }
                .task {
                    model.backupIfDue()
                    model.change { RoutineOps.pruneExpiredClones(&$0, today: model.today) }
                    KeyboardDismisser.install()
                    WatchBridge.shared.start(model: model, timer: timer)
                    WidgetSync.write(model)
                    ReminderSync.sync(model); WrappedNotify.sync(model)
                    keepAwake()
                    followProfile()
                    GymReminder.shared.register()
                    LiveActivitySync.start(model: model, timer: timer)
                    ServerSync.shared.start(model)
                    HealthService.shared.startObservingUnlock(model: model)
                    await HealthService.shared.refreshAuthStatus()
                    await HealthService.shared.flushOutboxIfAllowed(root: model.root)
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
            Tab("Gym", systemImage: "dumbbell", value: "gym") { GymView() }
            Tab("Nutrition", systemImage: "fork.knife", value: "nutrition") { NutritionView() }
            Tab("Today", systemImage: "sun.max", value: "today") { HomeView() }
            Tab("Analysis", systemImage: "waveform.path.ecg", value: "analysis") { AnalysisView() }
            Tab("Profile", systemImage: "person.crop.circle", value: "profile") { ProfileView() }
        }
        .modifier(WorkoutAccessory())
        .fullScreenCover(isPresented: $model.showWorkout, onDismiss: flushPendingCoverWeighIn) { WorkoutView().tint(Theme.accent) }
        .fullScreenCover(item: $model.wrappedYear, onDismiss: flushPendingCoverWeighIn) { WrappedStory(year: $0).tint(Theme.accent) }
        .alert("Something went wrong", isPresented: .init(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func flushPendingCoverWeighIn() {
        if model.pendingCoverWeighIn && !model.showWorkout && model.wrappedYear == nil {
            model.pendingCoverWeighIn = false
            model.weighInRequested = true
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
