import Foundation

/// Pure wire types, request encoder, and `(status, code)` HTTP error mapping matching the Stage 5a
/// FastAPI endpoints (`GET /api/ai/status` and `POST /api/ai/meal`).
public enum AIWire {
    /// Matches Stage 5a `server/hexserver/ai.py` (`MAX_IMAGE_BYTES = 1_150_000`).
    public static let maxImageBytes = 1_150_000
    public static let maxNoteCharacters = 240

    // MARK: - DTOs

    public struct Status: Codable, Equatable, Sendable {
        public let configured: Bool
        public let model: String?
        public let dailyTokenCap: Int
        public let dailyTokensUsed: Int

        public init(configured: Bool, model: String?, dailyTokenCap: Int, dailyTokensUsed: Int) {
            self.configured = configured
            self.model = model
            self.dailyTokenCap = dailyTokenCap
            self.dailyTokensUsed = dailyTokensUsed
        }
    }

    public struct MealItemEstimate: Codable, Equatable, Sendable {
        public let name: String
        public let kcal: Double
        public let protein: Double
        public let carbs: Double
        public let fat: Double

        public init(name: String, kcal: Double, protein: Double, carbs: Double, fat: Double) {
            self.name = name
            self.kcal = kcal
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
        }
    }

    public struct MealEstimate: Codable, Equatable, Sendable {
        public let name: String
        public let kcal: Double
        public let protein: Double
        public let carbs: Double
        public let fat: Double
        public let items: [MealItemEstimate]
        public let confidence: String
        public let plausibilityWarning: Bool
        public let warnings: [String]

        public init(
            name: String,
            kcal: Double,
            protein: Double,
            carbs: Double,
            fat: Double,
            items: [MealItemEstimate],
            confidence: String,
            plausibilityWarning: Bool,
            warnings: [String]
        ) {
            self.name = name
            self.kcal = kcal
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
            self.items = items
            self.confidence = confidence
            self.plausibilityWarning = plausibilityWarning
            self.warnings = warnings
        }
    }

    // MARK: - Typed Errors

    public enum ErrorKind: Error, Equatable, Sendable {
        case notPaired
        case notConfigured
        case unauthorized
        case upstreamAuth
        case payloadTooLarge
        case invalidImage
        case badRequest
        case noFoodDetected
        case rateLimited(retryAfter: Int?)
        case dailyCapReached(retryAfter: Int?)
        case busy(retryAfter: Int?)
        case timeout
        case networkLost
        case cancelled
        case serverError(code: String?, status: Int)
        case invalidResponse

        /// Transient conditions where tapping "Try again" with the same prepared image makes sense.
        /// `.dailyCapReached` is deliberately non-retryable until the rolling 24 h window clears.
        public var isRetryable: Bool {
            switch self {
            case .busy, .rateLimited, .timeout, .networkLost, .serverError:
                return true
            case .dailyCapReached, .notPaired, .notConfigured, .unauthorized, .upstreamAuth,
                 .payloadTooLarge, .invalidImage, .badRequest, .noFoodDetected, .cancelled, .invalidResponse:
                return false
            }
        }
    }

    // MARK: - Request Encoding

    private struct MealRequestBody: Encodable {
        let image_b64: String
        let note: String?
        let lang: String
    }

    private struct ErrorEnvelope: Decodable {
        let error: String?
        let code: String?
    }

    public static func isJPEG(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let start = data.startIndex
        return data[start] == 0xFF && data[start + 1] == 0xD8 && data[start + 2] == 0xFF
    }

    /// Synchronous request builder for `POST /api/ai/meal`.
    /// Validates JPEG magic bytes and byte cap, trims/caps `note` at 240 characters, and encodes
    /// without escaping `/` so base64 overhead stays strictly minimal.
    public static func encodeMealRequest(
        jpegData: Data,
        note: String?,
        lang: String
    ) throws -> Data {
        guard isJPEG(jpegData) else { throw ErrorKind.invalidImage }
        guard jpegData.count <= maxImageBytes else { throw ErrorKind.payloadTooLarge }

        let cleanedNote: String? = {
            guard let raw = note?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            if raw.count <= maxNoteCharacters { return raw }
            return String(raw.prefix(maxNoteCharacters))
        }()

        let normalizedLang = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = MealRequestBody(
            image_b64: jpegData.base64EncodedString(),
            note: cleanedNote,
            lang: normalizedLang.isEmpty ? "zh" : normalizedLang
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    /// `nonisolated async` entry point so `@MainActor` callers execute the ~1.5 MB base64 + JSON
    /// serialization off the main thread under Swift 6 (`SWIFT_APPROACHABLE_CONCURRENCY: NO`).
    public nonisolated static func encodeMealRequestAsync(
        jpegData: Data,
        note: String?,
        lang: String
    ) async throws -> Data {
        try encodeMealRequest(jpegData: jpegData, note: note, lang: lang)
    }

    // MARK: - Response Decoding & Error Mapping

    public static func decodeStatus(from data: Data) throws -> Status {
        do {
            return try JSONDecoder().decode(Status.self, from: data)
        } catch {
            throw ErrorKind.invalidResponse
        }
    }

    public static func decodeMealEstimate(from data: Data) throws -> MealEstimate {
        do {
            return try JSONDecoder().decode(MealEstimate.self, from: data)
        } catch {
            throw ErrorKind.invalidResponse
        }
    }

    /// Maps an HTTP error response from `/api/ai/*` strictly by `(status, code)` plus optional
    /// `Retry-After` integer header.
    public static func mapHTTPError(
        status: Int,
        body: Data?,
        retryAfterHeader: String?
    ) -> ErrorKind {
        let retryAfter = retryAfterHeader
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { Int($0) }
            .flatMap { $0 > 0 ? $0 : nil }

        let parsedCode: String? = body
            .flatMap { try? JSONDecoder().decode(ErrorEnvelope.self, from: $0) }?
            .code?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if status == 401 {
            return .unauthorized
        }

        switch parsedCode {
        case "ai-unconfigured":
            return .notConfigured
        case "ai-busy", "ai-upstream-busy":
            return .busy(retryAfter: retryAfter)
        case "rate-limited":
            return .rateLimited(retryAfter: retryAfter)
        case "daily-cap-exceeded":
            return .dailyCapReached(retryAfter: retryAfter)
        case "payload-too-large":
            return .payloadTooLarge
        case "invalid-image":
            return .invalidImage
        case "bad-request":
            return .badRequest
        case "no-food":
            return .noFoodDetected
        case "ai-upstream-auth":
            return .upstreamAuth
        case "ai-upstream-error":
            return .serverError(code: "ai-upstream-error", status: status)
        case "ai-timeout":
            return .timeout
        default:
            break
        }

        switch status {
        case 413:
            return .payloadTooLarge
        case 422:
            return .noFoodDetected
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 504:
            return .timeout
        default:
            return .serverError(code: parsedCode, status: status)
        }
    }
}
