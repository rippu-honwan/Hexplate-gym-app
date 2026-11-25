import Foundation
import HexplateCore
import Observation

/// Client for Stage 5a's paired server AI endpoints (`GET /api/ai/status`, `POST /api/ai/meal`).
///
/// Key invariants:
/// - Reads `ServerSync.shared.aiCredentials` fresh on every request (never cached across token rotation).
/// - Dedicated ephemeral `URLSession` with `httpShouldSetCookies = false` and `timeoutIntervalForResource = 60`
///   (above the server's 50 s deadline so structured 504 errors arrive cleanly).
/// - Request base64/JSON serialization runs off-main via `AIWire.encodeMealRequestAsync`.
@MainActor
@Observable
final class AIClient {
    static let shared = AIClient()
    static let privacyConsentKey = "aiPrivacyConsentAccepted"

    private(set) var hasPrivacyConsent: Bool

    #if DEBUG
    let isFakeMode: Bool
    private let fakeWarning: Bool
    private let fakeErrorOnce: Bool
    private let fakeDelayMs: Int
    private var fakeErrorConsumed = false
    #endif

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    init() {
        self.hasPrivacyConsent = UserDefaults.standard.bool(forKey: Self.privacyConsentKey)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let fakeAI = args.contains("-hexplate-fake-ai")
        let fakeWarn = args.contains("-hexplate-fake-ai-warning")
        let fakeErr = args.contains("-hexplate-fake-ai-error")
        let fakeSlow = args.contains("-hexplate-fake-ai-slow")
        self.isFakeMode = fakeAI || fakeWarn || fakeErr || fakeSlow
        self.fakeWarning = fakeWarn
        self.fakeErrorOnce = fakeErr
        self.fakeDelayMs = fakeSlow ? 4_000 : 700
        #endif
    }

    var isAvailableForScan: Bool {
        #if DEBUG
        if isFakeMode { return true }
        #endif
        return ServerSync.shared.paired
    }

    func acceptPrivacyConsent() {
        UserDefaults.standard.set(true, forKey: Self.privacyConsentKey)
        hasPrivacyConsent = true
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

    func estimateMeal(jpegData: Data, note: String?) async throws -> AIWire.MealEstimate {
        // Off-main base64 + JSON encoding (runs on global executor via nonisolated async).
        let lang = Theme.language
        let body = try await AIWire.encodeMealRequestAsync(jpegData: jpegData, note: note, lang: lang)
        try Task.checkCancellation()

        #if DEBUG
        if isFakeMode {
            do {
                try await Task.sleep(for: .milliseconds(fakeDelayMs))
            } catch {
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
                    .init(name: "Grilled salmon", kcal: 210, protein: 28, carbs: 2, fat: 12),
                    .init(name: "Rice & sides", kcal: 210, protein: 17, carbs: 60, fat: 10),
                ],
                confidence: "low",
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
                .init(name: "Grilled chicken", kcal: 280, protein: 38.0, carbs: 4.5, fat: 11.5),
                .init(name: "Steamed rice", kcal: 290, protein: 5.7, carbs: 60.0, fat: 1.6),
                .init(name: "Broccoli & sauce", kcal: 70, protein: 2.5, carbs: 4.0, fat: 6.0),
            ],
            confidence: "high",
            plausibilityWarning: false,
            warnings: []
        )
    }
    #endif
}
