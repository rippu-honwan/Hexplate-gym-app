import HexplateCore
import SwiftUI

@main
struct HexplateApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                // One accent everywhere, switches included (their default is green).
                .tint(Color.accentColor)
                .environment(model)
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
            Tab("History", systemImage: "clock.arrow.circlepath") { HistoryView() }
        }
        .alert("Something went wrong", isPresented: .init(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
