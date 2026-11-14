import Foundation

/// Hexplate's own copy of the state document, in a folder it owns.
///
/// Same scheme as the Capacitor app (frontend/src/lib/mobile.js nativeSave / nativeLoad): the
/// document is written whole to a second file and then moved over the first, so a write cut short
/// never leaves half a file where the last good copy was.
public struct StateStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    var main: URL { directory.appending(path: "state.json") }
    var next: URL { directory.appending(path: "state.next.json") }
    static let previousName = "state.bak.json"

    public func load() -> StateDocument? { Self.read(main: main, next: next) }

    public func save(_ document: StateDocument) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try document.data().write(to: next)
        if fm.fileExists(atPath: main.path) {
            // Atomic swap; the copy it replaces is kept as state.bak.json.
            try? fm.removeItem(at: directory.appending(path: Self.previousName))
            _ = try fm.replaceItemAt(main, withItemAt: next, backupItemName: Self.previousName, options: .withoutDeletingBackupItem)
        } else {
            try fm.moveItem(at: next, to: main)
        }
    }

    /// Replaces everything with `document` (an import). The data it replaces is first copied to
    /// `backups/`, and that copy's location is returned.
    @discardableResult
    public func replace(with document: StateDocument) throws -> URL? {
        let fm = FileManager.default
        var backup: URL?
        if let current = load() {
            let folder = directory.appending(path: "backups")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "pre-import-\(Int(Date().timeIntervalSince1970 * 1000)).json")
            try current.data().write(to: url)
            backup = url
        }
        try save(document)
        return backup
    }

    /// Whichever of the two files parses and is the later one (`_ts`) is the copy; a leftover
    /// `next` from an interrupted move only wins when it is newer than `main`.
    static func read(main: URL, next: URL) -> StateDocument? {
        let read = { (url: URL) in (try? Data(contentsOf: url)).flatMap { try? StateDocument(data: $0) } }
        let mainDoc = read(main)
        if let nextDoc = read(next), mainDoc == nil || nextDoc.timestamp > mainDoc!.timestamp { return nextDoc }
        return mainDoc
    }
}

/// The state file the Capacitor app left in the app's Documents folder. Read only: there is no
/// code path here that writes, moves or deletes it.
public enum LegacyState {
    public static func load(documents: URL) -> StateDocument? {
        StateStore.read(
            main: documents.appending(path: "opengym-state.json"),
            next: documents.appending(path: "opengym-state.next.json")
        )
    }
}
