import Foundation

/// Whole feature areas switched on and off (openGym lib/modules.js). `modules = {id: bool}` holds
/// only the choices made: a missing key is on. Off hides a module's screens; nothing is deleted.
public enum Modules {
    /// The modules Hexplate has screens for, in openGym's order. Form videos, the gym check-in, the
    /// Coach, integrations and seasonal themes are openGym-only, and the watch is always on here.
    public static let ids = ["effort", "plates", "strength", "body", "health", "motivation"]

    public static func isOn(_ s: [String: JSONValue], _ id: String) -> Bool {
        s["modules"]?.object?[id] != .bool(false)
    }

    /// `s` with one module switched.
    public static func set(_ s: inout [String: JSONValue], _ id: String, _ on: Bool) {
        var m = s["modules"]?.object ?? [:]
        m[id] = .bool(on)
        s["modules"] = .object(m)
    }
}
