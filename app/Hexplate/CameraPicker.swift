import AVFoundation
import HexplateCore
import PhotosUI
import SwiftUI
import UIKit

/// `@MainActor` `UIImagePickerController` wrapper guarded by `isSourceTypeAvailable(.camera)`.
/// Pre-downscales 48 MP camera captures to `<= 2560 px` before handing raw bytes to
/// `HexplateCore.MealImageProcessor` so memory stays bounded.
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onPickedData: (Data) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPickedData: onPickedData, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPickedData: (Data) -> Void
        let onCancel: () -> Void

        init(onPickedData: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onPickedData = onPickedData
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.imageURL] as? URL, let raw = try? Data(contentsOf: url) {
                onPickedData(raw)
                return
            }
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            let downscaled = Self.preDownscale(image, maxDimension: 2560)
            if let jpeg = downscaled.jpegData(compressionQuality: 0.85) {
                onPickedData(jpeg)
            } else {
                onCancel()
            }
        }

        private static func preDownscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
            let size = image.size
            let longest = max(size.width, size.height)
            guard longest > maxDimension, longest > 0 else { return image }
            let scale = maxDimension / longest
            let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            return image.preparingThumbnail(of: target) ?? image
        }
    }
}

/// Single-sheet AI meal photo capture and estimation flow:
/// privacy opt-in (first time) -> capture/library pick -> off-main EXIF-strip resize + `/api/ai/meal`
/// -> in-place handoff to `MealEditorSheet` (never saving photo or meal until the user taps Save).
struct AIMealCaptureSheet: View {
    private enum Phase {
        case consent
        case pick
        case analyzing(rawData: Data?, preparedJPEG: Data?, token: UUID)
        case failed(error: AIWire.ErrorKind, preparedJPEG: Data?, retryBlockedUntil: Date?)
        case review(MealEditorSheet.AIDraft)
        case manual(photoData: Data?)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let defaultDate: String
    @Binding var deferWeighIn: Bool

    private let ai = AIClient.shared

    @State private var phase: Phase = .pick
    @State private var initialized = false
    @State private var note = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showCameraDeniedAlert = false
    @State private var previewImage: UIImage?
    @State private var photoLoadError = false

    private var shouldDeferWeighIn: Bool {
        switch phase {
        case .analyzing, .review:
            return true
        case .consent, .pick, .failed, .manual:
            return false
        }
    }

    var body: some View {
        Group {
            switch phase {
            case .review(let draft):
                MealEditorSheet(defaultDate: defaultDate, aiDraft: draft)
            case .manual(let photoData):
                MealEditorSheet(defaultDate: defaultDate, pendingPhotoData: photoData)
            default:
                captureNavigation
            }
        }
        .onAppear {
            if !initialized {
                initialized = true
                phase = ai.hasPrivacyConsent ? .pick : .consent
            }
            deferWeighIn = shouldDeferWeighIn
        }
        .onChange(of: shouldDeferWeighIn) { _, newValue in
            deferWeighIn = newValue
        }
        .onDisappear {
            deferWeighIn = false
        }
    }

    private var captureNavigation: some View {
        NavigationStack {
            Group {
                switch phase {
                case .consent:
                    consentView
                case .pick:
                    pickView
                case .analyzing(let rawData, let preparedJPEG, let token):
                    analyzingView(rawData: rawData, preparedJPEG: preparedJPEG, token: token)
                case .failed(let error, let preparedJPEG, let blockedUntil):
                    failedView(error: error, preparedJPEG: preparedJPEG, retryBlockedUntil: blockedUntil)
                case .review, .manual:
                    EmptyView()
                }
            }
            .navigationTitle("Scan meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onPickedData: { data in
                    showCamera = false
                    startAnalysis(rawData: data)
                },
                onCancel: {
                    showCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .alert("Camera access is off", isPresented: $showCameraDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow camera access in Settings to photograph meals, or choose a photo from your library.")
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            photoLoadError = false
            Task {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        startAnalysis(rawData: data)
                    } else {
                        photoLoadError = true
                    }
                } catch {
                    photoLoadError = true
                }
            }
        }
    }

    // MARK: - Consent Step

    private var consentView: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI meal estimation").font(.headline)
                        Text("When you scan a meal, your resized photo and optional note are sent to your Hexplate server and forwarded to the AI provider it is configured with.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Location and EXIF camera metadata are removed before upload. Saved photos stay on this device only.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "camera.viewfinder").foregroundStyle(.tint)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button("Continue") {
                    ai.acceptPrivacyConsent()
                    phase = .pick
                }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)

                Button("Log manually instead") {
                    phase = .manual(photoData: nil)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pick Photo Step

    private var pickView: some View {
        Form {
            if !ai.isAvailableForScan {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect Hexplate to your server").font(.headline)
                            Text("Pair your server in Profile → Settings → Server to estimate meals from photos.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextField("Optional note (e.g. half rice, 200 g chicken)", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                    .onChange(of: note) { _, value in
                        if value.count > AIWire.maxNoteCharacters {
                            note = String(value.prefix(AIWire.maxNoteCharacters))
                        }
                    }
            } header: {
                Text("Note")
            } footer: {
                Text("Optional details help improve portion estimates (\(note.count)/\(AIWire.maxNoteCharacters)).")
                    .monospacedDigit()
            }

            Section {
                if CameraPicker.isAvailable {
                    Button("Take photo", systemImage: "camera") {
                        requestCameraAndPresent()
                    }
                    .disabled(!ai.isAvailableForScan)
                }

                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    Label("Choose from library", systemImage: "photo.on.rectangle")
                }
                .disabled(!ai.isAvailableForScan)

                #if DEBUG
                if ai.isFakeMode {
                    Button("Use sample meal photo", systemImage: "sparkles") {
                        if let sample = Self.makeDebugSampleJPEG() {
                            startAnalysis(rawData: sample)
                        }
                    }
                }
                #endif
            } footer: {
                if photoLoadError {
                    Text("Could not load that photo. Try another image.")
                } else if !CameraPicker.isAvailable {
                    Text("Camera is not available on this device. Choose a photo from your library.")
                }
            }

            Section {
                Button("Log manually instead", systemImage: "square.and.pencil") {
                    phase = .manual(photoData: nil)
                }
            }
        }
        .keyboardDismissal()
    }

    // MARK: - Analyzing Step

    private func analyzingView(rawData: Data?, preparedJPEG: Data?, token: UUID) -> some View {
        VStack(spacing: 16) {
            Spacer()
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 180, height: 180)
                    .clipShape(.rect(cornerRadius: 14))
            }
            ProgressView()
                .controlSize(.large)
            Text("Estimating nutrition…")
                .font(.headline)
            Text("Stripping metadata and analyzing your meal photo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .task(id: token) {
            await runAnalysis(rawData: rawData, existingJPEG: preparedJPEG, token: token)
        }
    }

    // MARK: - Failed / Retry Step

    private func failedView(
        error: AIWire.ErrorKind,
        preparedJPEG: Data?,
        retryBlockedUntil: Date?
    ) -> some View {
        let canRetry: Bool = {
            guard preparedJPEG != nil else { return false }
            if !error.isRetryable { return false }
            if let blockedUntil = retryBlockedUntil, Date.now < blockedUntil { return false }
            return true
        }()

        return List {
            if let previewImage {
                Section {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipShape(.rect(cornerRadius: 10))
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }

            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Estimation failed").font(.headline)
                        Text(AIClient.userMessage(for: error))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 4)
            }

            Section {
                if case .dailyCapReached = error {
                    Button("Try again", systemImage: "arrow.clockwise") {}
                        .disabled(true)
                } else if canRetry, let jpeg = preparedJPEG {
                    Button("Try again", systemImage: "arrow.clockwise") {
                        phase = .analyzing(rawData: nil, preparedJPEG: jpeg, token: UUID())
                    }
                    .fontWeight(.semibold)
                }

                Button("Choose another photo", systemImage: "photo") {
                    previewImage = nil
                    phase = .pick
                }

                Button("Enter manually", systemImage: "square.and.pencil") {
                    phase = .manual(photoData: preparedJPEG)
                }
            }
        }
    }

    // MARK: - Helpers

    private func startAnalysis(rawData: Data) {
        previewImage = UIImage(data: rawData)
        phase = .analyzing(rawData: rawData, preparedJPEG: nil, token: UUID())
    }

    private func runAnalysis(rawData: Data?, existingJPEG: Data?, token: UUID) async {
        var prepared: Data? = existingJPEG
        do {
            if prepared == nil {
                guard let rawData else {
                    phase = .failed(error: .invalidImage, preparedJPEG: nil, retryBlockedUntil: nil)
                    return
                }
                let processed = try await MealImageProcessor.prepareJPEG(from: rawData)
                try Task.checkCancellation()
                prepared = processed
                previewImage = UIImage(data: processed)
            }

            guard let jpeg = prepared else { return }
            let estimate = try await ai.estimateMeal(jpegData: jpeg, note: note)
            guard !Task.isCancelled else { return }
            phase = .review(MealEditorSheet.AIDraft(estimate: estimate, jpegData: jpeg))
        } catch let imageError as MealImageError {
            guard !Task.isCancelled else { return }
            let mapped: AIWire.ErrorKind = (imageError == .tooLarge) ? .payloadTooLarge : .invalidImage
            phase = .failed(error: mapped, preparedJPEG: nil, retryBlockedUntil: nil)
        } catch let aiError as AIWire.ErrorKind {
            guard !Task.isCancelled, aiError != .cancelled else { return }
            let blockedUntil: Date?
            switch aiError {
            case .dailyCapReached(let secs):
                blockedUntil = secs.map { Date.now.addingTimeInterval(TimeInterval($0)) } ?? .distantFuture
            default:
                blockedUntil = nil
            }
            phase = .failed(error: aiError, preparedJPEG: prepared, retryBlockedUntil: blockedUntil)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error: .networkLost, preparedJPEG: prepared, retryBlockedUntil: nil)
        }
    }

    private func requestCameraAndPresent() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted {
                    showCamera = true
                } else {
                    showCameraDeniedAlert = true
                }
            }
        case .denied, .restricted:
            showCameraDeniedAlert = true
        @unknown default:
            showCameraDeniedAlert = true
        }
    }

    #if DEBUG
    private static func makeDebugSampleJPEG() -> Data? {
        let size = CGSize(width: 640, height: 480)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.systemOrange.withAlphaComponent(0.25).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.systemBrown.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 120, y: 80, width: 400, height: 320))
            UIColor.systemGreen.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 320, y: 150, width: 140, height: 140))
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 170, y: 160, width: 150, height: 150))
        }
        return img.jpegData(compressionQuality: 0.85)
    }
    #endif
}
