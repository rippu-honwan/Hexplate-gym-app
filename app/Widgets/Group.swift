import Foundation

/// The App Group the app and the widget extension share (the same one the Capacitor app used).
enum OpenGymGroup {
    static let id = "group.com.rippuhonwan.mygym"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}
