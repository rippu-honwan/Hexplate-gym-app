import AVFoundation
import HexplateCore
import os
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Swift 6 strict-concurrency `Transferable` for `PhotosPickerItem` loading `.image` content
/// reliably across HEIC, Live Photos, Portrait, PNG, JPEG, and iCloud-backed photos.
nonisolated struct PickedMealImage: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PickedMealImage(data: data)
        }
        FileRepresentation(importedContentType: .image) { received in
            PickedMealImage(data: try Data(contentsOf: received.file))
        }
    }
}

/// `@MainActor` `UIImagePickerController` wrapper guarded by `isSourceTypeAvailable(.camera)`.
/// Pre-downscales 48 MP camera captures to `<= 2560 px` and hands `Sendable` JPEG `Data` back
/// (reporting extraction/encoding errors explicitly via `onFailed` rather than silently cancelling).
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onPickedData: (Data) -> Void
    let onFailed: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPickedData: onPickedData, onFailed: onFailed, onCancel: onCancel)
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
        let onFailed: () -> Void
        let onCancel: () -> Void

        init(
            onPickedData: @escaping (Data) -> Void,
            onFailed: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onPickedData = onPickedData
            self.onFailed = onFailed
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.imageURL] as? URL, let raw = try? Data(contentsOf: url), !raw.isEmpty {
                onPickedData(raw)
                return
            }
            guard let image = info[.originalImage] as? UIImage else {
                onFailed()
                return
            }
            let downscaled = Self.preDownscale(image, maxDimension: 2560)
            if let jpeg = downscaled.jpegData(compressionQuality: 0.85), !jpeg.isEmpty {
                onPickedData(jpeg)
            } else {
                onFailed()
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
/// privacy opt-in (first time) -> capture/library pick -> unified structured load/prepare/upload
/// task on the sheet root -> in-place handoff to `MealEditorSheet` (saving photo/meal only on Save).
struct AIMealCaptureSheet: View {
    private static let log = Logger(subsystem: "Hexplate", category: "AIMeal")

    private enum WorkingStage {
        case loadingPhoto
        case preparing
        case estimating
    }

    private enum WorkInput {
        case library(PhotosPickerItem)
        case rawData(Data, source: String)
        case preparedJPEG(Data)
        #if DEBUG
        case debugSample
        #endif
    }

    private enum CameraOutcome {
        case data(Data)
        case failed
    }

    private enum Phase {
        case consent
        case pick
        case working(stage: WorkingStage)
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
    @State private var pendingCameraOutcome: CameraOutcome?
    @State private var previewImage: UIImage?

    // Single structured work owner bound to the persistent root `ZStack` (C1, R2).
    @State private var activeToken: UUID?
    @State private var pendingWork: WorkInput?
    @State private var userCancelled = false
    #if DEBUG
    @State private var debugEstimateCalls = 0
    #endif

    private var shouldDeferWeighIn: Bool {
        switch phase {
        case .working, .review:
            return true
        case .consent, .pick, .failed, .manual:
            return false
        }
    }

    var body: some View {
        // Real container (`ZStack`, never `Group`) so `.task(id: activeToken)` and
        // `.interactiveDismissDisabled` bind once to the persistent sheet root (C1).
        ZStack {
            switch phase {
            case .review(let draft):
                MealEditorSheet(defaultDate: defaultDate, aiDraft: draft)
            case .manual(let photoData):
                MealEditorSheet(defaultDate: defaultDate, pendingPhotoData: photoData)
            default:
                captureNavigation
            }
        }
        .interactiveDismissDisabled(shouldDeferWeighIn)
        .task(id: activeToken) {
            guard let token = activeToken, let work = pendingWork else { return }
            // Atomically consume `pendingWork` before the first suspension point (C1).
            pendingWork = nil
            await runWork(work, token: token)
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
                case .working(let stage):
                    workingView(stage: stage)
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
                    Button("Cancel") {
                        cancelAndDismiss()
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: handleCameraDismiss) {
            CameraPicker(
                onPickedData: { data in
                    pendingCameraOutcome = .data(data)
                    showCamera = false
                },
                onFailed: {
                    pendingCameraOutcome = .failed
                    showCamera = false
                },
                onCancel: {
                    pendingCameraOutcome = nil
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
            startWork(.library(item), initialStage: .loadingPhoto)
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
                    activeToken = nil
                    pendingWork = nil
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

                PhotosPicker(
                    selection: $photoItem,
                    matching: .images,
                    preferredItemEncoding: .compatible
                ) {
                    Label("Choose from library", systemImage: "photo.on.rectangle")
                }
                .disabled(!ai.isAvailableForScan)

                #if DEBUG
                if ai.isFakeMode {
                    Button("Use sample meal photo", systemImage: "sparkles") {
                        startWork(.debugSample, initialStage: .loadingPhoto)
                    }
                }
                #endif
            } footer: {
                if !CameraPicker.isAvailable {
                    Text("Camera is not available on this device. Choose a photo from your library.")
                }
            }

            Section {
                Button("Log manually instead", systemImage: "square.and.pencil") {
                    activeToken = nil
                    pendingWork = nil
                    phase = .manual(photoData: nil)
                }
            }
        }
        .keyboardDismissal()
    }

    // MARK: - Working Step (Loading Photo -> Preparing -> Estimating)

    private func workingView(stage: WorkingStage) -> some View {
        let headline: LocalizedStringKey
        let detail: LocalizedStringKey
        switch stage {
        case .loadingPhoto:
            headline = "Loading photo…"
            detail = "Reading your selected photo from the library."
        case .preparing:
            headline = "Preparing photo…"
            detail = "Resizing and stripping camera metadata before upload."
        case .estimating:
            headline = "Estimating nutrition…"
            detail = "Sending your photo to Hexplate AI for nutrition analysis."
        }

        return VStack(spacing: 16) {
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
            Text(headline)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
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
                        startWork(.preparedJPEG(jpeg), initialStage: .estimating)
                    }
                    .fontWeight(.semibold)
                }

                Button("Choose another photo", systemImage: "photo") {
                    activeToken = nil
                    pendingWork = nil
                    previewImage = nil
                    phase = .pick
                }

                Button("Enter manually", systemImage: "square.and.pencil") {
                    activeToken = nil
                    pendingWork = nil
                    phase = .manual(photoData: preparedJPEG)
                }
            }
        }
    }

    // MARK: - Pipeline Helpers

    private func startWork(_ input: WorkInput, initialStage: WorkingStage) {
        userCancelled = false
        pendingWork = input
        if case .preparedJPEG = input {
            // Keep existing prepared thumbnail on retry.
        } else {
            previewImage = nil
        }
        phase = .working(stage: initialStage)
        activeToken = UUID()
    }

    private func cancelAndDismiss() {
        userCancelled = true
        pendingWork = nil
        activeToken = nil
        Self.log.info("stage=cancel origin=user")
        dismiss()
    }

    private func handleCameraDismiss() {
        guard let outcome = pendingCameraOutcome else { return }
        pendingCameraOutcome = nil
        switch outcome {
        case .data(let raw):
            Self.log.info("source=camera stage=load_end bytes=\(raw.count)")
            startWork(.rawData(raw, source: "camera"), initialStage: .preparing)
        case .failed:
            Self.log.error("source=camera stage=load_end outcome=failed")
            activeToken = nil
            pendingWork = nil
            previewImage = nil
            phase = .failed(error: .invalidImage, preparedJPEG: nil, retryBlockedUntil: nil)
        }
    }

    private func runWork(_ work: WorkInput, token: UUID) async {
        var prepared: Data?

        do {
            let rawData: Data?
            switch work {
            case .library(let item):
                let contentTypes = item.supportedContentTypes.map(\.identifier).joined(separator: ",")
                Self.log.info("source=library stage=load_start contentTypes=\(contentTypes, privacy: .public)")
                var loaded: Data?
                if let picked = try? await item.loadTransferable(type: PickedMealImage.self) {
                    loaded = picked.data
                }
                if loaded == nil {
                    loaded = try await item.loadTransferable(type: Data.self)
                }
                try Task.checkCancellation()
                Self.log.info("source=library stage=load_end bytes=\(loaded?.count ?? 0)")
                guard let loaded, !loaded.isEmpty else {
                    throw MealImageError.invalidImage
                }
                rawData = loaded

            case .rawData(let data, let source):
                Self.log.info("source=\(source, privacy: .public) stage=load_ready bytes=\(data.count)")
                rawData = data

            case .preparedJPEG(let jpeg):
                Self.log.info("source=retry stage=prepare_reused bytes=\(jpeg.count)")
                prepared = jpeg
                rawData = nil

            #if DEBUG
            case .debugSample:
                Self.log.info("source=debugSample stage=load_start")
                if ai.isFakeSlow {
                    try await Task.sleep(for: .milliseconds(2_000))
                }
                try Task.checkCancellation()
                guard let sample = Self.makeDebugSampleJPEG() else {
                    throw MealImageError.invalidImage
                }
                Self.log.info("source=debugSample stage=load_end bytes=\(sample.count)")
                rawData = sample
            #endif
            }

            if prepared == nil {
                guard let rawData else {
                    Self.log.error("stage=prepare outcome=missing_raw_data")
                    finishFailed(.invalidImage, preparedJPEG: nil, retryBlockedUntil: nil, token: token)
                    return
                }
                phase = .working(stage: .preparing)
                let processed = try await MealImageProcessor.prepareJPEG(from: rawData)
                try Task.checkCancellation()
                prepared = processed
                // Populate preview strictly from the downscaled <= 1280 px JPEG (R5).
                previewImage = UIImage(data: processed)
                Self.log.info("stage=prepare outcome=ok bytes=\(processed.count)")
            }

            guard let jpeg = prepared else {
                Self.log.error("stage=upload outcome=missing_prepared_jpeg")
                finishFailed(.invalidImage, preparedJPEG: nil, retryBlockedUntil: nil, token: token)
                return
            }

            phase = .working(stage: .estimating)
            #if DEBUG
            debugEstimateCalls += 1
            Self.log.info("stage=upload_start bytes=\(jpeg.count) estimateCall=\(self.debugEstimateCalls)")
            #else
            Self.log.info("stage=upload_start bytes=\(jpeg.count)")
            #endif

            let estimate = try await ai.estimateMeal(jpegData: jpeg, note: note)
            try Task.checkCancellation()
            guard activeToken == token, !userCancelled else { return }
            Self.log.info("stage=upload_end outcome=ok items=\(estimate.items.count)")
            activeToken = nil
            phase = .review(MealEditorSheet.AIDraft(estimate: estimate, jpegData: jpeg))
        } catch let imageError as MealImageError {
            guard activeToken == token, !userCancelled else { return }
            Self.log.error("stage=prepare outcome=error detail=\(String(describing: imageError), privacy: .public)")
            let mapped: AIWire.ErrorKind = (imageError == .tooLarge) ? .payloadTooLarge : .invalidImage
            finishFailed(mapped, preparedJPEG: nil, retryBlockedUntil: nil, token: token)
        } catch let aiError as AIWire.ErrorKind {
            if aiError == .cancelled {
                handleCancellation(preparedJPEG: prepared, token: token)
                return
            }
            guard activeToken == token, !userCancelled else { return }
            Self.log.error("stage=upload_end outcome=ai_error kind=\(String(describing: aiError), privacy: .public)")
            let blockedUntil: Date?
            switch aiError {
            case .dailyCapReached(let secs):
                blockedUntil = secs.map { Date.now.addingTimeInterval(TimeInterval($0)) } ?? .distantFuture
            default:
                blockedUntil = nil
            }
            finishFailed(aiError, preparedJPEG: prepared, retryBlockedUntil: blockedUntil, token: token)
        } catch is CancellationError {
            handleCancellation(preparedJPEG: prepared, token: token)
        } catch {
            guard activeToken == token, !userCancelled else { return }
            Self.log.error("stage=upload_end outcome=unexpected_error type=\(String(describing: type(of: error)), privacy: .public)")
            finishFailed(.networkLost, preparedJPEG: prepared, retryBlockedUntil: nil, token: token)
        }
    }

    private func handleCancellation(preparedJPEG: Data?, token: UUID) {
        if userCancelled || activeToken != token {
            Self.log.info("stage=cancel origin=user")
            return
        }
        // R3: never leave the sheet silently frozen on a spinner after an involuntary cancellation.
        Self.log.warning("stage=cancel origin=unknown prepared=\(preparedJPEG != nil)")
        finishFailed(.networkLost, preparedJPEG: preparedJPEG, retryBlockedUntil: nil, token: token)
    }

    private func finishFailed(
        _ error: AIWire.ErrorKind,
        preparedJPEG: Data?,
        retryBlockedUntil: Date?,
        token: UUID
    ) {
        guard activeToken == token, !userCancelled else { return }
        activeToken = nil
        phase = .failed(error: error, preparedJPEG: preparedJPEG, retryBlockedUntil: retryBlockedUntil)
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
