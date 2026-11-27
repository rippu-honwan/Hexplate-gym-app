import AVFoundation
import HexplateCore
import os
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Swift 6 strict-concurrency `Transferable` for `PhotosPickerItem`.
/// Uses `FileRepresentation` first so ImageIO subsamples directly from `received.file` inside the
/// importing closure (before the temporary file is removed) without loading full 48 MP images into
/// RAM; falls back to `DataRepresentation` producing the exact same `PreparedImage`.
nonisolated struct PickedMealImage: Transferable, Sendable {
    let prepared: MealImageProcessor.PreparedImage

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let result = try MealImageProcessor.prepareImageSync(fromFileURL: received.file)
            return PickedMealImage(prepared: result)
        }
        DataRepresentation(importedContentType: .image) { data in
            let result = try MealImageProcessor.prepareImageSync(from: data)
            return PickedMealImage(prepared: result)
        }
    }
}

/// Prepared on-device meal photo carrying unrotated `baseJPEG` (for single-generation rotation)
/// and the active `displayJPEG` shipped to AI estimation, manual entry, and local photo storage.
nonisolated struct PreparedMealPhoto: Equatable, Sendable {
    let baseJPEG: Data
    var displayJPEG: Data
    var quarterTurns: Int
    let captured: MealImageProcessor.CaptureTimestamp?

    init(prepared: MealImageProcessor.PreparedImage) {
        self.baseJPEG = prepared.jpegData
        self.displayJPEG = prepared.jpegData
        self.quarterTurns = 0
        self.captured = prepared.captured
    }
}

/// `@MainActor` `UIImagePickerController` wrapper guarded by `isSourceTypeAvailable(.camera)`.
/// Grabs `.originalImage` and dismisses immediately so all resizing/encoding runs off-main.
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onPickedImage: (UIImage) -> Void
    let onFailed: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPickedImage: onPickedImage, onFailed: onFailed, onCancel: onCancel)
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
        let onPickedImage: (UIImage) -> Void
        let onFailed: () -> Void
        let onCancel: () -> Void

        init(
            onPickedImage: @escaping (UIImage) -> Void,
            onFailed: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onPickedImage = onPickedImage
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
            guard let image = info[.originalImage] as? UIImage else {
                onFailed()
                return
            }
            onPickedImage(image)
        }
    }
}

/// Single-sheet AI meal photo capture and estimation flow:
/// privacy opt-in (first time) -> pick photo -> local prepare -> unified preview/confirm surface
/// (rotate 90 deg, meal type selector, optional note) -> estimating -> in-place `MealEditorSheet`
/// review (with re-estimate handoff back to confirm; saving photo/meal only on Save).
struct AIMealCaptureSheet: View {
    private static let log = Logger(subsystem: "Hexplate", category: "AIMeal")

    private enum WorkInput {
        case library(PhotosPickerItem)
        case cameraImage(UIImage)
        case estimate(PreparedMealPhoto)
        #if DEBUG
        case debugSample
        #endif
    }

    private enum CameraOutcome {
        case image(UIImage)
        case failed
    }

    private enum Phase {
        case consent
        case pick
        case preparing
        case confirm(PreparedMealPhoto)
        case estimating(PreparedMealPhoto)
        case failed(error: AIWire.ErrorKind, photo: PreparedMealPhoto?)
        case review(MealEditorSheet.AIDraft, photo: PreparedMealPhoto)
        case manual(photo: PreparedMealPhoto?)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let defaultDate: String
    @Binding var deferWeighIn: Bool

    private let ai = AIClient.shared

    @State private var phase: Phase = .pick
    @State private var initialized = false
    @State private var selectedMealType: Nutrition.MealType?
    @State private var note = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showCameraDeniedAlert = false
    @State private var pendingCameraOutcome: CameraOutcome?
    @State private var previewImage: UIImage?

    // Single structured work owner bound to the persistent root `ZStack`.
    @State private var activeToken: UUID?
    @State private var pendingWork: WorkInput?
    @State private var userCancelled = false

    // Separate off-main rotation task bound to the root `ZStack` (renders from `baseJPEG`).
    @State private var rotateToken: UUID?
    @State private var pendingRotate: (photo: PreparedMealPhoto, targetTurns: Int)?
    @State private var isRotating = false

    #if DEBUG
    @State private var debugEstimateCalls = 0
    #endif

    private var shouldDeferWeighIn: Bool {
        switch phase {
        case .preparing, .confirm, .estimating, .review:
            return true
        case .failed(_, let photo):
            return photo != nil
        case .consent, .pick, .manual:
            return false
        }
    }

    var body: some View {
        // Real container (`ZStack`, never `Group`) so `.task(id:)` modifiers and
        // `.interactiveDismissDisabled` bind once to the persistent sheet root.
        ZStack {
            switch phase {
            case .review(let draft, let photo):
                MealEditorSheet(
                    defaultDate: defaultDate,
                    aiDraft: draft,
                    onReestimate: { updatedMealType in
                        selectedMealType = updatedMealType
                        previewImage = UIImage(data: photo.displayJPEG)
                        phase = .confirm(photo)
                    }
                )
            case .manual(let photo):
                MealEditorSheet(
                    defaultDate: defaultDate,
                    pendingPhotoData: photo?.displayJPEG,
                    initialMealType: selectedMealType,
                    hasExplicitMealType: photo != nil,
                    captured: photo?.captured
                )
            default:
                captureNavigation
            }
        }
        .interactiveDismissDisabled(shouldDeferWeighIn)
        .task(id: activeToken) {
            guard let token = activeToken, let work = pendingWork else { return }
            // Atomically consume `pendingWork` before the first suspension point.
            pendingWork = nil
            await runWork(work, token: token)
        }
        .task(id: rotateToken) {
            guard let token = rotateToken, let request = pendingRotate else { return }
            pendingRotate = nil
            await runRotate(request.photo, targetTurns: request.targetTurns, token: token)
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
                case .preparing:
                    workingView(
                        headline: "Preparing photo…",
                        detail: "Resizing and stripping camera metadata before upload.",
                        showCancelEstimation: false,
                        photoForCancel: nil
                    )
                case .confirm(let photo):
                    confirmView(photo: photo, error: nil)
                case .estimating(let photo):
                    workingView(
                        headline: "Estimating nutrition…",
                        detail: "Sending your photo to Hexplate AI for nutrition analysis.",
                        showCancelEstimation: true,
                        photoForCancel: photo
                    )
                case .failed(let error, let photo):
                    if let photo {
                        confirmView(photo: photo, error: error)
                    } else {
                        loadFailedView(error: error)
                    }
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
                onPickedImage: { image in
                    pendingCameraOutcome = .image(image)
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
            startPrepare(.library(item))
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
                    resetActiveTasks()
                    phase = .manual(photo: nil)
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
                        startPrepare(.debugSample)
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
                    resetActiveTasks()
                    phase = .manual(photo: nil)
                }
            }
        }
    }

    // MARK: - Unified Confirm & Failed-with-Photo Step (R16, R17)

    private func confirmView(photo: PreparedMealPhoto, error: AIWire.ErrorKind?) -> some View {
        let retryAfterSeconds: Int? = {
            guard let error else { return nil }
            switch error {
            case .rateLimited(let secs), .busy(let secs):
                return secs
            default:
                return nil
            }
        }()

        let isDailyCap: Bool = {
            if case .dailyCapReached = error { return true }
            return false
        }()

        let canEstimate: Bool = {
            guard ai.isAvailableForScan, !isRotating else { return false }
            guard let error else { return true }
            if isDailyCap { return false }
            return error.isRetryable || error == .noFoodDetected
        }()

        return Form {
            if let error {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Estimation failed").font(.headline)
                            Text(AIClient.userMessage(for: error))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let secs = retryAfterSeconds {
                                Text("Try again in \(secs) s.")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let previewImage {
                Section {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .clipShape(.rect(cornerRadius: 10))
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                    Button {
                        startRotate(photo)
                    } label: {
                        HStack {
                            Label("Rotate 90°", systemImage: "rotate.right")
                            Spacer()
                            if isRotating {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(isRotating)
                }
            }

            Section("Meal type") {
                MealTypePicker(selection: $selectedMealType)
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
                if isDailyCap {
                    Button("Try again", systemImage: "arrow.clockwise") {}
                        .disabled(true)
                } else if error == nil {
                    Button("Estimate nutrition", systemImage: "sparkles") {
                        startEstimate(photo)
                    }
                    .fontWeight(.semibold)
                    .disabled(!canEstimate)
                } else if canEstimate {
                    Button("Try again", systemImage: "arrow.clockwise") {
                        startEstimate(photo)
                    }
                    .fontWeight(.semibold)
                }

                Button("Choose another photo", systemImage: "photo") {
                    resetActiveTasks()
                    previewImage = nil
                    phase = .pick
                }

                Button("Enter manually", systemImage: "square.and.pencil") {
                    resetActiveTasks()
                    phase = .manual(photo: photo)
                }
            }
        }
        .keyboardDismissal()
    }

    // MARK: - Working Step (Preparing / Estimating)

    private func workingView(
        headline: LocalizedStringKey,
        detail: LocalizedStringKey,
        showCancelEstimation: Bool,
        photoForCancel: PreparedMealPhoto?
    ) -> some View {
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
            Text(headline)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if showCancelEstimation, let photoForCancel {
                Button("Cancel estimation") {
                    // Return to `.confirm` synchronously; in-flight task exits on token check (R17).
                    activeToken = nil
                    pendingWork = nil
                    Self.log.info("stage=cancel_estimation origin=user")
                    phase = .confirm(photoForCancel)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Load/Prepare Failed (No Photo Yet)

    private func loadFailedView(error: AIWire.ErrorKind) -> some View {
        List {
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
                Button("Choose another photo", systemImage: "photo") {
                    resetActiveTasks()
                    previewImage = nil
                    phase = .pick
                }

                Button("Enter manually", systemImage: "square.and.pencil") {
                    resetActiveTasks()
                    phase = .manual(photo: nil)
                }
            }
        }
    }

    // MARK: - Pipeline Helpers

    private func resetActiveTasks() {
        activeToken = nil
        pendingWork = nil
        rotateToken = nil
        pendingRotate = nil
        isRotating = false
    }

    private func startPrepare(_ input: WorkInput) {
        userCancelled = false
        rotateToken = nil
        pendingRotate = nil
        isRotating = false
        previewImage = nil
        pendingWork = input
        phase = .preparing
        activeToken = UUID()
    }

    private func startEstimate(_ photo: PreparedMealPhoto) {
        guard !isRotating else { return }
        userCancelled = false
        pendingWork = .estimate(photo)
        phase = .estimating(photo)
        activeToken = UUID()
    }

    private func startRotate(_ photo: PreparedMealPhoto) {
        guard !isRotating else { return }
        isRotating = true
        let nextTurns = (photo.quarterTurns + 1) % 4
        pendingRotate = (photo, nextTurns)
        rotateToken = UUID()
    }

    private func cancelAndDismiss() {
        userCancelled = true
        resetActiveTasks()
        Self.log.info("stage=cancel origin=user")
        dismiss()
    }

    private func handleCameraDismiss() {
        guard let outcome = pendingCameraOutcome else { return }
        pendingCameraOutcome = nil
        switch outcome {
        case .image(let image):
            Self.log.info("source=camera stage=captured")
            startPrepare(.cameraImage(image))
        case .failed:
            Self.log.error("source=camera stage=load_end outcome=failed")
            resetActiveTasks()
            previewImage = nil
            phase = .failed(error: .invalidImage, photo: nil)
        }
    }

    private func initialSuggestedMealType(for captured: MealImageProcessor.CaptureTimestamp?) -> Nutrition.MealType? {
        if let captured, captured.day == defaultDate {
            return Nutrition.MealType.suggested(forHour: captured.hour)
        }
        if defaultDate == model.today {
            let hour = Calendar.current.component(.hour, from: Date.now)
            return Nutrition.MealType.suggested(forHour: hour)
        }
        return nil
    }

    private func runRotate(_ photo: PreparedMealPhoto, targetTurns: Int, token: UUID) async {
        defer {
            if rotateToken == token {
                isRotating = false
                rotateToken = nil
            }
        }
        do {
            let rotatedJPEG = try await MealImageProcessor.rotate(photo.baseJPEG, quarterTurns: targetTurns)
            try Task.checkCancellation()
            guard rotateToken == token, !userCancelled else { return }
            var updated = photo
            updated.displayJPEG = rotatedJPEG
            updated.quarterTurns = targetTurns
            previewImage = UIImage(data: rotatedJPEG)
            switch phase {
            case .confirm:
                phase = .confirm(updated)
            case .failed(let error, _):
                phase = .failed(error: error, photo: updated)
            default:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("stage=rotate outcome=error")
        }
    }

    private func runWork(_ work: WorkInput, token: UUID) async {
        var currentPhoto: PreparedMealPhoto?

        do {
            switch work {
            case .library(let item):
                let contentTypes = item.supportedContentTypes.map(\.identifier).joined(separator: ",")
                Self.log.info("source=library stage=load_start contentTypes=\(contentTypes, privacy: .public)")

                var preparedResult: MealImageProcessor.PreparedImage?
                do {
                    if let picked = try await item.loadTransferable(type: PickedMealImage.self) {
                        preparedResult = picked.prepared
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let ns = error as NSError
                    Self.log.warning("source=library stage=transfer_fallback domain=\(ns.domain, privacy: .public) code=\(ns.code)")
                }

                try Task.checkCancellation()

                if preparedResult == nil {
                    let rawData = try await item.loadTransferable(type: Data.self)
                    try Task.checkCancellation()
                    guard let rawData, !rawData.isEmpty else {
                        throw MealImageError.invalidImage
                    }
                    preparedResult = try await MealImageProcessor.prepareImage(from: rawData)
                }

                try Task.checkCancellation()
                guard let prepared = preparedResult else {
                    throw MealImageError.invalidImage
                }
                guard activeToken == token, !userCancelled else { return }

                let photo = PreparedMealPhoto(prepared: prepared)
                selectedMealType = initialSuggestedMealType(for: photo.captured)
                previewImage = UIImage(data: photo.displayJPEG)
                Self.log.info("source=library stage=prepare_ok bytes=\(photo.displayJPEG.count)")
                activeToken = nil
                phase = .confirm(photo)

            case .cameraImage(let image):
                let prepared = try await Self.prepareCameraImage(image)
                try Task.checkCancellation()
                guard activeToken == token, !userCancelled else { return }

                let photo = PreparedMealPhoto(prepared: prepared)
                selectedMealType = initialSuggestedMealType(for: photo.captured)
                previewImage = UIImage(data: photo.displayJPEG)
                Self.log.info("source=camera stage=prepare_ok bytes=\(photo.displayJPEG.count)")
                activeToken = nil
                phase = .confirm(photo)

            #if DEBUG
            case .debugSample:
                Self.log.info("source=debugSample stage=load_start")
                guard let sample = Self.makeDebugSampleJPEG() else {
                    throw MealImageError.invalidImage
                }
                let prepared = try await MealImageProcessor.prepareImage(from: sample)
                try Task.checkCancellation()
                guard activeToken == token, !userCancelled else { return }

                let photo = PreparedMealPhoto(prepared: prepared)
                selectedMealType = initialSuggestedMealType(for: photo.captured)
                previewImage = UIImage(data: photo.displayJPEG)
                Self.log.info("source=debugSample stage=prepare_ok bytes=\(photo.displayJPEG.count)")
                activeToken = nil
                phase = .confirm(photo)
            #endif

            case .estimate(let photo):
                currentPhoto = photo
                let jpeg = photo.displayJPEG
                #if DEBUG
                debugEstimateCalls += 1
                Self.log.info("stage=upload_start bytes=\(jpeg.count) estimateCall=\(self.debugEstimateCalls)")
                #else
                Self.log.info("stage=upload_start bytes=\(jpeg.count)")
                #endif

                let estimate = try await ai.estimateMeal(
                    jpegData: jpeg,
                    note: note,
                    mealType: selectedMealType
                )
                try Task.checkCancellation()
                guard activeToken == token, !userCancelled else { return }

                Self.log.info("stage=upload_end outcome=ok items=\(estimate.items.count)")
                activeToken = nil
                let draft = MealEditorSheet.AIDraft(
                    estimate: estimate,
                    jpegData: jpeg,
                    mealType: selectedMealType,
                    captured: photo.captured
                )
                phase = .review(draft, photo: photo)
            }
        } catch let imageError as MealImageError {
            guard activeToken == token, !userCancelled else { return }
            Self.log.error("stage=prepare outcome=error detail=\(String(describing: imageError), privacy: .public)")
            let mapped: AIWire.ErrorKind = (imageError == .tooLarge) ? .payloadTooLarge : .invalidImage
            finishFailed(mapped, photo: currentPhoto, token: token)
        } catch let aiError as AIWire.ErrorKind {
            if aiError == .cancelled {
                handleCancellation(photo: currentPhoto, token: token)
                return
            }
            guard activeToken == token, !userCancelled else { return }
            Self.log.error("stage=upload_end outcome=ai_error kind=\(String(describing: aiError), privacy: .public)")
            finishFailed(aiError, photo: currentPhoto, token: token)
        } catch is CancellationError {
            handleCancellation(photo: currentPhoto, token: token)
        } catch {
            guard activeToken == token, !userCancelled else { return }
            let ns = error as NSError
            Self.log.error("stage=work outcome=unexpected_error domain=\(ns.domain, privacy: .public) code=\(ns.code)")
            let fallbackError: AIWire.ErrorKind = (currentPhoto == nil) ? .invalidImage : .networkLost
            finishFailed(fallbackError, photo: currentPhoto, token: token)
        }
    }

    private func handleCancellation(photo: PreparedMealPhoto?, token: UUID) {
        if userCancelled || activeToken != token {
            Self.log.info("stage=cancel origin=user")
            return
        }
        // Never leave the sheet silently frozen on a spinner after an involuntary cancellation.
        Self.log.warning("stage=cancel origin=unknown prepared=\(photo != nil)")
        let mapped: AIWire.ErrorKind = (photo == nil) ? .invalidImage : .networkLost
        finishFailed(mapped, photo: photo, token: token)
    }

    private func finishFailed(
        _ error: AIWire.ErrorKind,
        photo: PreparedMealPhoto?,
        token: UUID
    ) {
        guard activeToken == token, !userCancelled else { return }
        activeToken = nil
        phase = .failed(error: error, photo: photo)
    }

    /// Off-main single-intermediate preparation for camera captures (`2560 px` @ `0.95` -> normal ladder).
    private nonisolated static func prepareCameraImage(_ image: UIImage) async throws -> MealImageProcessor.PreparedImage {
        let downscaled = preDownscale(image, maxDimension: 2560)
        guard let intermediate = downscaled.jpegData(compressionQuality: 0.95), !intermediate.isEmpty else {
            throw MealImageError.encodeFailed
        }
        let jpeg = try MealImageProcessor.prepareJPEGSync(from: intermediate)
        let now = Date.now
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let hour = comps.hour ?? 12
        let minute = comps.minute ?? 0
        let captured = MealImageProcessor.CaptureTimestamp(
            day: Day.iso(now),
            time: String(format: "%02d:%02d", hour, minute),
            hour: hour
        )
        return MealImageProcessor.PreparedImage(jpegData: jpeg, captured: captured)
    }

    private nonisolated static func preDownscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        return image.preparingThumbnail(of: target) ?? image
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
