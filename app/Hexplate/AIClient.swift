import Foundation
import HexplateCore
import Observation
import UIKit

/// Client for paired server AI endpoints (`GET /api/ai/status`, `POST /api/ai/meal`, `POST /api/ai/coach`).
///
/// Key invariants:
/// - Reads `ServerSync.shared.aiCredentials` fresh on every request (never cached across token rotation).
/// - Dedicated ephemeral `URLSession` with `httpShouldSetCookies = false` and `timeoutIntervalForResource = 75`
///   (safely above the server's 50 s deadline + cellular/Tailscale upload transit so structured 504 errors arrive cleanly).
/// - Meal and Coach privacy consents are tracked under separate UserDefaults keys because each
///   feature transmits a different data scope.
/// - Request serialization runs off-main via `AIWire.encodeMealRequestAsync` / `encodeCoachRequestAsync`.
@MainActor
@Observable
final class AIClient {
    @MainActor
    private final class BackgroundTaskBox {
        private var id: UIBackgroundTaskIdentifier = .invalid

        func begin(name: String) {
            end()
            id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                self?.end()
            }
        }

        func end() {
            guard id != .invalid else { return }
            let current = id
            id = .invalid
            UIApplication.shared.endBackgroundTask(current)
        }
    }

    static let shared = AIClient()
    static let privacyConsentKey = "aiPrivacyConsentAccepted"
    static let coachPrivacyConsentKey = "aiCoachPrivacyConsentAccepted"

    private(set) var hasPrivacyConsent: Bool
    private(set) var hasCoachPrivacyConsent: Bool

    #if DEBUG
    let isFakeMode: Bool
    let isFakeSlow: Bool
    let isFakeCoachMode: Bool
    private let fakeWarning: Bool
    private let fakeErrorOnce: Bool
    private let fakeCancelOnce: Bool
    private let fakeDelayMs: Int
    private var fakeErrorConsumed = false
    private var fakeCancelConsumed = false

    private let fakeCoachNoChange: Bool
    private let fakeCoachErrorOnce: Bool
    private var fakeCoachErrorConsumed = false
    #endif

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 75
        config.timeoutIntervalForResource = 75
        return URLSession(configuration: config)
    }()

    init() {
        self.hasPrivacyConsent = UserDefaults.standard.bool(forKey: Self.privacyConsentKey)
        self.hasCoachPrivacyConsent = UserDefaults.standard.bool(forKey: Self.coachPrivacyConsentKey)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let fakeAI = args.contains("-hexplate-fake-ai")
        let fakeWarn = args.contains("-hexplate-fake-ai-warning")
        let fakeErr = args.contains("-hexplate-fake-ai-error")
        let fakeSlow = args.contains("-hexplate-fake-ai-slow")
        let fakeCancel = args.contains("-hexplate-fake-ai-cancel")
        self.isFakeMode = fakeAI || fakeWarn || fakeErr || fakeSlow || fakeCancel
        self.isFakeSlow = fakeSlow
        self.fakeWarning = fakeWarn
        self.fakeErrorOnce = fakeErr
        self.fakeCancelOnce = fakeCancel
        self.fakeDelayMs = fakeSlow ? 2_000 : 700

        let fakeCoach = args.contains("-hexplate-fake-coach")
        let fakeCoachNoChg = args.contains("-hexplate-fake-coach-no-change")
        let fakeCoachErr = args.contains("-hexplate-fake-coach-error")
        self.isFakeCoachMode = fakeCoach || fakeCoachNoChg || fakeCoachErr
        self.fakeCoachNoChange = fakeCoachNoChg
        self.fakeCoachErrorOnce = fakeCoachErr
        #endif
    }

    var isAvailableForScan: Bool {
        #if DEBUG
        if isFakeMode { return true }
        #endif
        return ServerSync.shared.paired
    }

    var isAvailableForCoach: Bool {
        #if DEBUG
        if isFakeCoachMode { return true }
        #endif
        return ServerSync.shared.paired
    }

    func acceptPrivacyConsent() {
        UserDefaults.standard.set(true, forKey: Self.privacyConsentKey)
        hasPrivacyConsent = true
    }

    func acceptCoachPrivacyConsent() {
        UserDefaults.standard.set(true, forKey: Self.coachPrivacyConsentKey)
        hasCoachPrivacyConsent = true
    }

    func fetchStatus() async throws -> AIWire.Status {
        #if DEBUG
        if isFakeMode {
            return AIWire.Status(configured: true, model: "fake-vision-v1", dailyTokenCap: 200_000, dailyTokensUsed: 1_200)
        }
        #endif
        guard let creds = ServerSync.shared.aiCredentials else {
            throw AIWire.ErrorKind.notPaired
        }
        guard let url = URL(string: creds.base + "/api/ai/status") else {
            throw AIWire.ErrorKind.notPaired
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")

        let (data, http) = try await perform(req)
        guard (200..<300).contains(http.statusCode) else {
            throw AIWire.mapHTTPError(
                status: http.statusCode,
                body: data,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        return try AIWire.decodeStatus(from: data)
    }

    func estimateMeal(
        jpegData: Data,
        note: String?,
        mealType: Nutrition.MealType? = nil
    ) async throws -> AIWire.MealEstimate {
        // Off-main base64 + JSON encoding (runs on global executor via nonisolated async).
        let lang = Theme.language
        let body = try await AIWire.encodeMealRequestAsync(
            jpegData: jpegData,
            note: note,
            lang: lang,
            mealType: mealType?.rawValue
        )
        try Task.checkCancellation()

        #if DEBUG
        if isFakeMode {
            do {
                try await Task.sleep(for: .milliseconds(fakeDelayMs))
            } catch {
                throw AIWire.ErrorKind.cancelled
            }
            if fakeCancelOnce && !fakeCancelConsumed {
                fakeCancelConsumed = true
                throw AIWire.ErrorKind.cancelled
            }
            if fakeErrorOnce && !fakeErrorConsumed {
                fakeErrorConsumed = true
                throw AIWire.ErrorKind.networkLost
            }
            return Self.fakeEstimate(lang: lang, warning: fakeWarning)
        }
        #endif

        guard let creds = ServerSync.shared.aiCredentials else {
            throw AIWire.ErrorKind.notPaired
        }
        guard let url = URL(string: creds.base + "/api/ai/meal") else {
            throw AIWire.ErrorKind.notPaired
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Protect in-flight vision upload across brief screen locks or app switches (R15).
        let bgTask = BackgroundTaskBox()
        bgTask.begin(name: "HexplateAIMealEstimate")
        defer { bgTask.end() }

        let (data, http) = try await perform(req)
        guard (200..<300).contains(http.statusCode) else {
            throw AIWire.mapHTTPError(
                status: http.statusCode,
                body: data,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        return try AIWire.decodeMealEstimate(from: data)
    }

    func askCoach(
        message: String,
        snapshot: CoachContext.Snapshot,
        history: [AIWire.CoachChatTurn] = []
    ) async throws -> AIWire.CoachResponse {
        let lang = Theme.language
        let body = try await AIWire.encodeCoachRequestAsync(
            message: message,
            snapshot: snapshot,
            lang: lang,
            history: history
        )
        try Task.checkCancellation()

        #if DEBUG
        if isFakeCoachMode {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                throw AIWire.ErrorKind.cancelled
            }
            if fakeCoachErrorOnce && !fakeCoachErrorConsumed {
                fakeCoachErrorConsumed = true
                throw AIWire.ErrorKind.networkLost
            }
            let fakeData = try Self.fakeCoachResponseData(snapshot: snapshot, noChange: fakeCoachNoChange)
            return try AIWire.decodeCoachResponse(from: fakeData)
        }
        #endif

        guard let creds = ServerSync.shared.aiCredentials else {
            throw AIWire.ErrorKind.notPaired
        }
        guard let url = URL(string: creds.base + "/api/ai/coach") else {
            throw AIWire.ErrorKind.notPaired
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, http) = try await perform(req)
        guard (200..<300).contains(http.statusCode) else {
            throw AIWire.mapHTTPError(
                status: http.statusCode,
                body: data,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        return try AIWire.decodeCoachResponse(from: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIWire.ErrorKind.invalidResponse
            }
            return (data, http)
        } catch let error as AIWire.ErrorKind {
            throw error
        } catch is CancellationError {
            throw AIWire.ErrorKind.cancelled
        } catch let urlError as URLError {
            switch urlError.code {
            case .cancelled:
                throw AIWire.ErrorKind.cancelled
            case .timedOut:
                throw AIWire.ErrorKind.timeout
            default:
                throw AIWire.ErrorKind.networkLost
            }
        } catch {
            throw AIWire.ErrorKind.networkLost
        }
    }

    static func userMessage(for error: AIWire.ErrorKind) -> String {
        switch error {
        case .notPaired:
            String(localized: "Connect Hexplate to your server in Settings before using AI meal estimation.")
        case .notConfigured:
            String(localized: "AI meal estimation is not configured on your server yet.")
        case .unauthorized:
            String(localized: "Your server sign-in expired. Re-pair in Settings.")
        case .upstreamAuth:
            String(localized: "The AI provider rejected your server’s API key. Check your server configuration.")
        case .payloadTooLarge:
            String(localized: "This photo is still too large after resizing. Try a different photo.")
        case .invalidImage, .badRequest:
            String(localized: "The photo could not be read. Try taking or choosing another photo.")
        case .noFoodDetected:
            String(localized: "No food was recognized in this photo. Try a clearer angle or log manually.")
        case .rateLimited:
            String(localized: "Too many AI requests right now. Wait a moment and try again.")
        case .dailyCapReached:
            String(localized: "Daily AI limit reached — try again later.")
        case .busy:
            String(localized: "The AI service is busy right now. Try again in a moment.")
        case .timeout:
            String(localized: "Estimation timed out. Check your connection and try again.")
        case .networkLost:
            String(localized: "Connection was interrupted. Tap Try again to re-send your photo.")
        case .cancelled:
            String(localized: "Estimation cancelled.")
        case .serverError, .invalidResponse:
            String(localized: "The AI service returned an unexpected response. Try again or log manually.")
        }
    }

    static func warningMessage(for code: String) -> String {
        switch code {
        case "macro-kcal-mismatch":
            String(localized: "Calories and macros don’t quite add up. Check the numbers before saving.")
        default:
            String(localized: "Review the estimated numbers before saving.")
        }
    }

    static func coachUserMessage(for error: AIWire.ErrorKind) -> String {
        switch error {
        case .notPaired:
            String(localized: "Connect Hexplate to your server in Profile → Settings → Server before using AI Coach.")
        case .notConfigured:
            String(localized: "AI Coach is not configured on your server yet.")
        case .unauthorized:
            String(localized: "Your server sign-in expired. Re-pair in Settings.")
        case .upstreamAuth:
            String(localized: "The AI provider rejected your server’s API key. Check your server configuration.")
        case .payloadTooLarge:
            String(localized: "Your training context is too large to send. Try a shorter question.")
        case .badRequest, .invalidImage, .noFoodDetected:
            String(localized: "Enter a question for AI Coach before sending.")
        case .rateLimited:
            String(localized: "Too many AI requests right now. Wait a moment and try again.")
        case .dailyCapReached:
            String(localized: "Daily AI limit reached — try again later.")
        case .busy:
            String(localized: "The AI service is busy right now. Try again in a moment.")
        case .timeout:
            String(localized: "AI Coach timed out. Check your connection and try again.")
        case .networkLost:
            String(localized: "Connection was interrupted. Tap Try again to re-send your question.")
        case .cancelled:
            String(localized: "Request cancelled.")
        case .serverError, .invalidResponse:
            String(localized: "The AI service returned an unexpected response. Try again.")
        }
    }

    static func coachNoteMessage(for code: String) -> String {
        switch code {
        case "no_valid_plan_change":
            String(localized: "No valid plan change could be created from this reply. Your schedule is unchanged.")
        case "stale_plan":
            String(localized: "Your schedule changed while reviewing this suggestion. Ask again to get an updated plan.")
        case "today_shifted":
            String(localized: "The date rolled over to a new day. Ask again to review changes for today.")
        case "net_zero_change":
            String(localized: "This suggestion already matches your current plan. No changes are needed.")
        default:
            String(localized: "No valid plan change could be created from this reply. Your schedule is unchanged.")
        }
    }

    #if DEBUG
    private static func fakeCoachResponseData(snapshot: CoachContext.Snapshot, noChange: Bool) throws -> Data {
        if noChange {
            let payload: JSONValue = .object([
                "answer": .string(String(localized: "Your current plan already balances fatigue well, so no safe schedule adjustment was applied.")),
                "changes": .array([]),
                "note": .string("no_valid_plan_change"),
            ])
            return try JSONEncoder().encode(payload)
        }

        // Pick an unlocked non-rest day allowed by the active schedule mode (preferring today so
        // the "AI-adjusted" badge appears immediately on Today after Accept).
        let eligibleDays = snapshot.plan.filter { day in
            guard day.locked == nil, !day.isRest, day.routineId != nil, !day.exercises.isEmpty else {
                return false
            }
            if snapshot.scheduleMode == "rotation", day.isQueueSession {
                return day.date == snapshot.rotationOnDate
            }
            return true
        }
        let targetDay = eligibleDays.first(where: { $0.date == snapshot.today }) ?? eligibleDays.first

        guard let day = targetDay,
              let rid = day.routineId,
              let slot = day.exercises.first else {
            let payload: JSONValue = .object([
                "answer": .string(String(localized: "There is no unlocked upcoming workout to modify right now. Load a routine or plan first, then ask again.")),
                "changes": .array([]),
                "note": .null,
            ])
            return try JSONEncoder().encode(payload)
        }

        let newSets = slot.sets > 2 ? max(1, slot.sets - 1) : min(12, slot.sets + 1)
        var opObj: [String: JSONValue] = [
            "type": .string("set_sets"),
            "date": .string(day.date),
            "routineId": .string(rid),
            "slotIndex": .number(Double(slot.slotIndex)),
            "exerciseId": .string(slot.exerciseId),
            "sets": .number(Double(newSets)),
            "reason": .string(String(localized: "Trimmed working volume to match recovery and save time.")),
        ]
        if slot.mode == "reps", let reps = slot.reps {
            opObj["reps"] = .number(Double(reps))
        }

        let answer = String(localized: "I suggest adjusting \(slot.name) to \(newSets) sets so you can stay on track without adding extra fatigue.")
        let payload: JSONValue = .object([
            "answer": .string(answer),
            "changes": .array([.object(opObj)]),
            "note": .null,
        ])
        return try JSONEncoder().encode(payload)
    }
    #endif

    #if DEBUG
    private static func fakeEstimate(lang: String, warning: Bool) -> AIWire.MealEstimate {
        let isEnglish = lang.lowercased().hasPrefix("en")
        if warning {
            return AIWire.MealEstimate(
                name: isEnglish ? "Mixed Bento Box" : "Mixed Bento Box",
                kcal: 420,
                protein: 45,
                carbs: 62,
                fat: 22,
                items: [
                    .init(name: "Grilled salmon", portion: "120 g fillet", kcal: 210, protein: 28, carbs: 2, fat: 12),
                    .init(name: "Rice & sides", portion: "1 medium portion", kcal: 210, protein: 17, carbs: 60, fat: 10),
                ],
                confidence: "low",
                assumptions: "Sauce and cooking oil estimated visually; verify numbers before saving.",
                plausibilityWarning: true,
                warnings: ["macro-kcal-mismatch"]
            )
        }
        return AIWire.MealEstimate(
            name: "Chicken Teriyaki Bowl",
            kcal: 640,
            protein: 46.2,
            carbs: 68.5,
            fat: 19.1,
            items: [
                .init(name: "Grilled chicken", portion: "150 g cooked", kcal: 280, protein: 38.0, carbs: 4.5, fat: 11.5),
                .init(name: "Steamed rice", portion: "1 bowl (~200 g)", kcal: 290, protein: 5.7, carbs: 60.0, fat: 1.6),
                .init(name: "Broccoli & sauce", portion: "80 g + 1 tbsp glaze", kcal: 70, protein: 2.5, carbs: 4.0, fat: 6.0),
            ],
            confidence: "high",
            assumptions: "Assumed standard medium rice bowl and light teriyaki glaze.",
            plausibilityWarning: false,
            warnings: []
        )
    }
    #endif
}
