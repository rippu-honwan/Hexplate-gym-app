import SwiftUI

@main
struct HexplateApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ImportView()
                .environment(model)
        }
    }
}
