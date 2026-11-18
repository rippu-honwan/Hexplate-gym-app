import CryptoKit
import HexplateCore
import PhotosUI
import SwiftUI

/// The bytes behind MediaRefs: one file per photo in Application Support/Hexplate/media, named
/// by its SHA-256 the way the web app's store names them (media-store.js).
enum MediaStore {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Hexplate/media", directoryHint: .isDirectory)
    }
    static func url(_ ref: [String: JSONValue]) -> URL? {
        guard let hash = ref["hash"]?.stringValue, let mime = ref["mime"]?.stringValue else { return nil }
        return folder.appending(path: "\(hash).\(WorkoutPhotos.ext(mime))")
    }
    static func image(_ ref: [String: JSONValue]) -> UIImage? { url(ref).flatMap { UIImage(contentsOfFile: $0.path) } }

    /// A picked photo as a JPEG no longer than 2048 px on its long edge, with no location or other
    /// metadata, saved under its hash. Its MediaRef, or nil when it is not an image.
    static func ingest(_ data: Data, now: Double) -> [String: JSONValue]? {
        guard let source = UIImage(data: data) else { return nil }
        let edge = max(source.size.width, source.size.height), scale = min(1, 2048 / max(edge, 1))
        let size = CGSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        let ref: [String: JSONValue] = ["kind": .string("image"), "hash": .string(hash), "mime": .string("image/jpeg"), "size": .number(Double(jpeg.count)),
                                        "width": .number(size.width), "height": .number(size.height), "at": .number(now)]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let url = url(ref), !FileManager.default.fileExists(atPath: url.path) { try jpeg.write(to: url, options: .completeFileProtection) }
        } catch { return nil }
        return ref
    }
}

/// A saved workout's progress photos: a grid, Add while there is room, a context menu to remove.
// ponytail: photos only; videos, and photos filed under a day without a workout (dayPhotos), wait.
struct WorkoutPhotosSection: View {
    @Environment(AppModel.self) private var model
    let key: String
    let record: [String: JSONValue]?
    @State private var picked: [PhotosPickerItem] = []
    @State private var showing: [String: JSONValue]?

    var body: some View {
        let refs = WorkoutPhotos.of(record)
        Section {
            if !refs.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(refs.indices, id: \.self) { i in
                        Thumb(ref: refs[i])
                            .onTapGesture { showing = refs[i] }
                            .contextMenu {
                                Button("Remove photo", systemImage: "trash", role: .destructive) { remove(refs[i]) }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            if refs.count < WorkoutPhotos.max {
                PhotosPicker(selection: $picked, maxSelectionCount: WorkoutPhotos.max - refs.count, matching: .images) {
                    Label("Add progress photo", systemImage: "photo.badge.plus")
                }
            }
        } header: { Text("Photos") } footer: {
            Text("Kept on this phone. Up to \(WorkoutPhotos.max) per workout.")
        }
        .onChange(of: picked) { Task { await add(picked) } }
        .fullScreenCover(item: Binding(get: { showing.map(Shown.init) }, set: { showing = $0?.ref })) { PhotoViewer(ref: $0.ref) }
    }

    private func add(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let ref = MediaStore.ingest(data, now: model.now) else { continue }
            let (k, t) = (key, model.now)
            model.change { s in
                var list = s["workouts"]?.arrayValue ?? []
                if WorkoutPhotos.add(&list, key: k, ref, now: t) == .added { s["workouts"] = .array(list) }
            }
        }
        picked = []
    }

    private func remove(_ ref: [String: JSONValue]) {
        guard let hash = ref["hash"]?.stringValue else { return }
        let (k, t) = (key, model.now)
        model.change { s in
            var list = s["workouts"]?.arrayValue ?? []
            if WorkoutPhotos.remove(&list, key: k, hash: hash, now: t) { s["workouts"] = .array(list) }
        }
    }

    struct Shown: Identifiable { let ref: [String: JSONValue]; var id: String { ref["hash"]?.stringValue ?? "" } }
}

/// One square thumbnail; a grey tile when the file is not on this phone or media is hidden.
private struct Thumb: View {
    let ref: [String: JSONValue]
    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if !ExerciseMedia.hidden, let image = MediaStore.image(ref) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .contentShape(.rect)
    }
}

private struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let ref: [String: JSONValue]
    var body: some View {
        NavigationStack {
            Group {
                if !ExerciseMedia.hidden, let image = MediaStore.image(ref) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ContentUnavailableView("Not on this phone", systemImage: "photo", description: Text("This photo was added on another device."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
