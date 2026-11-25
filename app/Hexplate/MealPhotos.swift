import Foundation
import UIKit

/// Device-local encrypted JPEG storage for meal photos (`Application Support/Hexplate/meal-photos/<photoId>.jpg`).
/// Raw image bytes are never stored in `state.json`.
enum MealPhotos {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Hexplate/meal-photos", directoryHint: .isDirectory)
    }

    static func isValidId(_ photoId: String) -> Bool {
        guard !photoId.isEmpty, photoId.count <= 64 else { return false }
        return photoId.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57) // 0-9
                || (s.value >= 65 && s.value <= 90) // A-Z
                || (s.value >= 97 && s.value <= 122) // a-z
                || s.value == 45 || s.value == 95 // - _
        }
    }

    static func url(for photoId: String) -> URL? {
        guard isValidId(photoId) else { return nil }
        return folder.appending(path: "\(photoId).jpg")
    }

    static func save(_ jpegData: Data, photoId: String) throws {
        guard let target = url(for: photoId) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpegData.write(to: target, options: [.atomic, .completeFileProtection])
    }

    static func image(for photoId: String) -> UIImage? {
        guard let target = url(for: photoId), FileManager.default.fileExists(atPath: target.path) else { return nil }
        return UIImage(contentsOfFile: target.path)
    }

    static func delete(photoId: String) {
        guard let target = url(for: photoId) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// Removes unreferenced `.jpg` files older than `minAge` (default 24 hours).
    /// Call ONLY when the state document has loaded, the app is `.active`, and protected data is available.
    static func pruneOrphans(keeping referencedIds: Set<String>, minAge: TimeInterval = 86_400, now: Date = .now) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in urls where fileURL.pathExtension.lowercased() == "jpg" {
            let id = fileURL.deletingPathExtension().lastPathComponent
            if referencedIds.contains(id) { continue }
            guard let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                continue
            }
            if now.timeIntervalSince(modified) >= minAge {
                try? fm.removeItem(at: fileURL)
            }
        }
    }
}
